import CoreServices
import Darwin
import Foundation
import RelayModels
import RelayPTYCore
import RelayWorkspaceStore

public struct RelayLiveWorkspaceSnapshot: @unchecked Sendable {
    public let allRuns: [RelayRunRecord]
    public let latestRun: RelayRunRecord?
    public let terminalSnapshotsByLane: [String: TerminalViewportSnapshot]
    public let terminalBuffersByLane: [String: VT100TerminalScreenBuffer]
    public let terminalPlainTextByLane: [String: String]
    public let verifyOutputText: String
    public let observedAt: Date

    public init(
        allRuns: [RelayRunRecord] = [],
        latestRun: RelayRunRecord? = nil,
        terminalSnapshotsByLane: [String: TerminalViewportSnapshot] = [:],
        terminalBuffersByLane: [String: VT100TerminalScreenBuffer] = [:],
        terminalPlainTextByLane: [String: String] = [:],
        verifyOutputText: String = "",
        observedAt: Date = Date()
    ) {
        self.allRuns = allRuns
        self.latestRun = latestRun
        self.terminalSnapshotsByLane = terminalSnapshotsByLane
        self.terminalBuffersByLane = terminalBuffersByLane
        self.terminalPlainTextByLane = terminalPlainTextByLane
        self.verifyOutputText = verifyOutputText
        self.observedAt = observedAt
    }
}

/// Read-only live observer over a `.relayproj` bundle:
/// - Watches `workspace.sqlite` / `workspace.sqlite-wal` / `run.lock` via `FSEvents` + `DispatchSource` (`kqueue`)
///   and reads `RelayProjectDatabase.allRuns(reconcileWithLock: true)` without writing to SQLite or executing git merges.
/// - Incrementally streams `<worktree>/.relay/NN-<agent>.log` into per-lane `VT100TerminalScreenBuffer`s;
///   for lanes without non-empty `.relay/*.log` (e.g. budget-refused lanes), streams `runs/<runID>/lanes/<lane>.pty`.
/// - Emits a 1-second heartbeat while a run is active so elapsed-time displays advance smoothly.
public final class RelayLiveWorkspaceObserver: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var terminalRows: Int
        public var terminalColumns: Int
        public var fsEventsLatencySeconds: TimeInterval
        public var runningTickIntervalSeconds: TimeInterval
        public var readRelayStepLogs: Bool
        public var observeDatabaseChanges: Bool

        public init(
            terminalRows: Int = 26,
            terminalColumns: Int = 96,
            fsEventsLatencySeconds: TimeInterval = 0.02,
            runningTickIntervalSeconds: TimeInterval = 1.0,
            readRelayStepLogs: Bool = true,
            observeDatabaseChanges: Bool = true
        ) {
            self.terminalRows = max(4, terminalRows)
            self.terminalColumns = max(12, terminalColumns)
            self.fsEventsLatencySeconds = max(0.01, fsEventsLatencySeconds)
            self.runningTickIntervalSeconds = max(0.1, runningTickIntervalSeconds)
            self.readRelayStepLogs = readRelayStepLogs
            self.observeDatabaseChanges = observeDatabaseChanges
        }
    }

    private enum StreamFileKind: Equatable {
        case relayStepLog(runID: String, laneID: String)
        case lanePTY(runID: String, laneID: String)
        case verifyPTY(runID: String)
    }

    private enum LaneSourceMode: Equatable {
        case none
        case lanePTY
        case relayStepLog
    }

    private final class WeakObserverBox {
        weak var observer: RelayLiveWorkspaceObserver?
        init(_ observer: RelayLiveWorkspaceObserver) {
            self.observer = observer
        }
    }

    public let projectBundleURL: URL
    public let configuration: Configuration

    private let providedDatabase: RelayProjectDatabase?
    private var openedDatabase: RelayProjectDatabase?
    private let onUpdate: @Sendable (RelayLiveWorkspaceSnapshot) -> Void
    private let queue = DispatchQueue(label: "io.relayide.live-workspace-observer", qos: .userInteractive)

    private var isStarted = false
    private var streamRef: FSEventStreamRef?
    private var fileWatchSources: [String: DispatchSourceFileSystemObject] = [:]
    private var dbWatchSources: [String: DispatchSourceFileSystemObject] = [:]
    private var runningHeartbeatTimer: DispatchSourceTimer?

    private var cachedRuns: [RelayRunRecord] = []
    private var activeTerminalRunID: String?
    private var fileByteOffsets: [String: UInt64] = [:]
    private var fileLastByteWasCR: [String: Bool] = [:]
    private var laneSourceModes: [String: LaneSourceMode] = [:]
    private var laneBuffers: [String: VT100TerminalScreenBuffer] = [:]
    private var lanePlainTexts: [String: String] = [:]
    private var verifyPlainText: String = ""
    private var lastObservedLockPresent: Bool = false

    public init(
        projectBundleURL: URL,
        database: RelayProjectDatabase? = nil,
        configuration: Configuration = Configuration(),
        onUpdate: @escaping @Sendable (RelayLiveWorkspaceSnapshot) -> Void
    ) {
        self.projectBundleURL = projectBundleURL.standardizedFileURL
        self.providedDatabase = database
        self.configuration = configuration
        self.onUpdate = onUpdate
    }

    deinit {
        if let stream = streamRef {
            streamRef = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        runningHeartbeatTimer?.cancel()
        runningHeartbeatTimer = nil
        for (_, src) in fileWatchSources {
            src.cancel()
        }
        for (_, src) in dbWatchSources {
            src.cancel()
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            guard RelayProjectDatabase.bundleExists(at: self.projectBundleURL) else { return }
            self.isStarted = true
            _ = self.resolveDatabase()
            self.startFSEventStreamOnQueue()
            if self.configuration.observeDatabaseChanges {
                self.attachDatabaseFileWatchersIfAvailableOnQueue()
            }
            self.reloadDatabaseRunsOnQueue()
            self.scanAndDrainRunOutputFilesOnQueue()
            self.updateRunningHeartbeatTimerOnQueue()
            self.emitSnapshotOnQueue()
        }
    }

    public func stop() {
        queue.sync {
            guard isStarted else { return }
            isStarted = false
            if let stream = streamRef {
                streamRef = nil
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            runningHeartbeatTimer?.cancel()
            runningHeartbeatTimer = nil
            for (_, src) in fileWatchSources {
                src.cancel()
            }
            fileWatchSources.removeAll()
            for (_, src) in dbWatchSources {
                src.cancel()
            }
            dbWatchSources.removeAll()
            openedDatabase = nil
        }
    }

    public func refreshNow() {
        queue.async { [weak self] in
            guard let self, self.isStarted else { return }
            self.reloadDatabaseRunsOnQueue()
            self.scanAndDrainRunOutputFilesOnQueue()
            self.updateRunningHeartbeatTimerOnQueue()
            self.emitSnapshotOnQueue()
        }
    }

    // MARK: - FSEvents & kqueue Wiring (Serial Queue)

    private func resolveDatabase() -> RelayProjectDatabase? {
        if let providedDatabase {
            return providedDatabase
        }
        if let openedDatabase {
            return openedDatabase
        }
        guard RelayProjectDatabase.bundleExists(at: projectBundleURL) else {
            return nil
        }
        let db = try? RelayProjectDatabase.openExisting(bundleDirectoryURL: projectBundleURL)
        self.openedDatabase = db
        return db
    }

    private func startFSEventStreamOnQueue() {
        let box = WeakObserverBox(self)
        let retained = Unmanaged.passRetained(box)
        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<WeakObserverBox>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<WeakObserverBox>.fromOpaque(info).takeUnretainedValue()
            guard let observer = box.observer else { return }
            let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
            var paths: [String] = []
            paths.reserveCapacity(numEvents)
            for idx in 0..<numEvents {
                if let rawPtr = CFArrayGetValueAtIndex(cfArray, idx) {
                    paths.append(unsafeBitCast(rawPtr, to: CFString.self) as String)
                }
            }
            observer.handleFSEventsOnQueue(paths: paths)
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        if let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [projectBundleURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            configuration.fsEventsLatencySeconds,
            flags
        ) {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            streamRef = stream
        } else {
            retained.release()
        }
    }

    private func isDatabaseTriggerPath(_ standardizedPath: String) -> Bool {
        let last = (standardizedPath as NSString).lastPathComponent
        return last == "workspace.sqlite"
            || last == "workspace.sqlite-wal"
            || last == "workspace.sqlite-shm"
            || last == "workspace.sqlite-journal"
            || last == "run.lock"
    }

    private func attachDatabaseFileWatchersIfAvailableOnQueue() {
        guard configuration.observeDatabaseChanges else { return }
        let candidates = [
            projectBundleURL.appendingPathComponent("workspace.sqlite").standardizedFileURL.path,
            projectBundleURL.appendingPathComponent("workspace.sqlite-wal").standardizedFileURL.path
        ]
        for path in candidates where dbWatchSources[path] == nil {
            let fd = path.withCString { Darwin.open($0, O_RDONLY | O_EVTONLY | O_CLOEXEC) }
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .delete, .rename],
                queue: queue
            )
            src.setEventHandler { [weak self] in
                guard let self, self.isStarted, self.configuration.observeDatabaseChanges else { return }
                let flags = src.data
                if flags.contains(.delete) || flags.contains(.rename) {
                    self.dbWatchSources.removeValue(forKey: path)?.cancel()
                    self.attachDatabaseFileWatchersIfAvailableOnQueue()
                }
                let changedDB = self.reloadDatabaseRunsOnQueue()
                let changedOut = self.scanAndDrainRunOutputFilesOnQueue()
                self.updateRunningHeartbeatTimerOnQueue()
                if changedDB || changedOut {
                    self.emitSnapshotOnQueue()
                }
            }
            src.setCancelHandler {
                Darwin.close(fd)
            }
            dbWatchSources[path] = src
            src.resume()
        }
    }

    private func handleFSEventsOnQueue(paths: [String]) {
        guard isStarted else { return }
        var sawDatabaseEvent = false
        var sawRunDirectoryEvent = false
        var directOutputFiles: [(path: String, kind: StreamFileKind)] = []

        for raw in paths {
            let stdPath = URL(fileURLWithPath: raw).standardizedFileURL.path
            if isDatabaseTriggerPath(stdPath) {
                sawDatabaseEvent = true
            }
            if let classified = classifyStreamFilePath(stdPath) {
                directOutputFiles.append((stdPath, classified))
            } else if stdPath.contains("/runs") {
                sawRunDirectoryEvent = true
            }
        }

        var didMutate = false

        if sawDatabaseEvent && configuration.observeDatabaseChanges {
            attachDatabaseFileWatchersIfAvailableOnQueue()
            if reloadDatabaseRunsOnQueue() {
                didMutate = true
            }
            if scanAndDrainRunOutputFilesOnQueue() {
                didMutate = true
            }
            updateRunningHeartbeatTimerOnQueue()
        } else {
            for item in directOutputFiles {
                if handleDiscoveredStreamFileOnQueue(path: item.path, kind: item.kind) {
                    didMutate = true
                }
            }
            if sawRunDirectoryEvent {
                if scanAndDrainRunOutputFilesOnQueue() {
                    didMutate = true
                }
            }
        }

        if didMutate {
            emitSnapshotOnQueue()
        }
    }

    // MARK: - Database Polling (Triggered by SQLite / Lock Events)

    @discardableResult
    private func reloadDatabaseRunsOnQueue() -> Bool {
        guard let db = resolveDatabase() else { return false }
        guard let freshRuns = try? db.allRuns(reconcileWithLock: true) else { return false }
        let lockPath = projectBundleURL.appendingPathComponent("run.lock").path
        lastObservedLockPresent = FileManager.default.fileExists(atPath: lockPath)

        let changed = (freshRuns != cachedRuns)
        cachedRuns = freshRuns

        if let latestRunID = freshRuns.last?.runID, activeTerminalRunID != latestRunID {
            switchActiveTerminalRunOnQueue(to: latestRunID)
            return true
        }
        return changed
    }

    private func switchActiveTerminalRunOnQueue(to newRunID: String) {
        activeTerminalRunID = newRunID
        for (_, src) in fileWatchSources {
            src.cancel()
        }
        fileWatchSources.removeAll()
        fileByteOffsets.removeAll()
        fileLastByteWasCR.removeAll()
        laneSourceModes.removeAll()
        laneBuffers.removeAll()
        lanePlainTexts.removeAll()
        verifyPlainText = ""
    }

    // MARK: - Output File Classification, Discovery & Incremental Streaming

    private func classifyStreamFilePath(_ standardizedPath: String) -> StreamFileKind? {
        let runsPrefix = projectBundleURL.appendingPathComponent("runs", isDirectory: true).standardizedFileURL.path + "/"
        guard standardizedPath.hasPrefix(runsPrefix) else { return nil }
        let rel = String(standardizedPath.dropFirst(runsPrefix.count))
        let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let runID = parts[0]

        // <runID>/verify.pty
        if parts.count == 2, parts[1] == "verify.pty" {
            return .verifyPTY(runID: runID)
        }

        guard parts.count >= 3 else { return nil }

        // <runID>/lanes/<laneID>.pty
        if parts.count == 3, parts[1] == "lanes", parts[2].hasSuffix(".pty") {
            let laneID = String(parts[2].dropLast(4))
            guard !laneID.isEmpty else { return nil }
            return .lanePTY(runID: runID, laneID: laneID)
        }

        // <runID>/worktrees/<laneID>/.relay/<step>.log
        if parts.count == 5, parts[1] == "worktrees", parts[3] == ".relay", parts[4].hasSuffix(".log") {
            guard configuration.readRelayStepLogs else { return nil }
            let laneID = parts[2]
            guard !laneID.isEmpty else { return nil }
            return .relayStepLog(runID: runID, laneID: laneID)
        }

        return nil
    }

    private func preferredRunIDForTerminalStreamingOnQueue() -> String? {
        if let dbLatest = cachedRuns.last?.runID {
            return dbLatest
        }
        let runsDir = projectBundleURL.appendingPathComponent("runs", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: runsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return activeTerminalRunID
        }
        let dirNames = children.compactMap { url -> String? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir ? url.lastPathComponent : nil
        }.sorted()
        return dirNames.last ?? activeTerminalRunID
    }

    @discardableResult
    private func scanAndDrainRunOutputFilesOnQueue() -> Bool {
        guard let targetRunID = preferredRunIDForTerminalStreamingOnQueue() else { return false }
        if activeTerminalRunID != targetRunID {
            switchActiveTerminalRunOnQueue(to: targetRunID)
        }

        let runRoot = projectBundleURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(targetRunID, isDirectory: true)

        var mutated = false
        let fm = FileManager.default

        // 1. Scan `<runRoot>/worktrees/<laneID>/.relay/*.log` FIRST so `.relay/*.log` always wins over `.pty` when non-empty.
        if configuration.readRelayStepLogs {
            let worktreesRoot = runRoot.appendingPathComponent("worktrees", isDirectory: true)
            if let laneDirs = try? fm.contentsOfDirectory(at: worktreesRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for laneDir in laneDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let laneID = laneDir.lastPathComponent
                    let relayDir = laneDir.appendingPathComponent(".relay", isDirectory: true)
                    if let items = try? fm.contentsOfDirectory(at: relayDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        let logs = items
                            .filter { $0.pathExtension == "log" }
                            .sorted { $0.lastPathComponent < $1.lastPathComponent }
                        for logURL in logs {
                            let stdPath = logURL.standardizedFileURL.path
                            if handleDiscoveredStreamFileOnQueue(
                                path: stdPath,
                                kind: .relayStepLog(runID: targetRunID, laneID: laneID)
                            ) {
                                mutated = true
                            }
                        }
                    }
                }
            }
        }

        // 2. Scan `<runRoot>/lanes/<laneID>.pty` as fallback for lanes without non-empty `.relay/*.log`.
        let lanesRoot = runRoot.appendingPathComponent("lanes", isDirectory: true)
        if let ptyItems = try? fm.contentsOfDirectory(at: lanesRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for ptyURL in ptyItems.filter({ $0.pathExtension == "pty" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let laneID = ptyURL.deletingPathExtension().lastPathComponent
                let stdPath = ptyURL.standardizedFileURL.path
                if handleDiscoveredStreamFileOnQueue(
                    path: stdPath,
                    kind: .lanePTY(runID: targetRunID, laneID: laneID)
                ) {
                    mutated = true
                }
            }
        }

        // 3. Scan `<runRoot>/verify.pty` for M2 verification output.
        let verifyURL = runRoot.appendingPathComponent("verify.pty")
        if fm.fileExists(atPath: verifyURL.path) {
            let stdVerifyPath = verifyURL.standardizedFileURL.path
            if handleDiscoveredStreamFileOnQueue(path: stdVerifyPath, kind: .verifyPTY(runID: targetRunID)) {
                mutated = true
            }
        }

        // Release file descriptors once the run is completely terminal.
        if let run = cachedRuns.last, run.runID == targetRunID, isEntireRunTerminal(run) {
            for (_, src) in fileWatchSources {
                src.cancel()
            }
            fileWatchSources.removeAll()
        }

        return mutated
    }

    @discardableResult
    private func handleDiscoveredStreamFileOnQueue(path: String, kind: StreamFileKind) -> Bool {
        let fileRunID: String
        switch kind {
        case .relayStepLog(let r, _), .lanePTY(let r, _), .verifyPTY(let r):
            fileRunID = r
        }

        if activeTerminalRunID == nil {
            activeTerminalRunID = fileRunID
        } else if let current = activeTerminalRunID, fileRunID > current, cachedRuns.last == nil {
            switchActiveTerminalRunOnQueue(to: fileRunID)
        }
        guard activeTerminalRunID == fileRunID else { return false }

        attachOutputFileWatcherIfNeededOnQueue(path: path, kind: kind)
        return drainStreamFileOnQueue(path: path, kind: kind)
    }

    private func attachOutputFileWatcherIfNeededOnQueue(path: String, kind: StreamFileKind) {
        guard fileWatchSources[path] == nil else { return }
        if let run = cachedRuns.last, isEntireRunTerminal(run) { return }
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_EVTONLY | O_CLOEXEC) }
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self, self.isStarted else { return }
            if self.drainStreamFileOnQueue(path: path, kind: kind) {
                self.emitSnapshotOnQueue()
            }
        }
        src.setCancelHandler {
            Darwin.close(fd)
        }
        fileWatchSources[path] = src
        src.resume()
    }

    @discardableResult
    private func drainStreamFileOnQueue(path: String, kind: StreamFileKind) -> Bool {
        switch kind {
        case .relayStepLog(let runID, let laneID):
            guard configuration.readRelayStepLogs, activeTerminalRunID == runID else { return false }
            let currentMode = laneSourceModes[laneID] ?? .none
            if currentMode == .lanePTY {
                // Check if `.log` now has non-empty content; if so, switch cleanly to `.relayStepLog` from offset 0.
                guard let size = fileByteSize(atPath: path), size > 0 else { return false }
                resetLaneBufferForStepLogsOnQueue(runID: runID, laneID: laneID)
                return replayAllStepLogsForLaneOnQueue(runID: runID, laneID: laneID)
            }
            guard let chunk = readNewBytesOnQueue(path: path), !chunk.isEmpty else { return false }
            laneSourceModes[laneID] = .relayStepLog
            appendChunkToLaneBufferOnQueue(laneID: laneID, path: path, chunk: chunk)
            return true

        case .lanePTY(let runID, let laneID):
            guard activeTerminalRunID == runID else { return false }
            let currentMode = laneSourceModes[laneID] ?? .none
            guard currentMode != .relayStepLog else {
                // Lane already has `.relay/*.log` content; keep terminal buffer matched to `.relay/*.log`.
                return false
            }
            // Before falling back to `.pty`, double-check if `.relay/*.log` already exists with >0 bytes on disk.
            if configuration.readRelayStepLogs, laneHasNonEmptyStepLogsOnDisk(runID: runID, laneID: laneID) {
                resetLaneBufferForStepLogsOnQueue(runID: runID, laneID: laneID)
                return replayAllStepLogsForLaneOnQueue(runID: runID, laneID: laneID)
            }
            guard let chunk = readNewBytesOnQueue(path: path), !chunk.isEmpty else { return false }
            laneSourceModes[laneID] = .lanePTY
            appendChunkToLaneBufferOnQueue(laneID: laneID, path: path, chunk: chunk)
            return true

        case .verifyPTY(let runID):
            guard activeTerminalRunID == runID else { return false }
            guard let chunk = readNewBytesOnQueue(path: path), !chunk.isEmpty else { return false }
            let capBytes = 65_536
            let decoded = String(decoding: chunk, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            verifyPlainText += decoded
            if verifyPlainText.utf8.count > capBytes {
                verifyPlainText = String(verifyPlainText.suffix(capBytes))
            }
            return true
        }
    }

    private func laneHasNonEmptyStepLogsOnDisk(runID: String, laneID: String) -> Bool {
        let relayDir = projectBundleURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(laneID, isDirectory: true)
            .appendingPathComponent(".relay", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: relayDir, includingPropertiesForKeys: nil) else {
            return false
        }
        for url in items where url.pathExtension == "log" {
            if let sz = fileByteSize(atPath: url.path), sz > 0 {
                return true
            }
        }
        return false
    }

    private func resetLaneBufferForStepLogsOnQueue(runID: String, laneID: String) {
        laneBuffers[laneID] = VT100TerminalScreenBuffer(
            laneID: laneID,
            rows: configuration.terminalRows,
            columns: configuration.terminalColumns
        )
        lanePlainTexts[laneID] = ""
        laneSourceModes[laneID] = .relayStepLog

        let relayPrefix = projectBundleURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(laneID, isDirectory: true)
            .appendingPathComponent(".relay", isDirectory: true)
            .standardizedFileURL.path + "/"
        for key in Array(fileByteOffsets.keys) where key.hasPrefix(relayPrefix) {
            fileByteOffsets[key] = 0
            fileLastByteWasCR[key] = false
        }
    }

    @discardableResult
    private func replayAllStepLogsForLaneOnQueue(runID: String, laneID: String) -> Bool {
        let relayDir = projectBundleURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(laneID, isDirectory: true)
            .appendingPathComponent(".relay", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: relayDir, includingPropertiesForKeys: nil) else {
            return false
        }
        var didFeed = false
        for url in items.filter({ $0.pathExtension == "log" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let stdPath = url.standardizedFileURL.path
            attachOutputFileWatcherIfNeededOnQueue(path: stdPath, kind: .relayStepLog(runID: runID, laneID: laneID))
            if let chunk = readNewBytesOnQueue(path: stdPath), !chunk.isEmpty {
                appendChunkToLaneBufferOnQueue(laneID: laneID, path: stdPath, chunk: chunk)
                didFeed = true
            }
        }
        return didFeed
    }

    private func fileByteSize(atPath path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attrs[.size] as? NSNumber else {
            return nil
        }
        return number.uint64Value
    }

    private func readNewBytesOnQueue(path: String) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let offset = fileByteOffsets[path] ?? 0
        do {
            try fh.seek(toOffset: offset)
            guard let chunk = try fh.readToEnd(), !chunk.isEmpty else { return nil }
            fileByteOffsets[path] = offset + UInt64(chunk.count)
            return chunk
        } catch {
            return nil
        }
    }

    private func appendChunkToLaneBufferOnQueue(laneID: String, path: String, chunk: Data) {
        let buffer: VT100TerminalScreenBuffer
        if let existing = laneBuffers[laneID] {
            buffer = existing
        } else {
            let created = VT100TerminalScreenBuffer(
                laneID: laneID,
                rows: configuration.terminalRows,
                columns: configuration.terminalColumns
            )
            laneBuffers[laneID] = created
            buffer = created
        }

        // Normalize bare LF (`0x0A`) into CRLF (`0x0D 0x0A`) so regular `.log` files start each line at column 0.
        var prevCR = fileLastByteWasCR[path] ?? false
        var normalized = Data()
        normalized.reserveCapacity(chunk.count + 16)
        for b in chunk {
            if b == 0x0A && !prevCR {
                normalized.append(0x0D)
            }
            normalized.append(b)
            prevCR = (b == 0x0D)
        }
        fileLastByteWasCR[path] = prevCR
        buffer.feed(normalized)

        let decoded = String(decoding: chunk, as: UTF8.self)
        lanePlainTexts[laneID, default: ""] += decoded
    }

    // MARK: - 1-Second Running Elapsed-Clock Heartbeat

    private func isEntireRunTerminal(_ run: RelayRunRecord) -> Bool {
        if !run.status.isTerminal {
            return false
        }
        if run.lanes.contains(where: { !$0.status.isTerminal }) {
            return false
        }
        if let integ = run.integration, !integ.status.isTerminal {
            return false
        }
        return true
    }

    private func updateRunningHeartbeatTimerOnQueue() {
        let hasActiveRun = cachedRuns.last.map { !isEntireRunTerminal($0) } ?? false
        if hasActiveRun {
            guard runningHeartbeatTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + configuration.runningTickIntervalSeconds,
                repeating: configuration.runningTickIntervalSeconds,
                leeway: .milliseconds(50)
            )
            timer.setEventHandler { [weak self] in
                guard let self, self.isStarted else { return }
                // Only reconcile SQLite here if `run.lock` vanished unexpectedly (e.g. SIGKILL orphan run).
                if self.configuration.observeDatabaseChanges && self.lastObservedLockPresent {
                    let lockPath = self.projectBundleURL.appendingPathComponent("run.lock").path
                    if !FileManager.default.fileExists(atPath: lockPath) {
                        _ = self.reloadDatabaseRunsOnQueue()
                        _ = self.scanAndDrainRunOutputFilesOnQueue()
                        self.updateRunningHeartbeatTimerOnQueue()
                    }
                }
                self.emitSnapshotOnQueue()
            }
            runningHeartbeatTimer = timer
            timer.resume()
        } else if let timer = runningHeartbeatTimer {
            runningHeartbeatTimer = nil
            timer.cancel()
        }
    }

    private func emitSnapshotOnQueue() {
        var snapDict: [String: TerminalViewportSnapshot] = [:]
        for (laneID, buf) in laneBuffers {
            snapDict[laneID] = buf.snapshot()
        }
        let snapshot = RelayLiveWorkspaceSnapshot(
            allRuns: cachedRuns,
            latestRun: cachedRuns.last,
            terminalSnapshotsByLane: snapDict,
            terminalBuffersByLane: laneBuffers,
            terminalPlainTextByLane: lanePlainTexts,
            verifyOutputText: verifyPlainText,
            observedAt: Date()
        )
        onUpdate(snapshot)
    }
}
