import Darwin
import Foundation
import RelayModels

// MARK: - POSIX Pseudo-Terminal (`posix_openpt` / `grantpt` / `unlockpt` / `ptsname` + `posix_spawn`) Multiplexer

public final class POSIXPseudoTerminalSession: @unchecked Sendable {
    public let laneID: String
    public let screenBuffer: VT100TerminalScreenBuffer

    private let lock = NSLock()
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var isRunningFlag: Bool = false
    private var exitStatusValue: Int32?
    private var bytesReadCount: UInt64 = 0
    private var bytesWrittenCount: UInt64 = 0
    private var startedAtDate: Date = Date()
    private var readSource: DispatchSourceRead?
    private let ioQueue: DispatchQueue

    public var onOutputUpdate: (@Sendable (TerminalViewportSnapshot) -> Void)?

    public init(laneID: String, rows: Int = 28, columns: Int = 100) {
        self.laneID = laneID
        self.screenBuffer = VT100TerminalScreenBuffer(laneID: laneID, rows: rows, columns: columns)
        self.ioQueue = DispatchQueue(label: "io.github.zxu756.RelayIDE.pty.\(laneID)", qos: .userInteractive)
    }

    deinit {
        terminate()
    }

    /// Spawns an interactive or headless child process attached to a real POSIX pseudo-terminal (`TIOCSCTTY` + `winsize`).
    public func spawn(
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environmentOverrides: [String: String] = [:]
    ) throws {
        lock.lock()
        if isRunningFlag {
            lock.unlock()
            return
        }
        lock.unlock()

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw RelayIDEError.processSpawnFailed(executable: executablePath, reason: "Executable not found or lacks +x permission")
        }

        let mfd = Darwin.posix_openpt(O_RDWR | O_NOCTTY)
        guard mfd >= 0 else {
            throw RelayIDEError.ptyAllocationFailed(errnoCode: errno, message: String(cString: strerror(errno)))
        }
        guard Darwin.grantpt(mfd) == 0, Darwin.unlockpt(mfd) == 0, let slaveNamePtr = Darwin.ptsname(mfd) else {
            let code = errno
            Darwin.close(mfd)
            throw RelayIDEError.ptyAllocationFailed(errnoCode: code, message: String(cString: strerror(code)))
        }

        let slavePath = String(cString: slaveNamePtr)
        let sfd = Darwin.open(slavePath, O_RDWR)
        guard sfd >= 0 else {
            let code = errno
            Darwin.close(mfd)
            throw RelayIDEError.ptyAllocationFailed(errnoCode: code, message: String(cString: strerror(code)))
        }

        var ws = winsize(
            ws_row: UInt16(clamping: screenBuffer.rows),
            ws_col: UInt16(clamping: screenBuffer.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(mfd, TIOCSWINSZ, &ws)

        // Configure `posix_spawn_file_actions_t` & `posix_spawnattr_t`
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, sfd, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, sfd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, sfd, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, mfd)
        if sfd > STDERR_FILENO {
            posix_spawn_file_actions_addclose(&fileActions, sfd)
        }
        if let wd = workingDirectory {
            _ = wd.withCString { cwd in
                posix_spawn_file_actions_addchdir_np(&fileActions, cwd)
            }
        }

        var spawnAttrs: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttrs)
        defer { posix_spawnattr_destroy(&spawnAttrs) }
        _ = posix_spawnattr_setflags(&spawnAttrs, Int16(POSIX_SPAWN_SETSID))

        // Build argv & envp
        var mergedEnv = ProcessInfo.processInfo.environment
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
            throw RelayIDEError.processSpawnFailed(
                executable: executablePath,
                reason: String(cString: strerror(spawnRC))
            )
        }

        // Put master FD into non-blocking mode for DispatchSourceRead
        let flags = fcntl(mfd, F_GETFL)
        _ = fcntl(mfd, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: mfd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.drainAvailableMasterOutput()
        }
        source.setCancelHandler {
            Darwin.close(mfd)
        }

        lock.lock()
        self.masterFD = mfd
        self.childPID = pid
        self.isRunningFlag = true
        self.exitStatusValue = nil
        self.startedAtDate = Date()
        self.readSource = source
        lock.unlock()

        source.resume()

        // Background exit reaper
        let spawnedPID = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            _ = Darwin.waitpid(spawnedPID, &status, 0)
            // Compute WEXITSTATUS((status >> 8) & 0xFF)
            let code = (status >> 8) & 0xFF
            self?.handleChildExit(exitCode: code)
        }
    }

    public func writeInput(_ data: Data) {
        lock.lock()
        let fd = masterFD
        let running = isRunningFlag
        lock.unlock()
        guard running, fd >= 0, !data.isEmpty else { return }

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if n > 0 {
                    offset += n
                    lock.lock()
                    bytesWrittenCount += UInt64(n)
                    lock.unlock()
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
        lock.lock()
        let fd = masterFD
        lock.unlock()
        guard fd >= 0 else { return }
        var ws = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(fd, TIOCSWINSZ, &ws)
    }

    public func terminate(signal sig: Int32 = SIGTERM) {
        lock.lock()
        let pid = childPID
        let running = isRunningFlag
        let src = readSource
        readSource = nil
        masterFD = -1
        isRunningFlag = false
        lock.unlock()

        if running && pid > 0 {
            _ = Darwin.kill(pid, sig)
        }
        src?.cancel()
    }

    public func metrics() -> PTYProcessMetrics {
        lock.lock()
        defer { lock.unlock() }
        return PTYProcessMetrics(
            laneID: laneID,
            pid: childPID,
            masterFD: masterFD,
            isRunning: isRunningFlag,
            exitStatus: exitStatusValue,
            bytesReadFromPTY: bytesReadCount,
            bytesWrittenToPTY: bytesWrittenCount,
            startedAt: startedAtDate
        )
    }

    private func drainAvailableMasterOutput() {
        lock.lock()
        let fd = masterFD
        lock.unlock()
        guard fd >= 0 else { return }

        var chunk = [UInt8](repeating: 0, count: 16_384)
        var aggregated = Data()
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                aggregated.append(contentsOf: chunk[0..<n])
            } else {
                break
            }
        }

        if !aggregated.isEmpty {
            lock.lock()
            bytesReadCount += UInt64(aggregated.count)
            lock.unlock()
            screenBuffer.feed(aggregated)
            if let cb = onOutputUpdate {
                cb(screenBuffer.snapshot())
            }
        }
    }

    private func handleChildExit(exitCode: Int32) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.drainAvailableMasterOutput()
            self.lock.lock()
            self.isRunningFlag = false
            self.exitStatusValue = exitCode
            let src = self.readSource
            self.readSource = nil
            self.masterFD = -1
            self.lock.unlock()
            src?.cancel()
            if let cb = self.onOutputUpdate {
                cb(self.screenBuffer.snapshot())
            }
        }
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
