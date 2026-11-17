import Darwin
import Foundation
import RelayModels

// MARK: - POSIX `<sys/wait.h>` Status Bit Decoding

public enum POSIXWaitStatus: Sendable {
    private static let statusMask: Int32 = 0x7F     // _WSTATUS(x) = x & 0177
    private static let stoppedMarker: Int32 = 0x7F  // _WSTOPPED = 0177

    /// Equivalent to `WIFEXITED(status)`: low 7 bits are 0.
    public static func wifExited(_ rawStatus: Int32) -> Bool {
        (rawStatus & statusMask) == 0
    }

    /// Equivalent to `WEXITSTATUS(status)`: `(status >> 8) & 0xFF`.
    public static func wExitStatus(_ rawStatus: Int32) -> Int32 {
        (rawStatus >> 8) & 0xFF
    }

    /// Equivalent to `WIFSIGNALED(status)`: low 7 bits are neither 0 nor `_WSTOPPED` (`0x7F`).
    public static func wifSignaled(_ rawStatus: Int32) -> Bool {
        let low = rawStatus & statusMask
        return low != 0 && low != stoppedMarker
    }

    /// Equivalent to `WTERMSIG(status)`: `status & 0x7F` (masks out `WCOREFLAG` `0x80`).
    public static func wTermSig(_ rawStatus: Int32) -> Int32 {
        rawStatus & statusMask
    }

    /// Equivalent to `WIFSTOPPED(status)`: low 7 bits equal `0x7F` and stop signal is not `SIGCONT` (`0x13`).
    public static func wifStopped(_ rawStatus: Int32) -> Bool {
        (rawStatus & statusMask) == stoppedMarker && ((rawStatus >> 8) & 0xFF) != 0x13
    }

    /// Equivalent to `WIFCONTINUED(status)`: low 7 bits equal `0x7F` and signal byte equals `0x13`.
    public static func wifContinued(_ rawStatus: Int32) -> Bool {
        (rawStatus & statusMask) == stoppedMarker && ((rawStatus >> 8) & 0xFF) == 0x13
    }

    public static func decode(_ rawStatus: Int32) -> PTYExitReason {
        if wifExited(rawStatus) {
            return .exited(code: wExitStatus(rawStatus))
        }
        if wifSignaled(rawStatus) {
            return .signaled(signal: wTermSig(rawStatus))
        }
        return .waitFailed(errnoCode: EINVAL)
    }
}

// MARK: - Descendant Process Enumeration & Escalation Step Telemetry (R42)

@_silgen_name("proc_listchildpids")
private func darwinProcListChildPIDs(
    _ ppid: pid_t,
    _ buffer: UnsafeMutableRawPointer?,
    _ buffersize: Int32
) -> Int32

public enum PTYTerminationEscalationStep: Sendable, Equatable {
    case sentSIGINT(pid: pid_t)
    case sentSIGTERM(pid: pid_t)
    case sentSIGKILL(pid: pid_t, descendantPIDs: [pid_t], processGroupIDs: [pid_t])
}

public struct PTYTerminationEscalationReport: Sendable, Equatable {
    public let steps: [PTYTerminationEscalationStep]
    public let initialDescendantPIDs: [pid_t]
    public let initialProcessGroupIDs: [pid_t]
    public let survivingPIDs: [pid_t]
    public let enumerationSucceeded: Bool

    public init(
        steps: [PTYTerminationEscalationStep],
        initialDescendantPIDs: [pid_t],
        initialProcessGroupIDs: [pid_t],
        survivingPIDs: [pid_t],
        enumerationSucceeded: Bool
    ) {
        self.steps = steps
        self.initialDescendantPIDs = initialDescendantPIDs
        self.initialProcessGroupIDs = initialProcessGroupIDs
        self.survivingPIDs = survivingPIDs
        self.enumerationSucceeded = enumerationSucceeded
    }
}

public struct POSIXProcessIdentity: Sendable, Hashable, Equatable {
    public let pid: pid_t
    public let ppid: pid_t
    public let pgid: pid_t
    public let startTimeSec: Int
    public let startTimeUsec: Int32
    public let isZombie: Bool

    public init(
        pid: pid_t,
        ppid: pid_t,
        pgid: pid_t,
        startTimeSec: Int,
        startTimeUsec: Int32,
        isZombie: Bool = false
    ) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.startTimeSec = startTimeSec
        self.startTimeUsec = startTimeUsec
        self.isZombie = isZombie
    }

    public func matchesProcess(_ other: POSIXProcessIdentity) -> Bool {
        pid == other.pid
            && startTimeSec == other.startTimeSec
            && startTimeUsec == other.startTimeUsec
    }
}

public enum POSIXProcessTree: Sendable {
    private static let zombieProcessStat: Int8 = 5 // SZOMB in <sys/proc.h>

    /// Queries kernel `kinfo_proc` identity for a single `pid` via `sysctl(KERN_PROC_PID)` for PID-reuse verification.
    public static func processIdentity(for pid: pid_t) -> POSIXProcessIdentity? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = Darwin.sysctl(&mib, 4, &info, &size, nil, 0)
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else {
            return nil
        }
        let pgid = Darwin.getpgid(pid)
        let effectivePGID = pgid > 0 ? pgid : info.kp_eproc.e_pgid
        return POSIXProcessIdentity(
            pid: pid,
            ppid: info.kp_eproc.e_ppid,
            pgid: effectivePGID,
            startTimeSec: info.kp_proc.p_starttime.tv_sec,
            startTimeUsec: info.kp_proc.p_starttime.tv_usec,
            isZombie: info.kp_proc.p_stat == zombieProcessStat
        )
    }

    /// Queries all current members of process group `pgid` via `sysctl(KERN_PROC_PGRP)`.
    public static func membersOfProcessGroup(_ pgid: pid_t) -> [POSIXProcessIdentity] {
        guard pgid > 1 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var neededBytes: Int = 0
        guard Darwin.sysctl(&mib, 4, nil, &neededBytes, nil, 0) == 0, neededBytes > 0 else {
            return []
        }
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = max(16, (neededBytes / stride) + 16)
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var actualBytes = capacity * stride
        let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
            Darwin.sysctl(&mib, 4, raw.baseAddress, &actualBytes, nil, 0)
        }
        guard rc == 0, actualBytes >= stride else { return [] }
        let count = actualBytes / stride
        var results: [POSIXProcessIdentity] = []
        results.reserveCapacity(count)
        for idx in 0..<count {
            let kp = buffer[idx]
            let p = kp.kp_proc.p_pid
            guard p > 1 else { continue }
            let livePGID = Darwin.getpgid(p)
            let effPGID = livePGID > 0 ? livePGID : kp.kp_eproc.e_pgid
            results.append(
                POSIXProcessIdentity(
                    pid: p,
                    ppid: kp.kp_eproc.e_ppid,
                    pgid: effPGID,
                    startTimeSec: kp.kp_proc.p_starttime.tv_sec,
                    startTimeUsec: kp.kp_proc.p_starttime.tv_usec,
                    isZombie: kp.kp_proc.p_stat == zombieProcessStat
                )
            )
        }
        return results
    }

    /// Lists immediate child PIDs of `ppid` via Darwin's `proc_listchildpids` (which returns element count, not bytes),
    /// distinguishing `< 0` failure from `0` children.
    public static func directChildrenWithStatus(of ppid: pid_t) -> (pids: [pid_t], succeeded: Bool) {
        guard ppid > 1 else { return ([], true) }
        let hint = darwinProcListChildPIDs(ppid, nil, 0)
        if hint < 0 {
            if Darwin.kill(ppid, 0) != 0 && errno == ESRCH {
                return ([], true)
            }
            return ([], false)
        }
        var capacity = max(256, Int(hint) + 64)
        while capacity <= 65_536 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let byteSize = Int32(clamping: capacity * MemoryLayout<pid_t>.stride)
            let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
                darwinProcListChildPIDs(ppid, raw.baseAddress, byteSize)
            }
            if count < 0 {
                if Darwin.kill(ppid, 0) != 0 && errno == ESRCH {
                    return ([], true)
                }
                return ([], false)
            }
            if count == 0 {
                return ([], true)
            }
            if Int(count) >= capacity {
                capacity *= 2
                continue
            }
            var seen = Set<pid_t>()
            var result: [pid_t] = []
            for idx in 0..<Int(count) {
                let child = buffer[idx]
                if child > 1 && child != ppid && seen.insert(child).inserted {
                    result.append(child)
                }
            }
            return (result, true)
        }
        return ([], false)
    }

    /// Lists immediate child PIDs of `ppid` via Darwin's `proc_listchildpids` (which returns element count, not bytes).
    public static func directChildren(of ppid: pid_t) -> [pid_t] {
        directChildrenWithStatus(of: ppid).pids
    }

    /// Enumerates all descendants of `rootPID` via `proc_listchildpids` BFS, reporting whether every query succeeded.
    public static func allDescendantsViaProcListChildPIDs(of rootPID: pid_t) -> (pids: [pid_t], succeeded: Bool) {
        guard rootPID > 1 else { return ([], true) }
        var visited: Set<pid_t> = [rootPID]
        var queue: [pid_t] = [rootPID]
        var descendants: [pid_t] = []
        var allSucceeded = true
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            let step = directChildrenWithStatus(of: current)
            if !step.succeeded {
                allSucceeded = false
            }
            for child in step.pids {
                if visited.insert(child).inserted {
                    descendants.append(child)
                    queue.append(child)
                }
            }
        }
        return (descendants, allSucceeded)
    }

    /// Fallback descendant enumeration via `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)` parent-to-children BFS tree (`03-relayide.md` M2 Hypothesis 1b).
    public static func allDescendantsViaSysctl(of rootPID: pid_t) -> (pids: [pid_t], succeeded: Bool) {
        guard rootPID > 1 else { return ([], true) }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var neededBytes: Int = 0
        guard Darwin.sysctl(&mib, 3, nil, &neededBytes, nil, 0) == 0, neededBytes > 0 else {
            return ([], false)
        }
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = max(64, (neededBytes / stride) + (neededBytes / stride) / 3 + 128)
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var actualBytes = capacity * stride
        let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
            Darwin.sysctl(&mib, 3, raw.baseAddress, &actualBytes, nil, 0)
        }
        guard rc == 0, actualBytes >= stride else {
            return ([], false)
        }

        let count = actualBytes / stride
        var childrenByParent: [pid_t: [pid_t]] = [:]
        for idx in 0..<count {
            let kp = buffer[idx]
            let pid = kp.kp_proc.p_pid
            let ppid = kp.kp_eproc.e_ppid
            guard pid > 1, ppid > 0, pid != ppid else { continue }
            childrenByParent[ppid, default: []].append(pid)
        }

        var visited: Set<pid_t> = [rootPID]
        var queue: [pid_t] = [rootPID]
        var descendants: [pid_t] = []
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for child in (childrenByParent[current] ?? []).sorted() {
                if visited.insert(child).inserted {
                    descendants.append(child)
                    queue.append(child)
                }
            }
        }
        return (descendants, true)
    }

    /// Primary `proc_listchildpids` enumeration with `sysctl(KERN_PROC_ALL)` tree fallback when `proc_listchildpids` fails or is incomplete.
    public static func enumerateDescendantsWithFallback(
        of rootPID: pid_t,
        procListImpl: ((pid_t) -> (pids: [pid_t], succeeded: Bool))? = nil,
        sysctlImpl: ((pid_t) -> (pids: [pid_t], succeeded: Bool))? = nil
    ) -> (pids: [pid_t], succeeded: Bool) {
        guard rootPID > 1 else { return ([], true) }
        let procFn = procListImpl ?? { allDescendantsViaProcListChildPIDs(of: $0) }
        let sysctlFn = sysctlImpl ?? { allDescendantsViaSysctl(of: $0) }

        let primary = procFn(rootPID)
        if primary.succeeded {
            // If `proc_listchildpids` succeeded, also check sysctl when using default implementations only if primary returned empty
            // or union seamlessly when fallback is triggered.
            if procListImpl == nil && sysctlImpl == nil {
                let secondary = sysctlFn(rootPID)
                if secondary.succeeded && secondary.pids.count > primary.pids.count {
                    var seen = Set<pid_t>(primary.pids)
                    var merged = primary.pids
                    for p in secondary.pids where seen.insert(p).inserted {
                        merged.append(p)
                    }
                    return (merged, true)
                }
            }
            return (primary.pids, true)
        }

        let fallback = sysctlFn(rootPID)
        if fallback.succeeded {
            var seen = Set<pid_t>(primary.pids)
            var merged = primary.pids
            for p in fallback.pids where seen.insert(p).inserted {
                merged.append(p)
            }
            return (merged, true)
        }

        return (primary.pids, false)
    }

    /// Recursively enumerates all descendants of `rootPID` (across `setsid` and `setpgid` boundaries) via BFS + `sysctl` fallback.
    public static func allDescendants(of rootPID: pid_t) -> [pid_t] {
        enumerateDescendantsWithFallback(of: rootPID).pids
    }

    /// Collects unique process group IDs (`getpgid`) for `pids`, excluding `<= 1` and `excludingProcessGroup`.
    public static func processGroupIDs(
        for pids: [pid_t],
        excludingProcessGroup: pid_t = Darwin.getpgrp()
    ) -> [pid_t] {
        var seen = Set<pid_t>()
        var groups: [pid_t] = []
        for pid in pids where pid > 1 {
            let pgid = Darwin.getpgid(pid)
            if pgid > 1 && pgid != excludingProcessGroup && seen.insert(pgid).inserted {
                groups.append(pgid)
            }
        }
        return groups
    }

    /// Filters candidate process groups against PID reuse: only retains groups in `collectedGroups` that STILL contain
    /// at least one non-zombie process whose `(pid, startTime)` matches a recorded `POSIXProcessIdentity` and whose current
    /// `pgid` is still in `collectedGroups`.
    public static func activeVerifiedProcessGroups(
        collectedGroups: [pid_t],
        trackedMembers: [pid_t: POSIXProcessIdentity],
        excludingProcessGroup: pid_t = Darwin.getpgrp(),
        identityProvider: (pid_t) -> POSIXProcessIdentity? = { processIdentity(for: $0) }
    ) -> [pid_t] {
        let allowedSet = Set(collectedGroups.filter { $0 > 1 && $0 != excludingProcessGroup })
        guard !allowedSet.isEmpty else { return [] }

        var verifiedLiveGroups = Set<pid_t>()
        for (pid, recorded) in trackedMembers {
            guard let live = identityProvider(pid),
                  !live.isZombie,
                  recorded.matchesProcess(live),
                  live.pgid > 1,
                  live.pgid != excludingProcessGroup,
                  allowedSet.contains(live.pgid)
            else {
                continue
            }
            verifiedLiveGroups.insert(live.pgid)
        }
        return collectedGroups.filter { verifiedLiveGroups.contains($0) }
    }
}

// MARK: - Internal Reaper-Safe Session State

private final class PTYSessionState: @unchecked Sendable {
    let laneID: String
    let screenBuffer: VT100TerminalScreenBuffer
    let updatesScreenBuffer: Bool
    let ioQueue: DispatchQueue
    let condition = NSCondition()

    var masterFD: Int32 = -1
    var rawOutputFD: Int32 = -1
    var rawOutputMaxBytes: UInt64? = nil
    var rawTranscriptBytesWrittenCount: UInt64 = 0
    var rawTranscriptTruncatedFlag: Bool = false
    var childPID: pid_t = -1
    var isRunningFlag: Bool = false
    var isSpawningFlag: Bool = false
    var exitStatusValue: Int32?
    var terminationSignalValue: Int32?
    var exitReasonValue: PTYExitReason?
    var bytesReadCount: UInt64 = 0
    var bytesWrittenCount: UInt64 = 0
    var startedAtDate: Date = Date()
    var readSource: DispatchSourceRead?
    var onOutputUpdate: (@Sendable (TerminalViewportSnapshot) -> Void)?

    init(laneID: String, rows: Int, columns: Int, updatesScreenBuffer: Bool = true) {
        self.laneID = laneID
        self.screenBuffer = VT100TerminalScreenBuffer(laneID: laneID, rows: rows, columns: columns)
        self.updatesScreenBuffer = updatesScreenBuffer
        self.ioQueue = DispatchQueue(label: "io.github.zxu756.RelayIDE.pty.\(laneID)", qos: .userInteractive)
    }

    @discardableResult
    private static func writeAllVerbatim(fd: Int32, data: Data) -> Int {
        guard fd >= 0, !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return 0 }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            return offset
        }
    }

    func drainAvailableMasterOutput() {
        condition.lock()
        let fd = masterFD
        let rfd = rawOutputFD
        let maxBytes = rawOutputMaxBytes
        let alreadyWritten = rawTranscriptBytesWrittenCount
        let alreadyTruncated = rawTranscriptTruncatedFlag
        condition.unlock()
        guard fd >= 0 else { return }

        var chunk = [UInt8](repeating: 0, count: 16_384)
        var aggregated = Data()
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                aggregated.append(contentsOf: chunk[0..<n])
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }

        if !aggregated.isEmpty {
            var writtenThisDrain = 0
            var didTruncate = false
            if rfd >= 0 {
                if let cap = maxBytes {
                    if alreadyTruncated || alreadyWritten >= cap {
                        didTruncate = true
                    } else {
                        let remaining = cap - alreadyWritten
                        if UInt64(aggregated.count) <= remaining {
                            writtenThisDrain = Self.writeAllVerbatim(fd: rfd, data: aggregated)
                        } else {
                            let slice = Data(aggregated.prefix(Int(remaining)))
                            writtenThisDrain = Self.writeAllVerbatim(fd: rfd, data: slice)
                            didTruncate = true
                        }
                    }
                } else {
                    writtenThisDrain = Self.writeAllVerbatim(fd: rfd, data: aggregated)
                }
            }

            condition.lock()
            bytesReadCount += UInt64(aggregated.count)
            if writtenThisDrain > 0 {
                rawTranscriptBytesWrittenCount += UInt64(writtenThisDrain)
            }
            if didTruncate {
                rawTranscriptTruncatedFlag = true
            }
            let cb = onOutputUpdate
            condition.unlock()

            if updatesScreenBuffer {
                screenBuffer.feed(aggregated)
                if let cb {
                    cb(screenBuffer.snapshot())
                }
            }
        }
    }

    func finalizeChildExit(reason: PTYExitReason) {
        ioQueue.async {
            self.drainAvailableMasterOutput()
            self.condition.lock()
            let rfd = self.rawOutputFD
            self.rawOutputFD = -1
            self.condition.unlock()
            if rfd >= 0 {
                Darwin.close(rfd)
            }

            self.condition.lock()
            self.isRunningFlag = false
            self.exitReasonValue = reason
            self.exitStatusValue = reason.exitCode
            self.terminationSignalValue = reason.terminationSignal
            let src = self.readSource
            self.readSource = nil
            self.masterFD = -1
            let cb = self.onOutputUpdate
            self.condition.broadcast()
            self.condition.unlock()

            src?.cancel()
            if let cb {
                cb(self.screenBuffer.snapshot())
            }
        }
    }

    func waitForExit(timeout: TimeInterval? = nil) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if let timeout {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while isRunningFlag {
                if !condition.wait(until: deadline) {
                    break
                }
            }
        } else {
            while isRunningFlag {
                condition.wait()
            }
        }
        return !isRunningFlag
    }
}

// MARK: - POSIX Pseudo-Terminal (`posix_openpt` / `grantpt` / `unlockpt` / `ptsname` + `posix_spawn`) Multiplexer

public final class POSIXPseudoTerminalSession: @unchecked Sendable {
    private static let ptyOpenLock = NSLock()

    public let laneID: String
    public var screenBuffer: VT100TerminalScreenBuffer { state.screenBuffer }

    private let state: PTYSessionState

    public var onOutputUpdate: (@Sendable (TerminalViewportSnapshot) -> Void)? {
        get {
            state.condition.lock()
            defer { state.condition.unlock() }
            return state.onOutputUpdate
        }
        set {
            state.condition.lock()
            state.onOutputUpdate = newValue
            state.condition.unlock()
        }
    }

    public init(laneID: String, rows: Int = 28, columns: Int = 100, updatesScreenBuffer: Bool = true) {
        self.laneID = laneID
        self.state = PTYSessionState(laneID: laneID, rows: rows, columns: columns, updatesScreenBuffer: updatesScreenBuffer)
    }

    deinit {
        terminate()
        state.condition.lock()
        state.onOutputUpdate = nil
        state.condition.unlock()
    }

    /// Spawns an interactive or headless child process attached to a real POSIX pseudo-terminal (`TIOCSCTTY` + `winsize`).
    public func spawn(
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        baseEnvironment: [String: String]? = nil,
        environmentOverrides: [String: String] = [:],
        unsetEnvironmentKeys: Set<String> = [],
        rawOutputFilePath: String? = nil,
        rawOutputMaxBytes: UInt64? = nil,
        preserveEnvironmentVerbatim: Bool = false
    ) throws {
        state.condition.lock()
        if state.isRunningFlag || state.isSpawningFlag {
            let activePID = state.childPID
            state.condition.unlock()
            throw RelayIDEError.ptySessionAlreadyRunning(laneID: laneID, pid: activePID)
        }
        state.isSpawningFlag = true
        state.condition.unlock()

        var didTransitionToRunning = false
        defer {
            if !didTransitionToRunning {
                state.condition.lock()
                state.isSpawningFlag = false
                state.condition.unlock()
            }
        }

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw RelayIDEError.processSpawnFailed(executable: executablePath, reason: "Executable not found or lacks +x permission")
        }

        var openedRawFD: Int32 = -1
        if let rawPath = rawOutputFilePath {
            let parentDir = URL(fileURLWithPath: rawPath).deletingLastPathComponent()
            if !parentDir.path.isEmpty {
                try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            openedRawFD = rawPath.withCString { cPath in
                Darwin.open(cPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            }
            guard openedRawFD >= 0 else {
                let code = errno
                throw RelayIDEError.rawTranscriptOpenFailed(
                    path: rawPath,
                    errnoCode: code,
                    message: String(cString: strerror(code))
                )
            }
        }

        // Serialize `posix_openpt` + `FD_CLOEXEC` + `ptsname` + slave `O_CLOEXEC` open so concurrent
        // `Process.run()` / `posix_spawn` calls can neither race `ptsname`'s static buffer nor inherit
        // another lane's PTY master FD across sibling sessions.
        let mfd: Int32
        let sfd: Int32
        Self.ptyOpenLock.lock()
        let allocatedMaster = Darwin.posix_openpt(O_RDWR | O_NOCTTY)
        if allocatedMaster < 0 {
            let code = errno
            Self.ptyOpenLock.unlock()
            if openedRawFD >= 0 { Darwin.close(openedRawFD) }
            throw RelayIDEError.ptyAllocationFailed(errnoCode: code, message: String(cString: strerror(code)))
        }
        let existingFDFlags = fcntl(allocatedMaster, F_GETFD)
        _ = fcntl(allocatedMaster, F_SETFD, (existingFDFlags >= 0 ? existingFDFlags : 0) | FD_CLOEXEC)

        guard Darwin.grantpt(allocatedMaster) == 0,
              Darwin.unlockpt(allocatedMaster) == 0,
              let slaveNamePtr = Darwin.ptsname(allocatedMaster)
        else {
            let code = errno
            Darwin.close(allocatedMaster)
            Self.ptyOpenLock.unlock()
            if openedRawFD >= 0 { Darwin.close(openedRawFD) }
            throw RelayIDEError.ptyAllocationFailed(errnoCode: code, message: String(cString: strerror(code)))
        }

        let slavePath = String(cString: slaveNamePtr)
        let allocatedSlave = Darwin.open(slavePath, O_RDWR | O_CLOEXEC)
        Self.ptyOpenLock.unlock()

        guard allocatedSlave >= 0 else {
            let code = errno
            Darwin.close(allocatedMaster)
            if openedRawFD >= 0 { Darwin.close(openedRawFD) }
            throw RelayIDEError.ptyAllocationFailed(errnoCode: code, message: String(cString: strerror(code)))
        }
        mfd = allocatedMaster
        sfd = allocatedSlave

        var ws = winsize(
            ws_row: UInt16(clamping: screenBuffer.rows),
            ws_col: UInt16(clamping: screenBuffer.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(mfd, TIOCSWINSZ, &ws)

        // Configure `posix_spawn_file_actions_t` & `posix_spawnattr_t` with `POSIX_SPAWN_CLOEXEC_DEFAULT`
        // so only `0, 1, 2` (dup'd from the slave PTY) are inherited by the child.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, sfd, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, sfd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, sfd, STDERR_FILENO)
        posix_spawn_file_actions_addinherit_np(&fileActions, STDIN_FILENO)
        posix_spawn_file_actions_addinherit_np(&fileActions, STDOUT_FILENO)
        posix_spawn_file_actions_addinherit_np(&fileActions, STDERR_FILENO)
        if let wd = workingDirectory {
            _ = wd.withCString { cwd in
                posix_spawn_file_actions_addchdir_np(&fileActions, cwd)
            }
        }

        var spawnAttrs: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttrs)
        defer { posix_spawnattr_destroy(&spawnAttrs) }
        var defaultSigs: sigset_t = 0
        sigfillset(&defaultSigs)
        _ = posix_spawnattr_setsigdefault(&spawnAttrs, &defaultSigs)
        var emptyMask: sigset_t = 0
        sigemptyset(&emptyMask)
        _ = posix_spawnattr_setsigmask(&spawnAttrs, &emptyMask)
        _ = posix_spawnattr_setflags(
            &spawnAttrs,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )

        // Build argv & envp
        var mergedEnv = baseEnvironment ?? ProcessInfo.processInfo.environment
        for k in unsetEnvironmentKeys {
            mergedEnv.removeValue(forKey: k)
        }
        if !preserveEnvironmentVerbatim {
            mergedEnv["TERM"] = "xterm-256color"
            mergedEnv["COLORTERM"] = "truecolor"
            mergedEnv["LANG"] = mergedEnv["LANG"] ?? "en_US.UTF-8"
        }
        for (k, v) in environmentOverrides {
            mergedEnv[k] = v
        }

        let allArgs = [executablePath] + arguments
        let cArgs: [UnsafeMutablePointer<CChar>?] = allArgs.map { strdup($0) } + [nil]
        defer { cArgs.forEach { if let p = $0 { free(p) } } }

        let envStrings = mergedEnv.map { "\($0.key)=\($0.value)" }
        let cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer { cEnv.forEach { if let p = $0 { free(p) } } }

        var pid: pid_t = 0
        let spawnRC = executablePath.withCString { exeCStr in
            posix_spawn(&pid, exeCStr, &fileActions, &spawnAttrs, cArgs, cEnv)
        }
        Darwin.close(sfd)

        guard spawnRC == 0 else {
            Darwin.close(mfd)
            if openedRawFD >= 0 { Darwin.close(openedRawFD) }
            throw RelayIDEError.processSpawnFailed(
                executable: executablePath,
                reason: String(cString: strerror(spawnRC))
            )
        }

        // Put master FD into non-blocking mode for DispatchSourceRead
        let flags = fcntl(mfd, F_GETFL)
        _ = fcntl(mfd, F_SETFL, flags | O_NONBLOCK)

        let capturedState = self.state
        let source = DispatchSource.makeReadSource(fileDescriptor: mfd, queue: capturedState.ioQueue)
        source.setEventHandler {
            capturedState.drainAvailableMasterOutput()
        }
        source.setCancelHandler {
            Darwin.close(mfd)
        }

        var initialRawBytes: UInt64 = 0
        if openedRawFD >= 0 {
            var st = Darwin.stat()
            if Darwin.fstat(openedRawFD, &st) == 0 && st.st_size > 0 {
                initialRawBytes = UInt64(st.st_size)
            }
        }

        capturedState.condition.lock()
        capturedState.masterFD = mfd
        capturedState.rawOutputFD = openedRawFD
        capturedState.rawOutputMaxBytes = rawOutputMaxBytes
        capturedState.rawTranscriptBytesWrittenCount = initialRawBytes
        capturedState.rawTranscriptTruncatedFlag = (rawOutputMaxBytes != nil && initialRawBytes > rawOutputMaxBytes!)
        capturedState.childPID = pid
        capturedState.isRunningFlag = true
        capturedState.isSpawningFlag = false
        didTransitionToRunning = true
        capturedState.exitStatusValue = nil
        capturedState.terminationSignalValue = nil
        capturedState.exitReasonValue = nil
        capturedState.bytesReadCount = 0
        capturedState.bytesWrittenCount = 0
        capturedState.startedAtDate = Date()
        capturedState.readSource = source
        capturedState.condition.unlock()

        source.resume()

        // Background exit reaper with EINTR retry and POSIX <sys/wait.h> bit decoding
        let spawnedPID = pid
        DispatchQueue.global(qos: .utility).async {
            let reason = Self.waitForChildExit(pid: spawnedPID)
            capturedState.finalizeChildExit(reason: reason)
        }
    }

    public static func waitForChildExit(
        pid: pid_t,
        waitpidImpl: (pid_t, UnsafeMutablePointer<Int32>?, Int32) -> (rc: pid_t, err: Int32) = { p, st, opts in
            let rc = Darwin.waitpid(p, st, opts)
            return (rc, rc < 0 ? errno : 0)
        }
    ) -> PTYExitReason {
        while true {
            var status: Int32 = 0
            let (rc, err) = waitpidImpl(pid, &status, 0)
            if rc == pid {
                if POSIXWaitStatus.wifStopped(status) || POSIXWaitStatus.wifContinued(status) {
                    continue
                }
                return POSIXWaitStatus.decode(status)
            }
            if rc < 0 && err == EINTR {
                continue
            }
            return .waitFailed(errnoCode: err)
        }
    }

    public func writeInput(_ data: Data) {
        state.condition.lock()
        let fd = state.masterFD
        let running = state.isRunningFlag
        state.condition.unlock()
        guard running, fd >= 0, !data.isEmpty else { return }

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if n > 0 {
                    offset += n
                    state.condition.lock()
                    state.bytesWrittenCount += UInt64(n)
                    state.condition.unlock()
                } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    usleep(500)
                } else {
                    break
                }
            }
        }
    }

    public func sendText(_ text: String, asPaste: Bool = false) {
        let snap = screenBuffer.snapshot()
        if asPaste && snap.bracketedPasteEnabled {
            writeInput(Data("\u{1B}[200~\(text)\u{1B}[201~".utf8))
        } else {
            writeInput(Data(text.utf8))
        }
    }

    public func resizeTerminal(rows: Int, columns: Int) {
        screenBuffer.resize(rows: rows, columns: columns)
        state.condition.lock()
        let fd = state.masterFD
        state.condition.unlock()
        guard fd >= 0 else { return }
        var ws = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(fd, TIOCSWINSZ, &ws)
    }

    /// Sends `sig` to the child's process group (`-pid`) without blocking.
    public func sendSignalToProcessGroup(_ sig: Int32) {
        state.condition.lock()
        let pid = state.childPID
        let running = state.isRunningFlag
        state.condition.unlock()
        guard running, pid > 0 else { return }
        if Darwin.kill(-pid, sig) != 0 && errno == ESRCH {
            _ = Darwin.kill(pid, sig)
        }
    }

    /// Current spawned child PID (`-1` if not yet spawned).
    public var childProcessID: pid_t {
        state.condition.lock()
        defer { state.condition.unlock() }
        return state.childPID
    }

    /// Waits until the spawned child has exited, been reaped, and flushed its final PTY output.
    /// Returns `true` if the session is no longer running, or `false` if `timeout` elapsed first.
    @discardableResult
    public func waitForExit(timeout: TimeInterval? = nil) -> Bool {
        state.waitForExit(timeout: timeout)
    }

    /// Non-blocking async wait that resolves once the child has exited, been reaped, and closed its `.pty` transcript.
    public func awaitExit() async -> PTYExitReason {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = self.state.waitForExit(timeout: nil)
                let reason = self.metrics().exitReason ?? .waitFailed(errnoCode: ECHILD)
                continuation.resume(returning: reason)
            }
        }
    }

    /// Closes the PTY master descriptor without sending signals via `kill()`, matching kernel FD teardown when RelayIDE crashes (`SIGKILL`).
    public func closeMasterFDSimulatingCrash() {
        state.condition.lock()
        let src = state.readSource
        state.readSource = nil
        let fd = state.masterFD
        state.masterFD = -1
        state.condition.unlock()

        if let src {
            src.cancel()
        } else if fd >= 0 {
            Darwin.close(fd)
        }
    }

    /// Escalates `SIGINT -> wait(sigintGraceSeconds) -> SIGTERM -> wait(sigtermGraceSeconds) -> SIGKILL`,
    /// collecting all descendants and their process groups BEFORE sending the first signal (`03-relayide.md` M2 §6, R42, R54).
    @discardableResult
    public func terminateWithEscalation(
        sigintGraceSeconds: TimeInterval = 10.0,
        sigtermGraceSeconds: TimeInterval = 5.0,
        onStep: (@Sendable (PTYTerminationEscalationStep) -> Void)? = nil
    ) -> [PTYTerminationEscalationStep] {
        terminateWithEscalationReport(
            sigintGraceSeconds: sigintGraceSeconds,
            sigtermGraceSeconds: sigtermGraceSeconds,
            onStep: onStep
        ).steps
    }

    /// Full escalation ladder returning step trace, collected groups/descendants, enumeration status, and any surviving PIDs.
    @discardableResult
    public func terminateWithEscalationReport(
        sigintGraceSeconds: TimeInterval = 10.0,
        sigtermGraceSeconds: TimeInterval = 5.0,
        descendantEnumerator: ((pid_t) -> (pids: [pid_t], succeeded: Bool))? = nil,
        onStep: (@Sendable (PTYTerminationEscalationStep) -> Void)? = nil
    ) -> PTYTerminationEscalationReport {
        state.condition.lock()
        let pid = state.childPID
        let running = state.isRunningFlag
        state.condition.unlock()

        guard running, pid > 0 else {
            return PTYTerminationEscalationReport(
                steps: [],
                initialDescendantPIDs: [],
                initialProcessGroupIDs: [],
                survivingPIDs: [],
                enumerationSucceeded: true
            )
        }

        let callerPGID = Darwin.getpgrp()
        let selfPID = Darwin.getpid()

        // R54: Collect ALL descendants and their process groups BEFORE sending the very first signal (`SIGINT`),
        // because `pid` (e.g. `/bin/sh` in `verify`) may exit immediately on `SIGINT`, reparenting any `setpgrp`
        // descendant to `launchd` (PID 1) before `SIGKILL` would ever be reached.
        let enumResult = (descendantEnumerator ?? { POSIXProcessTree.enumerateDescendantsWithFallback(of: $0) })(pid)
        let enumerationSucceeded = enumResult.succeeded
        var allDiscoveredDescendants: [pid_t] = enumResult.pids
        var discoveredDescendantSet = Set<pid_t>(allDiscoveredDescendants)

        var collectedGroups = POSIXProcessTree.processGroupIDs(
            for: [pid] + allDiscoveredDescendants,
            excludingProcessGroup: callerPGID
        )
        if pid > 1 && pid != callerPGID && Darwin.getpgid(pid) == pid && !collectedGroups.contains(pid) {
            collectedGroups.insert(pid, at: 0)
        }

        var trackedMembers: [pid_t: POSIXProcessIdentity] = [:]
        for candidate in [pid] + allDiscoveredDescendants where candidate > 1 && candidate != selfPID {
            if let identity = POSIXProcessTree.processIdentity(for: candidate) {
                trackedMembers[candidate] = identity
            }
        }
        for pgid in collectedGroups {
            for member in POSIXProcessTree.membersOfProcessGroup(pgid) where member.pid != selfPID {
                if trackedMembers[member.pid] == nil {
                    trackedMembers[member.pid] = member
                }
                if member.pid != pid && discoveredDescendantSet.insert(member.pid).inserted {
                    allDiscoveredDescendants.append(member.pid)
                }
            }
        }

        let initialDescendantPIDs = allDiscoveredDescendants
        let initialProcessGroupIDs = collectedGroups

        func refreshTrackedTree() {
            let currentlyVerified = POSIXProcessTree.activeVerifiedProcessGroups(
                collectedGroups: collectedGroups,
                trackedMembers: trackedMembers,
                excludingProcessGroup: callerPGID
            )
            for pgid in currentlyVerified {
                for member in POSIXProcessTree.membersOfProcessGroup(pgid) where member.pid != selfPID {
                    if trackedMembers[member.pid] == nil {
                        trackedMembers[member.pid] = member
                    }
                    if member.pid != pid && discoveredDescendantSet.insert(member.pid).inserted {
                        allDiscoveredDescendants.append(member.pid)
                    }
                }
            }
            for (memberPID, recorded) in Array(trackedMembers) {
                guard let live = POSIXProcessTree.processIdentity(for: memberPID),
                      !live.isZombie,
                      recorded.matchesProcess(live)
                else {
                    continue
                }
                if live.pgid > 1 && live.pgid != callerPGID && !collectedGroups.contains(live.pgid) {
                    collectedGroups.append(live.pgid)
                }
                let childStep = POSIXProcessTree.directChildrenWithStatus(of: memberPID)
                for childPID in childStep.pids where childPID > 1 && childPID != selfPID {
                    if trackedMembers[childPID] == nil,
                       let childID = POSIXProcessTree.processIdentity(for: childPID) {
                        trackedMembers[childPID] = childID
                        if childPID != pid && discoveredDescendantSet.insert(childPID).inserted {
                            allDiscoveredDescendants.append(childPID)
                        }
                        if childID.pgid > 1 && childID.pgid != callerPGID && !collectedGroups.contains(childID.pgid) {
                            collectedGroups.append(childID.pgid)
                        }
                    }
                }
            }
        }

        func sendSignalToVerifiedGroups(_ sig: Int32) {
            refreshTrackedTree()
            let activeGroups = POSIXProcessTree.activeVerifiedProcessGroups(
                collectedGroups: collectedGroups,
                trackedMembers: trackedMembers,
                excludingProcessGroup: callerPGID
            )
            for pgid in activeGroups {
                if Darwin.kill(-pgid, sig) != 0 && errno == ESRCH && pgid == pid {
                    state.condition.lock()
                    let stillRunning = state.isRunningFlag
                    state.condition.unlock()
                    if stillRunning {
                        _ = Darwin.kill(pid, sig)
                    }
                }
            }
            if activeGroups.isEmpty {
                state.condition.lock()
                let stillRunning = state.isRunningFlag
                state.condition.unlock()
                if stillRunning && pid != callerPGID && pid != selfPID {
                    if Darwin.kill(-pid, sig) != 0 && errno == ESRCH {
                        _ = Darwin.kill(pid, sig)
                    }
                }
            }
        }

        func waitUntilSessionAndAllCollectedGroupsEmpty(timeout: TimeInterval) -> Bool {
            let deadline = Date(timeIntervalSinceNow: max(0.0, timeout))
            while true {
                refreshTrackedTree()
                let activeGroups = POSIXProcessTree.activeVerifiedProcessGroups(
                    collectedGroups: collectedGroups,
                    trackedMembers: trackedMembers,
                    excludingProcessGroup: callerPGID
                )
                state.condition.lock()
                let sessionStillRunning = state.isRunningFlag
                state.condition.unlock()

                if !sessionStillRunning && activeGroups.isEmpty {
                    // Confirm kernel group table drain for any group that just emptied
                    for pgid in collectedGroups {
                        Self.waitBrieflyForProcessGroupDrain(pgid: pgid, trackedMembers: trackedMembers)
                    }
                    return true
                }
                if Date() >= deadline {
                    return false
                }
                usleep(10_000)
            }
        }

        var steps: [PTYTerminationEscalationStep] = []

        // 1. SIGINT to all verified collected process groups (leader's group first), wait `sigintGraceSeconds` for ALL groups to empty
        let step1 = PTYTerminationEscalationStep.sentSIGINT(pid: pid)
        steps.append(step1)
        onStep?(step1)
        sendSignalToVerifiedGroups(SIGINT)
        if waitUntilSessionAndAllCollectedGroupsEmpty(timeout: sigintGraceSeconds) {
            return PTYTerminationEscalationReport(
                steps: steps,
                initialDescendantPIDs: initialDescendantPIDs,
                initialProcessGroupIDs: initialProcessGroupIDs,
                survivingPIDs: [],
                enumerationSucceeded: enumerationSucceeded
            )
        }

        // 2. SIGTERM to all verified still-active collected process groups, wait `sigtermGraceSeconds` for ALL groups to empty
        let step2 = PTYTerminationEscalationStep.sentSIGTERM(pid: pid)
        steps.append(step2)
        onStep?(step2)
        sendSignalToVerifiedGroups(SIGTERM)
        if waitUntilSessionAndAllCollectedGroupsEmpty(timeout: sigtermGraceSeconds) {
            return PTYTerminationEscalationReport(
                steps: steps,
                initialDescendantPIDs: initialDescendantPIDs,
                initialProcessGroupIDs: initialProcessGroupIDs,
                survivingPIDs: [],
                enumerationSucceeded: enumerationSucceeded
            )
        }

        // 3. SIGKILL to all verified still-active collected process groups and verified surviving members
        refreshTrackedTree()
        let step3 = PTYTerminationEscalationStep.sentSIGKILL(
            pid: pid,
            descendantPIDs: allDiscoveredDescendants,
            processGroupIDs: collectedGroups
        )
        steps.append(step3)
        onStep?(step3)

        sendSignalToVerifiedGroups(SIGKILL)
        for (memberPID, recorded) in trackedMembers where memberPID > 1 && memberPID != selfPID {
            if let live = POSIXProcessTree.processIdentity(for: memberPID),
               !live.isZombie,
               recorded.matchesProcess(live),
               live.pgid != callerPGID {
                _ = Darwin.kill(memberPID, SIGKILL)
            }
        }

        _ = waitUntilSessionAndAllCollectedGroupsEmpty(timeout: 5.0)

        var survivors: [pid_t] = []
        for (memberPID, recorded) in trackedMembers where memberPID > 1 && memberPID != selfPID {
            if let live = POSIXProcessTree.processIdentity(for: memberPID),
               !live.isZombie,
               recorded.matchesProcess(live) {
                survivors.append(memberPID)
            }
        }
        survivors.sort()

        return PTYTerminationEscalationReport(
            steps: steps,
            initialDescendantPIDs: initialDescendantPIDs,
            initialProcessGroupIDs: initialProcessGroupIDs,
            survivingPIDs: survivors,
            enumerationSucceeded: enumerationSucceeded
        )
    }

    private static func waitBrieflyForProcessGroupDrain(
        pgid: pid_t,
        trackedMembers: [pid_t: POSIXProcessIdentity]
    ) {
        guard pgid > 1, pgid != Darwin.getpgrp() else { return }
        var checks = 0
        while Darwin.kill(-pgid, 0) == 0 && checks < 50 {
            // Stop waiting immediately if `pgid` was recycled by an unrelated process
            if let recordedLeader = trackedMembers[pgid],
               let liveLeader = POSIXProcessTree.processIdentity(for: pgid),
               !recordedLeader.matchesProcess(liveLeader) {
                break
            }
            checks += 1
            usleep(5_000)
        }
    }

    /// Signals the child's entire process group (`-pid`) and blocks until the process group has genuinely exited
    /// before `isRunning` becomes `false`.
    public func terminate(signal sig: Int32 = SIGTERM) {
        state.condition.lock()
        let pid = state.childPID
        let running = state.isRunningFlag
        state.condition.unlock()

        guard running, pid > 0 else { return }

        if Darwin.kill(-pid, sig) != 0 && errno == ESRCH {
            _ = Darwin.kill(pid, sig)
        }

        if !state.waitForExit(timeout: 10.0) {
            _ = Darwin.kill(-pid, SIGKILL)
            _ = Darwin.kill(pid, SIGKILL)
            _ = state.waitForExit(timeout: nil)
        }

        // Ensure remaining processes in the same process group (-pid) have also exited.
        var checks = 0
        while Darwin.kill(-pid, 0) == 0 {
            if checks == 400 { // ~2.0s grace for siblings in -pid
                _ = Darwin.kill(-pid, SIGKILL)
            }
            checks += 1
            usleep(5_000)
        }
    }

    public func metrics() -> PTYProcessMetrics {
        state.condition.lock()
        defer { state.condition.unlock() }
        let termDesc: String?
        if let reason = state.exitReasonValue {
            switch reason {
            case .exited:
                termDesc = nil
            case .signaled, .waitFailed:
                termDesc = reason.localizedDescription(in: .zhHans)
            }
        } else {
            termDesc = nil
        }
        return PTYProcessMetrics(
            laneID: laneID,
            pid: state.childPID,
            masterFD: state.masterFD,
            isRunning: state.isRunningFlag,
            exitStatus: state.exitStatusValue,
            terminationSignal: state.terminationSignalValue,
            exitReason: state.exitReasonValue,
            terminationDescription: termDesc,
            bytesReadFromPTY: state.bytesReadCount,
            bytesWrittenToPTY: state.bytesWrittenCount,
            rawTranscriptBytesWritten: state.rawTranscriptBytesWrittenCount,
            rawTranscriptTruncated: state.rawTranscriptTruncatedFlag,
            startedAt: state.startedAtDate
        )
    }
}

// MARK: - Multi-Lane PTY Grid Multiplexer Manager

public final class PTYMultiplexerGrid: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: POSIXPseudoTerminalSession] = [:]

    public init() {}

    @discardableResult
    public func getOrCreateSession(laneID: String, rows: Int = 28, columns: Int = 100) -> POSIXPseudoTerminalSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[laneID] {
            return existing
        }
        let created = POSIXPseudoTerminalSession(laneID: laneID, rows: rows, columns: columns)
        sessions[laneID] = created
        return created
    }

    public func session(forLane laneID: String) -> POSIXPseudoTerminalSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[laneID]
    }

    public func allSnapshots() -> [TerminalViewportSnapshot] {
        lock.lock()
        let list = sessions.keys.sorted().compactMap { sessions[$0] }
        lock.unlock()
        return list.map { $0.screenBuffer.snapshot() }
    }

    public func terminateAll() {
        lock.lock()
        let list = Array(sessions.values)
        lock.unlock()
        for s in list {
            s.terminate()
        }
    }
}
