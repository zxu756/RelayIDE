import CoreServices
import Foundation
import RelayModels

// MARK: - Glob Matcher & FSEvents Real-Time File-Scope Ownership Guardrail

public enum GlobPatternMatcher {
    public static func matches(path: String, glob: String) -> Bool {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedGlob = glob.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedGlob == "**" || normalizedGlob == "**/*" {
            return true
        }
        let regexPattern = globToRegex(normalizedGlob)
        guard let regex = try? NSRegularExpression(pattern: regexPattern) else {
            return normalizedPath == normalizedGlob
        }
        let ns = normalizedPath as NSString
        return regex.firstMatch(in: normalizedPath, range: NSRange(location: 0, length: ns.length)) != nil
    }

    public static func evaluateOwnership(relativePath: String, rule: FileOwnershipRule) -> (allowed: Bool, reason: String) {
        if rule.isReadOnlyVerifier {
            return (false, "Verifier lane is strictly read-only")
        }
        for forbidden in rule.forbiddenGlobs {
            if matches(path: relativePath, glob: forbidden) {
                return (false, "Matched forbidden glob '\(forbidden)'")
            }
        }
        if rule.allowedGlobs.isEmpty {
            return (false, "Empty allowedGlobs list")
        }
        for allowed in rule.allowedGlobs {
            if matches(path: relativePath, glob: allowed) {
                return (true, "Matched allowed glob '\(allowed)'")
            }
        }
        return (false, "Outside allowed globs [\(rule.allowedGlobs.joined(separator: ", "))]")
    }

    private static func globToRegex(_ glob: String) -> String {
        var out = "^"
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "*" {
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    if i + 2 < chars.count && chars[i + 2] == "/" {
                        out += "(?:.*/)?"
                        i += 3
                        continue
                    } else {
                        out += ".*"
                        i += 2
                        continue
                    }
                } else {
                    out += "[^/]*"
                }
            } else if ch == "?" {
                out += "[^/]"
            } else if ".+^$()[]{}|\\".contains(ch) {
                out += "\\\(ch)"
            } else {
                out.append(ch)
            }
            i += 1
        }
        out += "$"
        return out
    }
}

public final class FSEventsOwnershipMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let gitEngine: GitWorktreePlumbingEngine
    private var streamRef: FSEventStreamRef?
    private let callbackQueue = DispatchQueue(label: "io.github.zxu756.RelayIDE.fsevents", qos: .utility)
    private var lanesByWorktreePath: [String: ManagedWorktreeLane] = [:]
    private var violations: [OwnershipViolationEvent] = []

    public var onViolationDetected: (@Sendable (OwnershipViolationEvent) -> Void)?

    public init(gitEngine: GitWorktreePlumbingEngine = GitWorktreePlumbingEngine()) {
        self.gitEngine = gitEngine
    }

    deinit {
        stopMonitoring()
    }

    public func registerLane(_ lane: ManagedWorktreeLane) {
        let standardized = URL(fileURLWithPath: lane.worktreePath).standardizedFileURL.path
        lock.lock()
        lanesByWorktreePath[standardized] = lane
        lock.unlock()
    }

    public func auditChangedPath(worktreePath: String, relativePath: String) -> OwnershipViolationEvent? {
        let stdRoot = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
        lock.lock()
        let laneOpt = lanesByWorktreePath[stdRoot]
        lock.unlock()
        guard let lane = laneOpt else { return nil }

        let verdict = GlobPatternMatcher.evaluateOwnership(relativePath: relativePath, rule: lane.ownershipRule)
        guard !verdict.allowed else { return nil }

        var reverted = false
        if lane.ownershipRule.autoRevertViolations {
            if (try? gitEngine.revertPathToHEAD(in: stdRoot, relativePath: relativePath)) != nil {
                reverted = true
            }
        }

        let event = OwnershipViolationEvent(
            laneID: lane.id,
            vendor: lane.assignedVendor,
            relativePath: relativePath,
            violatedRuleSummary: verdict.reason,
            wasAutoReverted: reverted
        )
        lock.lock()
        violations.append(event)
        lock.unlock()
        onViolationDetected?(event)
        return event
    }

    public func startMonitoring() {
        lock.lock()
        if streamRef != nil {
            lock.unlock()
            return
        }
        let paths = Array(lanesByWorktreePath.keys)
        lock.unlock()
        guard !paths.isEmpty else { return }

        let unmanagedSelf = Unmanaged.passUnretained(self)
        var context = FSEventStreamContext(
            version: 0,
            info: unmanagedSelf.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, _, _ in
            guard let clientInfo else { return }
            let monitor = Unmanaged<FSEventsOwnershipMonitor>.fromOpaque(clientInfo).takeUnretainedValue()
            let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
            var changedPaths: [String] = []
            for idx in 0..<numEvents {
                if let ptr = CFArrayGetValueAtIndex(cfArray, idx) {
                    let cfStr = unsafeBitCast(ptr, to: CFString.self)
                    changedPaths.append(cfStr as String)
                }
            }
            monitor.handleFSEventsBatch(changedPaths)
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        FSEventStreamStart(stream)

        lock.lock()
        streamRef = stream
        lock.unlock()
    }

    public func stopMonitoring() {
        lock.lock()
        guard let stream = streamRef else {
            lock.unlock()
            return
        }
        streamRef = nil
        lock.unlock()

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    public func recordedViolations() -> [OwnershipViolationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return violations
    }

    private func handleFSEventsBatch(_ absolutePaths: [String]) {
        lock.lock()
        let roots = Array(lanesByWorktreePath.keys)
        lock.unlock()

        for rawAbs in absolutePaths {
            let stdAbs = URL(fileURLWithPath: rawAbs).standardizedFileURL.path
            for root in roots where stdAbs.hasPrefix(root + "/") {
                let rel = String(stdAbs.dropFirst(root.count + 1))
                if rel.hasPrefix(".git/") || rel == ".git" { continue }
                _ = auditChangedPath(worktreePath: root, relativePath: rel)
            }
        }
    }
}
