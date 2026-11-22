import CoreServices
import Darwin
import Foundation
import RelayModels

// MARK: - Read-Only Live Worktree File Ownership & M2 Conflict Block Reconstruction (`03-relayide.md` M5)

public enum RelayOwnedFileWorktreeState: String, Sendable, Codable, Hashable, Equatable {
    case committedToLane = "committed"
    case uncommittedInWorktree = "uncommitted"

    public func localizedLabel(in language: RelayLanguage) -> String {
        switch self {
        case .committedToLane:
            return RelayLocalizer.select(language, "committed", "已提交")
        case .uncommittedInWorktree:
            return RelayLocalizer.select(language, "uncommitted", "未提交")
        }
    }
}

public struct RelayLaneOwnedFileItem: Sendable, Hashable, Equatable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let worktreeState: RelayOwnedFileWorktreeState
    public let porcelainCode: String?
    public let additions: Int
    public let deletions: Int

    public init(
        relativePath: String,
        worktreeState: RelayOwnedFileWorktreeState,
        porcelainCode: String? = nil,
        additions: Int = 0,
        deletions: Int = 0
    ) {
        self.relativePath = relativePath
        self.worktreeState = worktreeState
        self.porcelainCode = porcelainCode
        self.additions = max(0, additions)
        self.deletions = max(0, deletions)
    }
}

public struct RelayLaneFileOwnershipSnapshot: Sendable, Hashable, Equatable, Identifiable {
    public var id: String { laneID }
    public let laneID: String
    public let worktreePath: String
    public let startCommitOID: String
    public let files: [RelayLaneOwnedFileItem]

    public var totalAdditions: Int {
        files.reduce(0) { $0 + $1.additions }
    }

    public var totalDeletions: Int {
        files.reduce(0) { $0 + $1.deletions }
    }

    public var committedFileCount: Int {
        files.filter { $0.worktreeState == .committedToLane }.count
    }

    public var uncommittedFileCount: Int {
        files.filter { $0.worktreeState == .uncommittedInWorktree }.count
    }

    public init(
        laneID: String,
        worktreePath: String,
        startCommitOID: String,
        files: [RelayLaneOwnedFileItem] = []
    ) {
        self.laneID = laneID
        self.worktreePath = worktreePath
        self.startCommitOID = startCommitOID
        self.files = files
    }
}

public struct RelayReconstructedMergeConflictBlock: Sendable, Hashable, Equatable, Identifiable {
    public var id: String { "\(ordinal):\(laneID):\(path)" }
    public let ordinal: Int
    public let laneID: String
    public let path: String
    public let code: String
    public let mergeBaseOID: String
    public let oursCommitOID: String
    public let theirsCommitOID: String
    public let conflictText: String?

    public init(
        ordinal: Int,
        laneID: String,
        path: String,
        code: String,
        mergeBaseOID: String,
        oursCommitOID: String,
        theirsCommitOID: String,
        conflictText: String?
    ) {
        self.ordinal = ordinal
        self.laneID = laneID
        self.path = path
        self.code = code
        self.mergeBaseOID = mergeBaseOID
        self.oursCommitOID = oursCommitOID
        self.theirsCommitOID = theirsCommitOID
        self.conflictText = conflictText
    }
}

public struct RelayReadOnlyGitInspectorConfiguration: Sendable, Equatable {
    public var fsEventsLatencySeconds: TimeInterval
    public var observeWorktreeFileSystemEvents: Bool
    public var reconstructConflictBlocksWithGitMergeFile: Bool

    public init(
        fsEventsLatencySeconds: TimeInterval = 0.03,
        observeWorktreeFileSystemEvents: Bool = true,
        reconstructConflictBlocksWithGitMergeFile: Bool = true
    ) {
        self.fsEventsLatencySeconds = max(0.01, fsEventsLatencySeconds)
        self.observeWorktreeFileSystemEvents = observeWorktreeFileSystemEvents
        self.reconstructConflictBlocksWithGitMergeFile = reconstructConflictBlocksWithGitMergeFile
    }
}

public struct RelayWatchedLaneWorktreeTarget: Sendable, Hashable, Equatable {
    public let laneID: String
    public let worktreePath: String
    public let startCommitOID: String

    public init(laneID: String, worktreePath: String, startCommitOID: String) {
        self.laneID = laneID
        self.worktreePath = worktreePath
        self.startCommitOID = startCommitOID
    }
}

public struct RelayReadOnlyGitRunInspector: Sendable {
    public let gitExecutablePath: String
    public let configuration: RelayReadOnlyGitInspectorConfiguration

    public init(
        gitExecutablePath: String = "/usr/bin/git",
        configuration: RelayReadOnlyGitInspectorConfiguration = RelayReadOnlyGitInspectorConfiguration()
    ) {
        self.gitExecutablePath = gitExecutablePath
        self.configuration = configuration
    }

    /// Resolves the baseline commit OID at which `lane`'s worktree was branched (`run.baseCommitOID` for root lanes,
    /// or the predecessor's `commitOID` when `lane.after` chains off a completed predecessor).
    public static func resolveLaneStartCommitOID(for lane: RelayRunLaneRecord, in run: RelayRunRecord) -> String {
        let byID = Dictionary(uniqueKeysWithValues: run.lanes.map { ($0.laneID, $0) })
        func walk(_ current: RelayRunLaneRecord, visited: inout Set<String>) -> String {
            guard visited.insert(current.laneID).inserted else {
                return run.baseCommitOID
            }
            guard let predID = current.after.last, let pred = byID[predID] else {
                return run.baseCommitOID
            }
            if let predCommit = pred.commitOID, !predCommit.isEmpty {
                return predCommit
            }
            return walk(pred, visited: &visited)
        }
        var visited = Set<String>()
        let resolved = walk(lane, visited: &visited)
        return resolved.isEmpty ? run.baseCommitOID : resolved
    }

    public static func isExcludedInternalPath(_ relativePath: String) -> Bool {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return true }
        let parts = trimmed.split(separator: "/")
        return parts.contains(".relay") || parts.contains(".git")
    }

    /// Computes a lane's owned file list strictly via read-only Git plumbing (`--no-optional-locks`):
    /// `git diff --name-only <startCommitOID>` ∪ `git ls-files --others --exclude-standard` (excluding `.relay/` and `.git/`),
    /// partitioned into committed vs uncommitted via `git status --porcelain=v1 -z -uall`, with `+add/-del` line counts.
    public func inspectLaneFileOwnership(
        laneID: String,
        worktreePath: String,
        startCommitOID: String,
        environment: [String: String]? = nil
    ) -> RelayLaneFileOwnershipSnapshot {
        guard !worktreePath.isEmpty, FileManager.default.fileExists(atPath: worktreePath) else {
            return RelayLaneFileOwnershipSnapshot(
                laneID: laneID,
                worktreePath: worktreePath,
                startCommitOID: startCommitOID,
                files: []
            )
        }

        let trimmedStart = startCommitOID.trimmingCharacters(in: .whitespacesAndNewlines)
        var effectiveRef = trimmedStart.isEmpty ? "HEAD" : trimmedStart

        // 1. `git diff --name-only <startCommitOID>` (with `-z --no-renames` for exact unquoted paths)
        var diffRes = runReadOnlyGitString(
            ["diff", "--no-renames", "--name-only", "-z", effectiveRef, "--"],
            cwd: worktreePath,
            environment: environment
        )
        if diffRes.exitCode != 0 && effectiveRef != "HEAD" {
            effectiveRef = "HEAD"
            diffRes = runReadOnlyGitString(
                ["diff", "--no-renames", "--name-only", "-z", effectiveRef, "--"],
                cwd: worktreePath,
                environment: environment
            )
        }
        let diffPaths: [String] = (diffRes.exitCode == 0)
            ? diffRes.stdout
                .split(separator: "\0", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { !Self.isExcludedInternalPath($0) }
            : []

        // 2. `git ls-files --others --exclude-standard`
        let untrackedRes = runReadOnlyGitString(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            cwd: worktreePath,
            environment: environment
        )
        let untrackedPaths: [String] = (untrackedRes.exitCode == 0)
            ? untrackedRes.stdout
                .split(separator: "\0", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { !Self.isExcludedInternalPath($0) }
            : []
        let untrackedSet = Set(untrackedPaths)

        let allPaths = Set(diffPaths).union(untrackedSet).sorted()
        guard !allPaths.isEmpty else {
            return RelayLaneFileOwnershipSnapshot(
                laneID: laneID,
                worktreePath: worktreePath,
                startCommitOID: startCommitOID,
                files: []
            )
        }

        // 3. `git status --porcelain=v1 -z -uall` to separate committed-on-lane vs uncommitted-in-worktree
        var porcelainByPath: [String: String] = [:]
        let statusRes = runReadOnlyGitString(
            ["status", "--porcelain=v1", "-z", "-uall"],
            cwd: worktreePath,
            environment: environment
        )
        if statusRes.exitCode == 0 {
            let entries = statusRes.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
            var idx = 0
            while idx < entries.count {
                let entry = entries[idx]
                idx += 1
                guard entry.count >= 4 else { continue }
                let xyChars = Array(entry.prefix(2))
                let xy = String(xyChars)
                let path = String(entry.dropFirst(3))
                if xyChars[0] == "R" || xyChars[0] == "C" {
                    if idx < entries.count {
                        idx += 1
                    }
                }
                if Self.isExcludedInternalPath(path) {
                    continue
                }
                porcelainByPath[path] = xy
            }
        }

        // 4. `git diff --numstat <startCommitOID>` for line additions/deletions
        var numstatByPath: [String: (add: Int, del: Int)] = [:]
        let numstatRes = runReadOnlyGitString(
            ["-c", "core.quotePath=false", "diff", "--no-renames", "--numstat", effectiveRef, "--"],
            cwd: worktreePath,
            environment: environment
        )
        if numstatRes.exitCode == 0 {
            for line in numstatRes.stdout.split(whereSeparator: \.isNewline) {
                let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard cols.count == 3 else { continue }
                let adds = Int(cols[0]) ?? 0
                let dels = Int(cols[1]) ?? 0
                let path = String(cols[2])
                if !Self.isExcludedInternalPath(path) {
                    numstatByPath[path] = (adds, dels)
                }
            }
        }

        let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        var items: [RelayLaneOwnedFileItem] = []
        items.reserveCapacity(allPaths.count)

        for path in allPaths {
            let xy = porcelainByPath[path]
            let state: RelayOwnedFileWorktreeState = (xy != nil) ? .uncommittedInWorktree : .committedToLane
            let counts: (add: Int, del: Int)
            if let stat = numstatByPath[path] {
                counts = stat
            } else if untrackedSet.contains(path) {
                let fileURL = worktreeURL.appendingPathComponent(path)
                counts = (Self.countTextFileLinesMatchingGitNumstat(at: fileURL), 0)
            } else {
                counts = (0, 0)
            }
            items.append(
                RelayLaneOwnedFileItem(
                    relativePath: path,
                    worktreeState: state,
                    porcelainCode: xy,
                    additions: counts.add,
                    deletions: counts.del
                )
            )
        }

        return RelayLaneFileOwnershipSnapshot(
            laneID: laneID,
            worktreePath: worktreePath,
            startCommitOID: startCommitOID,
            files: items
        )
    }

    /// Reconstructs Git conflict markers for every conflicted step in `integration.merges` strictly read-only
    /// inside an isolated temporary directory via `git merge-file -p -L integration -L base -L <laneID>`,
    /// without touching `repositoryPath` or any worktree.
    public func reconstructIntegrationConflictBlocks(
        repositoryPath: String,
        integration: RelayRunIntegrationRecord,
        environment: [String: String]? = nil
    ) -> [RelayReconstructedMergeConflictBlock] {
        let sortedSteps = integration.merges.sorted {
            if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
            return $0.laneID < $1.laneID
        }

        var currentIntegrationOID = integration.baseCommitOID
        var results: [RelayReconstructedMergeConflictBlock] = []

        for step in sortedSteps {
            switch step.status {
            case .merged:
                if let mergedOID = step.mergeCommitOID, !mergedOID.isEmpty {
                    currentIntegrationOID = mergedOID
                }
            case .noChanges, .notAttempted:
                continue
            case .conflict:
                let theirsOID = step.laneCommitOID ?? ""
                var mergeBaseOID = integration.baseCommitOID
                if !repositoryPath.isEmpty,
                   FileManager.default.fileExists(atPath: repositoryPath),
                   !currentIntegrationOID.isEmpty,
                   !theirsOID.isEmpty {
                    let mbRes = runReadOnlyGitString(
                        ["merge-base", currentIntegrationOID, theirsOID],
                        cwd: repositoryPath,
                        environment: environment
                    )
                    let trimmedMB = mbRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if mbRes.exitCode == 0 && !trimmedMB.isEmpty {
                        mergeBaseOID = trimmedMB
                    }
                }

                for item in step.conflicts {
                    var conflictText: String?
                    if configuration.reconstructConflictBlocksWithGitMergeFile,
                       !repositoryPath.isEmpty,
                       FileManager.default.fileExists(atPath: repositoryPath),
                       !currentIntegrationOID.isEmpty,
                       !theirsOID.isEmpty {
                        conflictText = reconstructSingleFileConflictText(
                            repositoryPath: repositoryPath,
                            laneID: step.laneID,
                            relativePath: item.path,
                            oursCommitOID: currentIntegrationOID,
                            baseCommitOID: mergeBaseOID,
                            theirsCommitOID: theirsOID,
                            environment: environment
                        )
                    }

                    results.append(
                        RelayReconstructedMergeConflictBlock(
                            ordinal: step.ordinal,
                            laneID: step.laneID,
                            path: item.path,
                            code: item.code,
                            mergeBaseOID: mergeBaseOID,
                            oursCommitOID: currentIntegrationOID,
                            theirsCommitOID: theirsOID,
                            conflictText: conflictText
                        )
                    )
                }
            }
        }

        return results
    }

    // MARK: - Private Read-Only Git Subprocess Helpers

    private func reconstructSingleFileConflictText(
        repositoryPath: String,
        laneID: String,
        relativePath: String,
        oursCommitOID: String,
        baseCommitOID: String,
        theirsCommitOID: String,
        environment: [String: String]?
    ) -> String? {
        let oursData = readBlobData(repositoryPath: repositoryPath, revision: oursCommitOID, relativePath: relativePath, environment: environment)
        let baseData = readBlobData(repositoryPath: repositoryPath, revision: baseCommitOID, relativePath: relativePath, environment: environment)
        let theirsData = readBlobData(repositoryPath: repositoryPath, revision: theirsCommitOID, relativePath: relativePath, environment: environment)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayide-mergefile-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let oursURL = tempDir.appendingPathComponent("ours")
        let baseURL = tempDir.appendingPathComponent("base")
        let theirsURL = tempDir.appendingPathComponent("theirs")

        do {
            try oursData.write(to: oursURL, options: [.atomic])
            try baseData.write(to: baseURL, options: [.atomic])
            try theirsData.write(to: theirsURL, options: [.atomic])
        } catch {
            return nil
        }

        let mergeRes = runReadOnlyGitRawBytes(
            [
                "merge-file",
                "-p",
                "-L", "integration",
                "-L", "base",
                "-L", laneID,
                oursURL.path,
                baseURL.path,
                theirsURL.path
            ],
            cwd: tempDir.path,
            environment: environment
        )
        guard mergeRes.exitCode >= 0 && mergeRes.exitCode < 128 else {
            return nil
        }
        return String(decoding: mergeRes.stdout, as: UTF8.self)
    }

    private func readBlobData(
        repositoryPath: String,
        revision: String,
        relativePath: String,
        environment: [String: String]?
    ) -> Data {
        guard !revision.isEmpty else { return Data() }
        let res = runReadOnlyGitRawBytes(
            ["cat-file", "blob", "\(revision):\(relativePath)"],
            cwd: repositoryPath,
            environment: environment
        )
        return (res.exitCode == 0) ? res.stdout : Data()
    }

    private static func countTextFileLinesMatchingGitNumstat(at fileURL: URL) -> Int {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return 0
        }
        let sampleCount = min(8000, data.count)
        if data.prefix(sampleCount).contains(0x00) {
            return 0
        }
        var newlineCount = 0
        for byte in data where byte == 0x0A {
            newlineCount += 1
        }
        if data.last != 0x0A {
            newlineCount += 1
        }
        return newlineCount
    }

    private func runReadOnlyGitString(
        _ subcommandArguments: [String],
        cwd: String,
        environment: [String: String]?
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let raw = runReadOnlyGitRawBytes(subcommandArguments, cwd: cwd, environment: environment)
        return (raw.exitCode, String(decoding: raw.stdout, as: UTF8.self), raw.stderr)
    }

    private func runReadOnlyGitRawBytes(
        _ subcommandArguments: [String],
        cwd: String,
        environment: [String: String]?
    ) -> (exitCode: Int32, stdout: Data, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gitExecutablePath)
        proc.arguments = ["--no-optional-locks"] + subcommandArguments
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var env = environment ?? ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return (-1, Data(), error.localizedDescription)
        }

        final class DataBox: @unchecked Sendable { var data = Data() }
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        proc.waitUntilExit()
        group.wait()

        return (
            exitCode: proc.terminationStatus,
            stdout: outBox.data,
            stderr: String(decoding: errBox.data, as: UTF8.self)
        )
    }
}

// MARK: - Live Per-Lane Worktree FSEvents File-Ownership Watcher

public final class RelayWorktreeOwnershipLiveWatcher: @unchecked Sendable {
    private final class WeakWatcherBox {
        weak var watcher: RelayWorktreeOwnershipLiveWatcher?
        init(_ watcher: RelayWorktreeOwnershipLiveWatcher) {
            self.watcher = watcher
        }
    }

    private let inspector: RelayReadOnlyGitRunInspector
    private let configuration: RelayReadOnlyGitInspectorConfiguration
    private let environment: [String: String]?
    private let onUpdate: @Sendable ([String: RelayLaneFileOwnershipSnapshot]) -> Void
    private let queue = DispatchQueue(label: "io.relayide.worktree-ownership-live-watcher", qos: .userInteractive)

    private var isStarted = false
    private var streamRef: FSEventStreamRef?
    private var watchedStreamPaths: [String] = []
    private var targets: [RelayWatchedLaneWorktreeTarget]
    private var canonicalWorktreeByLane: [String: String] = [:]
    private var canonicalRepoGitDir: String?
    private var repositoryPath: String?
    private var cachedSnapshots: [String: RelayLaneFileOwnershipSnapshot] = [:]

    public init(
        targets: [RelayWatchedLaneWorktreeTarget],
        repositoryPath: String? = nil,
        configuration: RelayReadOnlyGitInspectorConfiguration = RelayReadOnlyGitInspectorConfiguration(),
        gitExecutablePath: String = "/usr/bin/git",
        environment: [String: String]? = nil,
        onUpdate: @escaping @Sendable ([String: RelayLaneFileOwnershipSnapshot]) -> Void
    ) {
        self.targets = targets
        self.repositoryPath = repositoryPath
        self.configuration = configuration
        self.inspector = RelayReadOnlyGitRunInspector(
            gitExecutablePath: gitExecutablePath,
            configuration: configuration
        )
        self.environment = environment
        self.onUpdate = onUpdate
    }

    deinit {
        if let stream = streamRef {
            streamRef = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            self.rebuildStreamIfNeededOnQueue()
            self.recomputeLanesOnQueue(laneIDs: Set(self.targets.map(\.laneID)), forceEmit: true)
        }
    }

    public func stop() {
        queue.sync {
            guard isStarted else { return }
            isStarted = false
            teardownStreamOnQueue()
        }
    }

    public func updateTargets(_ newTargets: [RelayWatchedLaneWorktreeTarget], repositoryPath newRepoPath: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let prevByID = Dictionary(uniqueKeysWithValues: self.targets.map { ($0.laneID, $0) })
            self.targets = newTargets
            if let newRepoPath, !newRepoPath.isEmpty {
                self.repositoryPath = newRepoPath
            }
            guard self.isStarted else { return }

            let activeIDs = Set(newTargets.map(\.laneID))
            for staleID in Array(self.cachedSnapshots.keys) where !activeIDs.contains(staleID) {
                self.cachedSnapshots.removeValue(forKey: staleID)
            }

            var dirtyIDs = Set<String>()
            for t in newTargets {
                if prevByID[t.laneID] != t || self.cachedSnapshots[t.laneID] == nil {
                    dirtyIDs.insert(t.laneID)
                }
            }

            self.rebuildStreamIfNeededOnQueue()
            if !dirtyIDs.isEmpty {
                self.recomputeLanesOnQueue(laneIDs: dirtyIDs, forceEmit: false)
            }
        }
    }

    public func refreshNow() {
        queue.async { [weak self] in
            guard let self, self.isStarted else { return }
            self.rebuildStreamIfNeededOnQueue()
            self.recomputeLanesOnQueue(laneIDs: Set(self.targets.map(\.laneID)), forceEmit: true)
        }
    }

    // MARK: - Serial Queue Implementation

    private static func canonicalPath(_ rawPath: String) -> String {
        let resolved = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().standardizedFileURL.path
        if resolved.hasPrefix("/var/") {
            return "/private" + resolved
        }
        if resolved.hasPrefix("/tmp/") {
            return "/private" + resolved
        }
        return resolved
    }

    private func teardownStreamOnQueue() {
        if let stream = streamRef {
            streamRef = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        watchedStreamPaths = []
    }

    private func rebuildStreamIfNeededOnQueue() {
        var canonMap: [String: String] = [:]
        var desiredRoots: [String] = []

        for t in targets where !t.worktreePath.isEmpty && FileManager.default.fileExists(atPath: t.worktreePath) {
            let canon = Self.canonicalPath(t.worktreePath)
            canonMap[t.laneID] = canon
            if !desiredRoots.contains(canon) {
                desiredRoots.append(canon)
            }
        }
        canonicalWorktreeByLane = canonMap

        canonicalRepoGitDir = nil
        if let repo = repositoryPath, !repo.isEmpty {
            let gitDir = (repo as NSString).appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitDir) {
                let canonGit = Self.canonicalPath(gitDir)
                canonicalRepoGitDir = canonGit
                for sub in ["worktrees", "refs"] {
                    let subPath = (canonGit as NSString).appendingPathComponent(sub)
                    if FileManager.default.fileExists(atPath: subPath), !desiredRoots.contains(subPath) {
                        desiredRoots.append(subPath)
                    }
                }
            }
        }

        desiredRoots.sort()
        guard configuration.observeWorktreeFileSystemEvents else {
            teardownStreamOnQueue()
            return
        }
        if desiredRoots == watchedStreamPaths && streamRef != nil {
            return
        }

        teardownStreamOnQueue()
        guard !desiredRoots.isEmpty else { return }

        let box = WeakWatcherBox(self)
        let retained = Unmanaged.passRetained(box)
        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<WeakWatcherBox>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<WeakWatcherBox>.fromOpaque(info).takeUnretainedValue()
            guard let watcher = box.watcher else { return }
            let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
            var paths: [String] = []
            paths.reserveCapacity(numEvents)
            for idx in 0..<numEvents {
                if let rawPtr = CFArrayGetValueAtIndex(cfArray, idx) {
                    paths.append(unsafeBitCast(rawPtr, to: CFString.self) as String)
                }
            }
            watcher.handleFSEventsOnQueue(paths: paths)
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
            desiredRoots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            configuration.fsEventsLatencySeconds,
            flags
        ) {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            streamRef = stream
            watchedStreamPaths = desiredRoots
        } else {
            retained.release()
        }
    }

    private func handleFSEventsOnQueue(paths: [String]) {
        guard isStarted, configuration.observeWorktreeFileSystemEvents else { return }
        var dirtyLanes = Set<String>()

        for raw in paths {
            let canonEvent = Self.canonicalPath(raw)
            if canonEvent.hasSuffix(".lock") {
                continue
            }

            var matchedWorktree = false
            for (laneID, canonWT) in canonicalWorktreeByLane {
                if canonEvent == canonWT {
                    dirtyLanes.insert(laneID)
                    matchedWorktree = true
                } else if canonEvent.hasPrefix(canonWT + "/") {
                    let rel = String(canonEvent.dropFirst(canonWT.count + 1))
                    if !RelayReadOnlyGitRunInspector.isExcludedInternalPath(rel) {
                        dirtyLanes.insert(laneID)
                    }
                    matchedWorktree = true
                }
            }

            if !matchedWorktree, let canonGit = canonicalRepoGitDir, canonEvent.hasPrefix(canonGit + "/") {
                let gitRel = String(canonEvent.dropFirst(canonGit.count + 1))
                if gitRel.hasPrefix("worktrees/") || gitRel.hasPrefix("refs/") {
                    for t in targets {
                        dirtyLanes.insert(t.laneID)
                    }
                }
            }
        }

        if !dirtyLanes.isEmpty {
            recomputeLanesOnQueue(laneIDs: dirtyLanes, forceEmit: false)
        }
    }

    private func recomputeLanesOnQueue(laneIDs: Set<String>, forceEmit: Bool) {
        var didChange = false
        for target in targets where laneIDs.contains(target.laneID) {
            let fresh = inspector.inspectLaneFileOwnership(
                laneID: target.laneID,
                worktreePath: target.worktreePath,
                startCommitOID: target.startCommitOID,
                environment: environment
            )
            if cachedSnapshots[target.laneID] != fresh {
                cachedSnapshots[target.laneID] = fresh
                didChange = true
            }
        }
        if didChange || forceEmit {
            onUpdate(cachedSnapshots)
        }
    }
}
