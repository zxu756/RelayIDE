import Darwin
import Foundation
import RelayModels
import RelayPTYCore
import RelayWorktreeGit

// MARK: - M2 `verify` PTY Runner (`03-relayide.md` M2 §6, §7, §10; R51–R54)

public struct RelayVerifyExecutionOutcome: Sendable, Equatable {
    public let verifyRecord: RelayRunVerifyRecord
    public let integrationStatus: RelayIntegrationStatus
    public let integrationReason: String?
    public let ready: Bool
    public let survivingPIDs: [pid_t]
    public let enumerationSucceeded: Bool

    public init(
        verifyRecord: RelayRunVerifyRecord,
        integrationStatus: RelayIntegrationStatus,
        integrationReason: String?,
        ready: Bool,
        survivingPIDs: [pid_t] = [],
        enumerationSucceeded: Bool = true
    ) {
        self.verifyRecord = verifyRecord
        self.integrationStatus = integrationStatus
        self.integrationReason = integrationReason
        self.ready = ready
        self.survivingPIDs = survivingPIDs
        self.enumerationSucceeded = enumerationSucceeded
    }
}

private enum VerifyEscalationTrigger: Sendable {
    case cancelled
    case timedOut
}

private final class VerifyEscalationCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var trigger: VerifyEscalationTrigger?
    private var completed = false
    private var report: PTYTerminationEscalationReport?
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func tryClaim(_ candidate: VerifyEscalationTrigger) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard trigger == nil else { return false }
        trigger = candidate
        return true
    }

    var claimedTrigger: VerifyEscalationTrigger? {
        lock.lock()
        defer { lock.unlock() }
        return trigger
    }

    var completedReport: PTYTerminationEscalationReport? {
        lock.lock()
        defer { lock.unlock() }
        return report
    }

    func finish(with report: PTYTerminationEscalationReport) {
        lock.lock()
        self.report = report
        self.completed = true
        let waiters = continuations
        continuations.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForCompletionIfTriggered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if trigger == nil || completed {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}

public enum RelayVerifyRunner {
    /// 16 MiB (`16_777_216` bytes) raw PTY transcript cap for `<project>/runs/<runID>/verify.pty` (`03-relayide.md` M2 §6).
    public static let defaultMaxLogBytes: UInt64 = 16 * 1024 * 1024

    public static func defaultVerifyLogPath(projectBundlePath: String, runID: String) -> String {
        URL(fileURLWithPath: projectBundlePath, isDirectory: true)
            .standardizedFileURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("verify.pty")
            .path
    }

    /// Executes `command` inside `integrationWorktreePath` via `POSIXPseudoTerminalSession`
    /// (`/bin/sh -c 'exec </dev/null; exec /bin/sh -c "$1"' relayide-verify '<command>'`),
    /// returning `RelayRunVerifyRecord` (`03-relayide.md` M2 §6, §7, §10).
    @discardableResult
    public static func runVerify(
        runID: String,
        projectBundlePath: String,
        integrationWorktreePath: String,
        command: String,
        timeoutSec: Int = RelayRunPlan.defaultVerifyTimeoutSeconds,
        maxLogBytes: UInt64 = RelayVerifyRunner.defaultMaxLogBytes,
        sigintGraceSeconds: TimeInterval = RelayCancellationPolicy.defaultSigintGraceSeconds,
        sigtermGraceSeconds: TimeInterval = RelayCancellationPolicy.defaultSigtermGraceSeconds,
        gitEngine: GitWorktreePlumbingEngine = GitWorktreePlumbingEngine(),
        language: RelayLanguage = .en,
        environment: [String: String]? = nil,
        updatesScreenBuffer: Bool = false,
        sessionFactory: (@Sendable () -> POSIXPseudoTerminalSession)? = nil,
        descendantEnumerator: (@Sendable (pid_t) -> (pids: [pid_t], succeeded: Bool))? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onStarted: (@Sendable (_ pid: Int32, _ startedAt: Date, _ runningRecord: RelayRunVerifyRecord) throws -> Void)? = nil,
        onOutcomeReason: (@Sendable (String?) -> Void)? = nil,
        onStderrLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> RelayRunVerifyRecord {
        let outcome = try await runVerifyWithOutcome(
            runID: runID,
            projectBundlePath: projectBundlePath,
            integrationWorktreePath: integrationWorktreePath,
            command: command,
            timeoutSec: timeoutSec,
            maxLogBytes: maxLogBytes,
            sigintGraceSeconds: sigintGraceSeconds,
            sigtermGraceSeconds: sigtermGraceSeconds,
            gitEngine: gitEngine,
            language: language,
            environment: environment,
            updatesScreenBuffer: updatesScreenBuffer,
            sessionFactory: sessionFactory,
            descendantEnumerator: descendantEnumerator,
            isCancelled: isCancelled,
            onStarted: onStarted,
            onStderrLine: onStderrLine
        )
        onOutcomeReason?(outcome.integrationReason)
        return outcome.verifyRecord
    }

    /// Full `verify` execution returning both `RelayRunVerifyRecord` and its mapped `integration` status, reason, and `ready` flag.
    public static func runVerifyWithOutcome(
        runID: String,
        projectBundlePath: String,
        integrationWorktreePath: String,
        command: String,
        timeoutSec: Int = RelayRunPlan.defaultVerifyTimeoutSeconds,
        maxLogBytes: UInt64 = RelayVerifyRunner.defaultMaxLogBytes,
        sigintGraceSeconds: TimeInterval = RelayCancellationPolicy.defaultSigintGraceSeconds,
        sigtermGraceSeconds: TimeInterval = RelayCancellationPolicy.defaultSigtermGraceSeconds,
        gitEngine: GitWorktreePlumbingEngine = GitWorktreePlumbingEngine(),
        language: RelayLanguage = .en,
        environment: [String: String]? = nil,
        updatesScreenBuffer: Bool = false,
        sessionFactory: (@Sendable () -> POSIXPseudoTerminalSession)? = nil,
        descendantEnumerator: (@Sendable (pid_t) -> (pids: [pid_t], succeeded: Bool))? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onStarted: (@Sendable (_ pid: Int32, _ startedAt: Date, _ runningRecord: RelayRunVerifyRecord) throws -> Void)? = nil,
        onStderrLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> RelayVerifyExecutionOutcome {
        guard RelayPlanLaneSpec.isValidRunID(runID) else {
            throw RelayIDEError.relayEnvironmentFailure("Invalid run id '\(runID)' for verify execution")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: integrationWorktreePath, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw RelayIDEError.relayEnvironmentFailure(
                "Verify working directory does not exist or is not a directory: '\(integrationWorktreePath)'"
            )
        }

        if isCancelled() {
            let now = Date()
            let cancelledRecord = RelayRunVerifyRecord(
                command: command,
                timeoutSec: timeoutSec,
                status: .cancelled,
                exitCode: nil,
                signal: nil,
                pid: nil,
                startedAt: now,
                finishedAt: now,
                logPath: nil,
                logBytes: 0,
                logTruncated: false,
                modifiedTrackedFiles: []
            )
            return RelayVerifyExecutionOutcome(
                verifyRecord: cancelledRecord,
                integrationStatus: .cancelled,
                integrationReason: "cancelled",
                ready: false
            )
        }

        let logPath = defaultVerifyLogPath(projectBundlePath: projectBundlePath, runID: runID)
        let baseEnv = environment ?? ProcessInfo.processInfo.environment
        let session = sessionFactory?()
            ?? POSIXPseudoTerminalSession(laneID: "verify-\(runID)", updatesScreenBuffer: updatesScreenBuffer)

        // §6: Spawn `/bin/sh -c 'exec </dev/null; exec /bin/sh -c "$1"' relayide-verify '<command>'`
        // inside `integrationWorktreePath`, preserving caller environment verbatim (`PATH` untouched, non-login shell)
        // plus `PAGER=cat` and `GIT_PAGER=cat`.
        try session.spawn(
            executablePath: "/bin/sh",
            arguments: ["-c", "exec </dev/null; exec /bin/sh -c \"$1\"", "relayide-verify", command],
            workingDirectory: integrationWorktreePath,
            baseEnvironment: baseEnv,
            environmentOverrides: [
                "PAGER": "cat",
                "GIT_PAGER": "cat"
            ],
            rawOutputFilePath: logPath,
            rawOutputMaxBytes: maxLogBytes,
            preserveEnvironmentVerbatim: true
        )

        let childPID = session.childProcessID
        let startedAt = Date()
        let runningRecord = RelayRunVerifyRecord(
            command: command,
            timeoutSec: timeoutSec,
            status: .running,
            exitCode: nil,
            signal: nil,
            pid: childPID > 0 ? childPID : nil,
            startedAt: startedAt,
            finishedAt: nil,
            logPath: logPath,
            logBytes: 0,
            logTruncated: false,
            modifiedTrackedFiles: []
        )

        if let onStarted {
            do {
                try onStarted(childPID, startedAt, runningRecord)
            } catch {
                _ = session.terminateWithEscalationReport(
                    sigintGraceSeconds: sigintGraceSeconds,
                    sigtermGraceSeconds: sigtermGraceSeconds,
                    descendantEnumerator: descendantEnumerator
                )
                throw error
            }
        }

        onStderrLine(
            RelayIntegrationStderrFormatter.formatVerifyStartedLine(
                pid: childPID,
                timeoutSec: timeoutSec,
                language: language
            )
        )

        let effectiveTimeoutSec = max(1, timeoutSec)
        let deadline = startedAt.addingTimeInterval(TimeInterval(effectiveTimeoutSec))
        let coordinator = VerifyEscalationCoordinator()
        let watcherQueue = DispatchQueue(label: "io.github.zxu756.RelayIDE.verify.watcher.\(runID)")
        let watcherTimer = DispatchSource.makeTimerSource(queue: watcherQueue)

        func triggerEscalation(_ kind: VerifyEscalationTrigger) {
            guard coordinator.tryClaim(kind) else { return }
            watcherTimer.setEventHandler {}
            watcherTimer.cancel()
            DispatchQueue.global(qos: .userInitiated).async {
                let report = session.terminateWithEscalationReport(
                    sigintGraceSeconds: sigintGraceSeconds,
                    sigtermGraceSeconds: sigtermGraceSeconds,
                    descendantEnumerator: descendantEnumerator
                )
                coordinator.finish(with: report)
            }
        }

        watcherTimer.schedule(deadline: .now(), repeating: .milliseconds(20))
        watcherTimer.setEventHandler {
            guard coordinator.claimedTrigger == nil else { return }
            guard session.metrics().isRunning else { return }
            if isCancelled() {
                triggerEscalation(.cancelled)
            } else if Date() >= deadline {
                triggerEscalation(.timedOut)
            }
        }
        watcherTimer.resume()

        let exitReason = await session.awaitExit()
        if coordinator.claimedTrigger == nil {
            watcherTimer.setEventHandler {}
            watcherTimer.cancel()
        }
        await coordinator.waitForCompletionIfTriggered()
        let finishedAt = Date()

        let finalMetrics = session.metrics()
        let logBytes = Int(finalMetrics.rawTranscriptBytesWritten)
        let logTruncated = finalMetrics.rawTranscriptTruncated
        let escalationReport = coordinator.completedReport
        let survivingPIDs = escalationReport?.survivingPIDs ?? []
        let enumerationSucceeded = escalationReport?.enumerationSucceeded ?? true

        let verifyStatus: RelayVerifyStatus
        let exitCode: Int32?
        let signal: Int32?
        var modifiedTrackedFiles: [String] = []
        let integrationStatus: RelayIntegrationStatus
        let integrationReason: String?
        let ready: Bool

        if coordinator.claimedTrigger == .cancelled || isCancelled() {
            verifyStatus = .cancelled
            exitCode = exitReason.exitCode
            signal = exitReason.terminationSignal
            integrationStatus = .cancelled
            integrationReason = Self.formatEscalationReason(
                base: "cancelled",
                report: escalationReport,
                rootPID: childPID
            )
            ready = false
        } else if coordinator.claimedTrigger == .timedOut {
            verifyStatus = .timeout
            exitCode = nil
            signal = exitReason.terminationSignal
            integrationStatus = .verifyTimeout
            integrationReason = Self.formatEscalationReason(
                base: "verify timed out after \(effectiveTimeoutSec)s",
                report: escalationReport,
                rootPID: childPID
            )
            ready = false
        } else {
            switch exitReason {
            case .exited(code: 0):
                let porcelainOut = try gitEngine.runGit(
                    ["status", "--porcelain=v1", "--untracked-files=no"],
                    cwd: integrationWorktreePath,
                    environment: baseEnv
                )
                if porcelainOut.isEmpty {
                    verifyStatus = .passed
                    exitCode = 0
                    signal = nil
                    integrationStatus = .verified
                    integrationReason = nil
                    ready = true
                } else {
                    let dirty = Self.parseModifiedTrackedFiles(porcelainV1Output: porcelainOut)
                    modifiedTrackedFiles = dirty
                    verifyStatus = .failed
                    exitCode = 0
                    signal = nil
                    integrationStatus = .verifyFailed
                    let dirtyJoined = dirty.joined(separator: ", ")
                    integrationReason = "verify modified tracked files: \(dirtyJoined)"
                    ready = false
                }

            case .exited(code: let code):
                verifyStatus = .failed
                exitCode = code
                signal = nil
                integrationStatus = .verifyFailed
                integrationReason = "verify failed (exit \(code))"
                ready = false

            case .signaled(signal: let sig):
                verifyStatus = .failed
                exitCode = nil
                signal = sig
                integrationStatus = .verifyFailed
                integrationReason = "verify failed (signal \(sig))"
                ready = false

            case .waitFailed(errnoCode: let err):
                verifyStatus = .failed
                exitCode = nil
                signal = nil
                integrationStatus = .verifyFailed
                integrationReason = "verify failed (waitpid errno \(err))"
                ready = false
            }
        }

        let completedRecord = RelayRunVerifyRecord(
            command: command,
            timeoutSec: timeoutSec,
            status: verifyStatus,
            exitCode: exitCode,
            signal: signal,
            pid: childPID > 0 ? childPID : nil,
            startedAt: startedAt,
            finishedAt: finishedAt,
            logPath: logPath,
            logBytes: logBytes,
            logTruncated: logTruncated,
            modifiedTrackedFiles: modifiedTrackedFiles
        )

        onStderrLine(
            RelayIntegrationStderrFormatter.formatVerifyFinishedLine(
                verify: completedRecord,
                language: language
            )
        )

        return RelayVerifyExecutionOutcome(
            verifyRecord: completedRecord,
            integrationStatus: integrationStatus,
            integrationReason: integrationReason,
            ready: ready,
            survivingPIDs: survivingPIDs,
            enumerationSucceeded: enumerationSucceeded
        )
    }

    /// Parses modified tracked file paths from `git status --porcelain=v1 --untracked-files=no` output
    /// without stripping leading status-column spaces (`XY PATH`).
    public static func parseModifiedTrackedFiles(porcelainV1Output: String) -> [String] {
        let normalized = porcelainV1Output.replacingOccurrences(of: "\r\n", with: "\n")
        var files = Set<String>()
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            guard rawLine.count >= 4 else { continue }
            let xy = Array(rawLine.prefix(2))
            var rest = String(rawLine.dropFirst(3))
            if (xy[0] == "R" || xy[0] == "C"), let arrow = rest.range(of: " -> ") {
                rest = String(rest[arrow.upperBound...])
            }
            let unquoted = unquoteGitPathIfNeeded(rest)
            if !unquoted.isEmpty {
                files.insert(unquoted)
            }
        }
        return files.sorted()
    }

    private static func unquoteGitPathIfNeeded(_ path: String) -> String {
        guard path.count >= 2, path.first == "\"", path.last == "\"" else {
            return path
        }
        let inner = Array(path.dropFirst().dropLast().utf8)
        var out: [UInt8] = []
        var idx = 0
        while idx < inner.count {
            let b = inner[idx]
            if b == 0x5C, idx + 1 < inner.count { // backslash
                idx += 1
                let next = inner[idx]
                switch next {
                case UInt8(ascii: "n"): out.append(0x0A); idx += 1
                case UInt8(ascii: "r"): out.append(0x0D); idx += 1
                case UInt8(ascii: "t"): out.append(0x09); idx += 1
                case UInt8(ascii: "\\"): out.append(0x5C); idx += 1
                case UInt8(ascii: "\""): out.append(0x22); idx += 1
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var octalVal: UInt8 = 0
                    var digits = 0
                    while idx < inner.count && digits < 3 && inner[idx] >= UInt8(ascii: "0") && inner[idx] <= UInt8(ascii: "7") {
                        octalVal = (octalVal &* 8) &+ (inner[idx] - UInt8(ascii: "0"))
                        idx += 1
                        digits += 1
                    }
                    out.append(octalVal)
                default:
                    out.append(next)
                    idx += 1
                }
            } else {
                out.append(b)
                idx += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func formatEscalationReason(
        base: String,
        report: PTYTerminationEscalationReport?,
        rootPID: pid_t
    ) -> String {
        guard let report else { return base }
        if !report.survivingPIDs.isEmpty {
            let pidList = report.survivingPIDs.map(String.init).joined(separator: ", ")
            return "\(base); potentially surviving PIDs: [\(pidList)]"
        }
        if !report.enumerationSucceeded {
            let candidates = Array(Set(([rootPID] + report.initialDescendantPIDs).filter { $0 > 0 })).sorted()
            let pidList = candidates.map(String.init).joined(separator: ", ")
            return "\(base); descendant enumeration incomplete, processes under PID(s) [\(pidList)] may still be running"
        }
        return base
    }
}
