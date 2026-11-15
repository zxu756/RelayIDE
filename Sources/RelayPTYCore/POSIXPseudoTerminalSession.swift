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

public enum POSIXProcessTree: Sendable {
    /// Lists immediate child PIDs of `ppid` via Darwin's `proc_listchildpids` (which returns element count, not bytes).
    public static func directChildren(of ppid: pid_t) -> [pid_t] {
        guard ppid > 1 else { return [] }
        let hint = darwinProcListChildPIDs(ppid, nil, 0)
        var capacity = max(256, Int(max(0, hint)) + 64)
        while capacity <= 65_536 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let byteSize = Int32(clamping: capacity * MemoryLayout<pid_t>.stride)
            let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
                darwinProcListChildPIDs(ppid, raw.baseAddress, byteSize)
            }
            if count <= 0 {
                return []
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
            return result
        }
        return []
    }

    /// Recursively enumerates all descendants of `rootPID` (across `setsid` and `setpgid` boundaries) via BFS.
    public static func allDescendants(of rootPID: pid_t) -> [pid_t] {
        guard rootPID > 1 else { return [] }
        var visited: Set<pid_t> = [rootPID]
        var queue: [pid_t] = [rootPID]
        var descendants: [pid_t] = []
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for child in directChildren(of: current) {
                if visited.insert(child).inserted {
                    descendants.append(child)
                    queue.append(child)
                }
            }
        }
        return descendants
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
}

// MARK: - Internal Reaper-Safe Session State

private final class PTYSessionState: @unchecked Sendable {
    let laneID: String
    let screenBuffer: VT100TerminalScreenBuffer
    let ioQueue: DispatchQueue
    let condition = NSCondition()

    var masterFD: Int32 = -1
    var rawOutputFD: Int32 = -1
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

    init(laneID: String, rows: Int, columns: Int) {
        self.laneID = laneID
        self.screenBuffer = VT100TerminalScreenBuffer(laneID: laneID, rows: rows, columns: columns)
        self.ioQueue = DispatchQueue(label: "io.github.zxu756.RelayIDE.pty.\(laneID)", qos: .userInteractive)
    }

    private static func writeAllVerbatim(fd: Int32, data: Data) {
        guard fd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
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
        }
    }

    func drainAvailableMasterOutput() {
        condition.lock()
        let fd = masterFD
        let rfd = rawOutputFD
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
            Self.writeAllVerbatim(fd: rfd, data: aggregated)
            condition.lock()
            bytesReadCount += UInt64(aggregated.count)
            let cb = onOutputUpdate
            condition.unlock()
            screenBuffer.feed(aggregated)
            if let cb {
                cb(screenBuffer.snapshot())
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

    public init(laneID: String, rows: Int = 28, columns: Int = 100) {
        self.laneID = laneID
        self.state = PTYSessionState(laneID: laneID, rows: rows, columns: columns)
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
        rawOutputFilePath: String? = nil
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
        mergedEnv["TERM"] = "xterm-256color"
        mergedEnv["COLORTERM"] = "truecolor"
        mergedEnv["LANG"] = mergedEnv["LANG"] ?? "en_US.UTF-8"
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

        capturedState.condition.lock()
        capturedState.masterFD = mfd
        capturedState.rawOutputFD = openedRawFD
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

    /// Escalates `SIGINT -> wait(sigintGraceSeconds) -> SIGTERM -> wait(sigtermGraceSeconds) -> descendant-PGID SIGKILL` (R42).
    @discardableResult
    public func terminateWithEscalation(
        sigintGraceSeconds: TimeInterval = 10.0,
        sigtermGraceSeconds: TimeInterval = 5.0,
        onStep: (@Sendable (PTYTerminationEscalationStep) -> Void)? = nil
    ) -> [PTYTerminationEscalationStep] {
        state.condition.lock()
        let pid = state.childPID
        let running = state.isRunningFlag
        state.condition.unlock()

        guard running, pid > 0 else { return [] }
        var steps: [PTYTerminationEscalationStep] = []
        let callerPGID = Darwin.getpgrp()

        // 1. SIGINT to relay.sh's process group (-pid), wait sigintGraceSeconds
        let step1 = PTYTerminationEscalationStep.sentSIGINT(pid: pid)
        steps.append(step1)
        onStep?(step1)
        if Darwin.kill(-pid, SIGINT) != 0 && errno == ESRCH {
            _ = Darwin.kill(pid, SIGINT)
        }
        if state.waitForExit(timeout: max(0.0, sigintGraceSeconds)) {
            Self.waitBrieflyForProcessGroupDrain(pgid: pid)
            return steps
        }

        // 2. SIGTERM to relay.sh's process group (-pid), wait sigtermGraceSeconds
        let step2 = PTYTerminationEscalationStep.sentSIGTERM(pid: pid)
        steps.append(step2)
        onStep?(step2)
        if Darwin.kill(-pid, SIGTERM) != 0 && errno == ESRCH {
            _ = Darwin.kill(pid, SIGTERM)
        }
        if state.waitForExit(timeout: max(0.0, sigtermGraceSeconds)) {
            Self.waitBrieflyForProcessGroupDrain(pgid: pid)
            return steps
        }

        // 3. Snapshot all descendants and their process groups BEFORE sending SIGKILL, because
        //    killing `pid` first reparents its children to PID 1 and the agent runs in its own pgid.
        let descendants = POSIXProcessTree.allDescendants(of: pid)
        let pgids = POSIXProcessTree.processGroupIDs(
            for: [pid] + descendants,
            excludingProcessGroup: callerPGID
        )
        let step3 = PTYTerminationEscalationStep.sentSIGKILL(
            pid: pid,
            descendantPIDs: descendants,
            processGroupIDs: pgids
        )
        steps.append(step3)
        onStep?(step3)

        if pid != callerPGID {
            _ = Darwin.kill(-pid, SIGKILL)
        }
        _ = Darwin.kill(pid, SIGKILL)
        for pgid in pgids {
            _ = Darwin.kill(-pgid, SIGKILL)
        }
        for descPID in descendants where descPID > 1 && descPID != Darwin.getpid() {
            _ = Darwin.kill(descPID, SIGKILL)
        }

        _ = state.waitForExit(timeout: 5.0)
        Self.waitBrieflyForProcessGroupDrain(pgid: pid)
        for pgid in pgids {
            Self.waitBrieflyForProcessGroupDrain(pgid: pgid)
        }
        return steps
    }

    private static func waitBrieflyForProcessGroupDrain(pgid: pid_t) {
        guard pgid > 1, pgid != Darwin.getpgrp() else { return }
        var checks = 0
        while Darwin.kill(-pgid, 0) == 0 && checks < 100 {
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
