import Foundation
import RelayModels

// MARK: - Line-Anchored Guarded 3-Way Merge (the only merge entry point used by the CLI and the MCP server)
//
// Contract: a result is reported as clean only if no change of either side is lost and no line that neither
// side touched is altered (blank lines and string contents included). The check knows nothing about any
// programming language. It works on bytes and lines and is anchored on `git merge-file`:
//
//   1. Run the line-level 3-way merge (`git merge-file -p`).
//      Clean  -> that text is the result (after the language syntax check, where one exists).
//      Failed / git missing -> refuse to merge.
//   2. Only when git reports conflicts is the declaration-level engine consulted, and only as a referee.
//      The emitted text is never taken from the engine. It is assembled from git's own output:
//      every non-conflicting part byte for byte, and each conflict block replaced by the two sides'
//      lines, verbatim, one side after the other. That is only allowed when
//        - the file type has a real syntax checker, and the assembled text passes it,
//        - every conflict block is a pure "both sides inserted here" block (its base side is empty),
//        - the engine reports no conflict of its own, and its output, compared line by line with blank
//          lines ignored, is exactly the assembled text (so the engine neither dropped, added, changed
//          nor reordered a single non-blank line).
//   3. Anything else -> conflict: the caller gets git's conflict-marked text.

public enum GuardedMergeStrategy: String, Sendable, Equatable {
    /// The text is exactly what `git merge-file -p` produced.
    case lineLevel = "line-level"
    /// git reported conflicts; every one was a both-sides-insertion that the declaration engine agreed to keep.
    case declarationLevel = "declaration-level"
}

/// Why the declaration-level path did not produce a result for a file that git could not merge cleanly.
public enum GuardedMergeDeclarationVerdict: Sendable, Equatable {
    case noSyntaxCheckerForFileType(fileExtension: String)
    case inconsistentFinalNewline
    case structuralMergeUnreadable(detail: String)
    case conflictTouchesBaseLines(blockNumber: Int, blockCount: Int)
    case engineReportedConflicts(count: Int)
    case engineDisagreesWithLineMerge(detail: String)
    case assembledTextFailedSyntaxCheck(parser: String, diagnostic: String)

    public func localizedDescription(in language: RelayLanguage) -> String {
        let zh = language.isChinese
        switch self {
        case .noSyntaxCheckerForFileType(let ext):
            let shown = ext.isEmpty ? (zh ? "（无扩展名）" : "(no extension)") : ".\(ext)"
            return zh
                ? "\(shown) 文件没有可用的语法检查器，不尝试声明级合并"
                : "no syntax checker is available for \(shown) files, so declaration-level merging is not attempted"
        case .inconsistentFinalNewline:
            return zh
                ? "三个版本的文件末尾换行不一致，不尝试声明级合并"
                : "the three versions disagree about the final newline, so declaration-level merging is not attempted"
        case .structuralMergeUnreadable(let detail):
            return zh
                ? "无法解析 git merge-file --diff3 的输出（\(detail)），不采用声明级结果"
                : "could not parse the `git merge-file --diff3` output (\(detail)); declaration-level result not used"
        case .conflictTouchesBaseLines(let number, let count):
            return zh
                ? "第 \(number)/\(count) 个冲突块改动或删除了 base 里的行（不是两边各自在同一位置插入），不采用声明级结果"
                : "conflict block \(number) of \(count) modifies or deletes base lines (it is not a both-sides insertion); declaration-level result not used"
        case .engineReportedConflicts(let count):
            return zh
                ? "声明级引擎自己报告了 \(count) 处冲突"
                : "the declaration-level engine itself reported \(count) conflict(s)"
        case .engineDisagreesWithLineMerge(let detail):
            return zh
                ? "声明级引擎的结果与行级合并对不上（\(detail)），不采用"
                : "the declaration-level engine's result does not match the line-level merge (\(detail)); not used"
        case .assembledTextFailedSyntaxCheck(let parser, let diagnostic):
            return zh
                ? "保留两边插入内容后的文本未通过语法检查（\(parser)）：\(diagnostic)"
                : "the text with both sides' insertions kept failed the syntax check (\(parser)): \(diagnostic)"
        }
    }
}

public enum GuardedMergeOutcome: Sendable, Equatable {
    /// Exit 0. `syntaxParser` is nil when the file type has no syntax checker (the text is then git's own clean result).
    case clean(mergedText: String, strategy: GuardedMergeStrategy, syntaxParser: String?, resolvedConflictBlocks: Int)
    /// Exit 1. `lineMergeText` is the `git merge-file -p` output including conflict markers.
    case conflict(lineMergeText: String, conflictCount: Int, declarationVerdict: GuardedMergeDeclarationVerdict)
    /// Exit 3. git merged cleanly but the result does not parse; nothing is emitted.
    case syntaxCheckFailed(parser: String, diagnostic: String)
    /// Exit 4. git is missing or `git merge-file` failed; nothing is merged without the line-level reference.
    case lineMergeUnavailable(reason: String)
}

public struct LineAnchoredGuardedMerger: Sendable {
    public static let leftLabel = "left"
    public static let baseLabel = "base"
    public static let rightLabel = "right"

    /// Absolute path of the git executable, or nil when none was found. A nil path always yields `.lineMergeUnavailable`.
    public let gitExecutablePath: String?

    public init(gitExecutablePath: String?) {
        self.gitExecutablePath = gitExecutablePath
    }

    /// Resolves `git` from the PATH of `environment` only. There is deliberately no fallback location:
    /// when git cannot be found the merge is refused.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.gitExecutablePath = Self.locateGit(in: environment)
    }

    public static func locateGit(in environment: [String: String]) -> String? {
        guard let pathValue = environment["PATH"] else { return nil }
        for dir in pathValue.split(separator: ":") where !dir.isEmpty {
            let candidate = (String(dir) as NSString).appendingPathComponent("git")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: Entry Point

    public func merge(
        relativePath: String,
        baseSource: String,
        leftSource: String,
        rightSource: String
    ) -> GuardedMergeOutcome {
        guard let gitPath = gitExecutablePath else {
            return .lineMergeUnavailable(reason: "git executable not found in PATH")
        }
        let base = Array(baseSource.utf8)
        let left = Array(leftSource.utf8)
        let right = Array(rightSource.utf8)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-line-merge-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: workDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .lineMergeUnavailable(reason: "cannot create scratch directory: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: workDir) }

        // A program that merely happens to be called `git` (or a shim that cannot find the real one) must not be
        // mistaken for a merge result: its exit status would be read as "clean" or as a number of conflicts.
        if let identityProblem = Self.gitIdentityProblem(gitPath: gitPath, workDir: workDir) {
            return .lineMergeUnavailable(reason: identityProblem)
        }

        // Step 1: the line-level merge is the reference for everything that follows.
        let lineRun: GitMergeFileRun
        do {
            lineRun = try Self.runGitMergeFile(
                gitPath: gitPath,
                workDir: workDir,
                tag: "plain",
                left: left,
                base: base,
                right: right,
                extraArguments: []
            )
        } catch let failure as GitMergeFileFailure {
            return .lineMergeUnavailable(reason: failure.reason)
        } catch {
            return .lineMergeUnavailable(reason: error.localizedDescription)
        }

        let fileExtension = (relativePath as NSString).pathExtension.lowercased()

        if lineRun.conflictCount == 0 {
            let mergedText = String(decoding: lineRun.output, as: UTF8.self)
            let verdict = LanguageSyntaxValidator.validate(source: mergedText, filePath: relativePath)
            guard verdict.passed else {
                return .syntaxCheckFailed(parser: verdict.parserUsed ?? "parser", diagnostic: verdict.diagnostic)
            }
            return .clean(
                mergedText: mergedText,
                strategy: .lineLevel,
                syntaxParser: verdict.parserUsed,
                resolvedConflictBlocks: 0
            )
        }

        // Step 2: git reported conflicts. Everything below either proves a declaration-level resolution safe
        // or falls back to git's conflict-marked text.
        let openingMarker = Array((String(repeating: "<", count: 7) + " " + Self.leftLabel + "\n").utf8)
        let hasOpeningMarker = Self.splitLinesKeepingTerminators(lineRun.output).contains { Array($0) == openingMarker }
        guard hasOpeningMarker else {
            return .lineMergeUnavailable(
                reason: "`git merge-file` exited with status \(lineRun.conflictCount) but printed no conflict markers"
            )
        }
        let lineMergeText = String(decoding: lineRun.output, as: UTF8.self)
        func conflict(_ verdict: GuardedMergeDeclarationVerdict) -> GuardedMergeOutcome {
            .conflict(lineMergeText: lineMergeText, conflictCount: lineRun.conflictCount, declarationVerdict: verdict)
        }

        guard LanguageSyntaxValidator.hasSyntaxChecker(forFilePath: relativePath) else {
            return conflict(.noSyntaxCheckerForFileType(fileExtension: fileExtension))
        }

        // git must add a newline in front of a conflict marker when a side's last line has none, which would make
        // the end of file ambiguous. Files that all lack the final newline are merged as if they had one and the
        // newline is removed again at the end; mixed cases are left to the user.
        let terminated = [base, left, right].map { $0.isEmpty || $0.last == 0x0A }
        let stripFinalNewline: Bool
        var structuralBase = base
        var structuralLeft = left
        var structuralRight = right
        if terminated.allSatisfy({ $0 }) {
            stripFinalNewline = false
        } else if terminated.allSatisfy({ !$0 }) {
            stripFinalNewline = true
            structuralBase.append(0x0A)
            structuralLeft.append(0x0A)
            structuralRight.append(0x0A)
        } else {
            return conflict(.inconsistentFinalNewline)
        }

        let markerSize = Self.unambiguousMarkerSize(for: [structuralBase, structuralLeft, structuralRight])
        let structuralRun: GitMergeFileRun
        do {
            structuralRun = try Self.runGitMergeFile(
                gitPath: gitPath,
                workDir: workDir,
                tag: "diff3",
                left: structuralLeft,
                base: structuralBase,
                right: structuralRight,
                extraArguments: ["--diff3", "--marker-size=\(markerSize)"]
            )
        } catch let failure as GitMergeFileFailure {
            return conflict(.structuralMergeUnreadable(detail: failure.reason))
        } catch {
            return conflict(.structuralMergeUnreadable(detail: error.localizedDescription))
        }

        let segments: [MergeSegment]
        switch Self.parseDiff3(structuralRun.output, markerSize: markerSize) {
        case .failure(let parseFailure):
            return conflict(.structuralMergeUnreadable(detail: parseFailure.detail))
        case .success(let parsed):
            segments = parsed
        }
        let blockCount = segments.reduce(0) { count, segment in
            if case .conflict = segment { return count + 1 }
            return count
        }
        guard blockCount > 0 else {
            return conflict(.structuralMergeUnreadable(detail: "no conflict block found in --diff3 output"))
        }
        var blockNumber = 0
        for segment in segments {
            if case .conflict(_, let baseLines, _) = segment {
                blockNumber += 1
                if !baseLines.isEmpty {
                    return conflict(.conflictTouchesBaseLines(blockNumber: blockNumber, blockCount: blockCount))
                }
            }
        }

        // The declaration-level engine is consulted as a referee only.
        let report = ThreeWaySemanticASTMerger().mergeFile(
            relativePath: relativePath,
            baseSource: baseSource,
            leftSource: leftSource,
            rightSource: rightSource,
            leftLaneID: Self.leftLabel,
            rightLaneID: Self.rightLabel
        )
        guard report.isCleanlyMerged else {
            return conflict(.engineReportedConflicts(count: max(1, report.unresolvedConflictCount)))
        }

        let engineLines = Self.nonBlankLines(Array(report.mergedText.utf8))
        var cursor = 0
        var assembled: [UInt8] = []
        assembled.reserveCapacity(left.count + right.count)
        blockNumber = 0
        for segment in segments {
            switch segment {
            case .stable(let bytes):
                let expected = Self.nonBlankLines(bytes)
                guard Self.sequence(engineLines, at: cursor, startsWith: expected) else {
                    return conflict(.engineDisagreesWithLineMerge(
                        detail: "lines outside the conflict blocks differ near non-blank line \(cursor + 1)"
                    ))
                }
                cursor += expected.count
                assembled.append(contentsOf: bytes)
            case .conflict(let leftBytes, _, let rightBytes):
                blockNumber += 1
                let leftLines = Self.nonBlankLines(leftBytes)
                let rightLines = Self.nonBlankLines(rightBytes)
                if Self.sequence(engineLines, at: cursor, startsWith: leftLines + rightLines) {
                    assembled.append(contentsOf: leftBytes)
                    assembled.append(contentsOf: rightBytes)
                } else if Self.sequence(engineLines, at: cursor, startsWith: rightLines + leftLines) {
                    assembled.append(contentsOf: rightBytes)
                    assembled.append(contentsOf: leftBytes)
                } else {
                    return conflict(.engineDisagreesWithLineMerge(
                        detail: "conflict block \(blockNumber) of \(blockCount): the engine did not keep both sides' inserted lines together at this position"
                    ))
                }
                cursor += leftLines.count + rightLines.count
            }
        }
        guard cursor == engineLines.count else {
            return conflict(.engineDisagreesWithLineMerge(
                detail: "the engine emitted \(engineLines.count - cursor) extra non-blank line(s)"
            ))
        }

        if stripFinalNewline, assembled.last == 0x0A {
            assembled.removeLast()
        }
        let assembledText = String(decoding: assembled, as: UTF8.self)
        let verdict = LanguageSyntaxValidator.validate(source: assembledText, filePath: relativePath)
        guard verdict.passed, let parser = verdict.parserUsed else {
            return conflict(.assembledTextFailedSyntaxCheck(
                parser: verdict.parserUsed ?? "parser",
                diagnostic: verdict.diagnostic
            ))
        }
        return .clean(
            mergedText: assembledText,
            strategy: .declarationLevel,
            syntaxParser: parser,
            resolvedConflictBlocks: blockCount
        )
    }

    // MARK: git merge-file

    struct GitMergeFileRun {
        let conflictCount: Int
        let output: [UInt8]
    }

    struct GitMergeFileFailure: Error {
        let reason: String
    }

    /// Runs `git merge-file -p` on private copies of the three versions. The child gets a minimal environment and a
    /// working directory outside any repository, so no user, system or repository git configuration (for example
    /// `merge.conflictStyle`) can change the output.
    static func runGitMergeFile(
        gitPath: String,
        workDir: URL,
        tag: String,
        left: [UInt8],
        base: [UInt8],
        right: [UInt8],
        extraArguments: [String]
    ) throws -> GitMergeFileRun {
        let leftURL = workDir.appendingPathComponent("\(tag)-left")
        let baseURL = workDir.appendingPathComponent("\(tag)-base")
        let rightURL = workDir.appendingPathComponent("\(tag)-right")
        do {
            try Data(left).write(to: leftURL)
            try Data(base).write(to: baseURL)
            try Data(right).write(to: rightURL)
        } catch {
            throw GitMergeFileFailure(reason: "cannot write scratch files: \(error.localizedDescription)")
        }

        let result: (status: Int32, exitedNormally: Bool, stdout: Data, stderr: Data)
        do {
            result = try runGit(
                gitPath: gitPath,
                workDir: workDir,
                arguments: ["merge-file", "-p"] + extraArguments + [
                    "-L", leftLabel, "-L", baseLabel, "-L", rightLabel,
                    leftURL.path, baseURL.path, rightURL.path
                ]
            )
        } catch {
            throw GitMergeFileFailure(reason: "cannot run \(gitPath): \(error.localizedDescription)")
        }

        // `git merge-file` exits 0 when clean, with the number of conflicts (capped at 127) otherwise,
        // and with a value above 127 on error.
        guard result.exitedNormally, result.status >= 0, result.status <= 127 else {
            let stderrText = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitMergeFileFailure(
                reason: "`git merge-file` failed (status \(result.status))" + (stderrText.isEmpty ? "" : ": \(stderrText)")
            )
        }
        return GitMergeFileRun(conflictCount: Int(result.status), output: Array(result.stdout))
    }

    /// Returns nil when `gitPath --version` identifies itself as git, otherwise a description of what went wrong.
    static func gitIdentityProblem(gitPath: String, workDir: URL) -> String? {
        do {
            let result = try runGit(gitPath: gitPath, workDir: workDir, arguments: ["--version"])
            let text = String(decoding: result.stdout, as: UTF8.self)
            if result.exitedNormally, result.status == 0, text.hasPrefix("git version ") {
                return nil
            }
            let stderrText = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(gitPath) --version` did not answer as git (status \(result.status))"
                + (stderrText.isEmpty ? "" : ": \(stderrText)")
        } catch {
            return "cannot run \(gitPath): \(error.localizedDescription)"
        }
    }

    /// Runs git with a minimal environment and a working directory outside any repository.
    private static func runGit(
        gitPath: String,
        workDir: URL,
        arguments: [String]
    ) throws -> (status: Int32, exitedNormally: Bool, stdout: Data, stderr: Data) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gitPath)
        proc.arguments = arguments
        proc.currentDirectoryURL = workDir
        proc.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": workDir.path,
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CEILING_DIRECTORIES": workDir.deletingLastPathComponent().path,
            "GIT_TERMINAL_PROMPT": "0"
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        try proc.run()

        // Both pipes are drained while the child runs, so output of any size cannot block it.
        final class DataBox: @unchecked Sendable {
            var data = Data()
        }
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        proc.waitUntilExit()
        group.wait()
        return (proc.terminationStatus, proc.terminationReason == .exit, outBox.data, errBox.data)
    }

    // MARK: --diff3 Output Parsing

    enum MergeSegment: Equatable {
        case stable([UInt8])
        case conflict(left: [UInt8], base: [UInt8], right: [UInt8])
    }

    struct Diff3ParseFailure: Error {
        let detail: String
    }

    /// Smallest marker width (at least git's default 7) that no line of the inputs can be mistaken for:
    /// one more than the longest run of a marker character at the start of any input line.
    static func unambiguousMarkerSize(for inputs: [[UInt8]]) -> Int {
        let markerBytes: Set<UInt8> = [0x3C, 0x7C, 0x3D, 0x3E] // < | = >
        var longestRun = 0
        for input in inputs {
            var atLineStart = true
            var runByte: UInt8 = 0
            var runLength = 0
            for byte in input {
                if byte == 0x0A {
                    atLineStart = true
                    runLength = 0
                    continue
                }
                if atLineStart {
                    atLineStart = false
                    if markerBytes.contains(byte) {
                        runByte = byte
                        runLength = 1
                        longestRun = max(longestRun, runLength)
                    } else {
                        runLength = 0
                    }
                } else if runLength > 0 {
                    if byte == runByte {
                        runLength += 1
                        longestRun = max(longestRun, runLength)
                    } else {
                        runLength = 0
                    }
                }
            }
        }
        return max(7, longestRun + 1)
    }

    static func parseDiff3(_ output: [UInt8], markerSize: Int) -> Result<[MergeSegment], Diff3ParseFailure> {
        func marker(_ byte: UInt8, label: String?) -> [UInt8] {
            var line = [UInt8](repeating: byte, count: markerSize)
            if let label {
                line.append(0x20)
                line.append(contentsOf: Array(label.utf8))
            }
            line.append(0x0A)
            return line
        }
        let leftMarker = marker(0x3C, label: leftLabel)
        let baseMarker = marker(0x7C, label: baseLabel)
        let separator = marker(0x3D, label: nil)
        let rightMarker = marker(0x3E, label: rightLabel)

        enum State {
            case stable
            case left
            case base
            case right
        }
        var state = State.stable
        var segments: [MergeSegment] = []
        var stableBytes: [UInt8] = []
        var leftBytes: [UInt8] = []
        var baseBytes: [UInt8] = []
        var rightBytes: [UInt8] = []

        for line in splitLinesKeepingTerminators(output) {
            let lineBytes = Array(line)
            switch state {
            case .stable:
                if lineBytes == leftMarker {
                    if !stableBytes.isEmpty {
                        segments.append(.stable(stableBytes))
                        stableBytes = []
                    }
                    state = .left
                } else if lineBytes == baseMarker || lineBytes == separator || lineBytes == rightMarker {
                    return .failure(Diff3ParseFailure(detail: "conflict marker outside a conflict block"))
                } else {
                    stableBytes.append(contentsOf: lineBytes)
                }
            case .left:
                if lineBytes == baseMarker {
                    state = .base
                } else if lineBytes == leftMarker || lineBytes == separator || lineBytes == rightMarker {
                    return .failure(Diff3ParseFailure(detail: "unexpected conflict marker inside the left side"))
                } else {
                    leftBytes.append(contentsOf: lineBytes)
                }
            case .base:
                if lineBytes == separator {
                    state = .right
                } else if lineBytes == leftMarker || lineBytes == baseMarker || lineBytes == rightMarker {
                    return .failure(Diff3ParseFailure(detail: "unexpected conflict marker inside the base side"))
                } else {
                    baseBytes.append(contentsOf: lineBytes)
                }
            case .right:
                if lineBytes == rightMarker {
                    segments.append(.conflict(left: leftBytes, base: baseBytes, right: rightBytes))
                    leftBytes = []
                    baseBytes = []
                    rightBytes = []
                    state = .stable
                } else if lineBytes == leftMarker || lineBytes == baseMarker || lineBytes == separator {
                    return .failure(Diff3ParseFailure(detail: "unexpected conflict marker inside the right side"))
                } else {
                    rightBytes.append(contentsOf: lineBytes)
                }
            }
        }
        guard case .stable = state else {
            return .failure(Diff3ParseFailure(detail: "unterminated conflict block"))
        }
        if !stableBytes.isEmpty {
            segments.append(.stable(stableBytes))
        }
        return .success(segments)
    }

    // MARK: Byte-Level Line Helpers

    /// Splits at "\n" and keeps the terminator with its line. The last piece has no terminator when the input does not end in one.
    static func splitLinesKeepingTerminators(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var lines: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        for index in bytes.indices where bytes[index] == 0x0A {
            lines.append(bytes[start...index])
            start = index + 1
        }
        if start < bytes.endIndex {
            lines.append(bytes[start..<bytes.endIndex])
        }
        return lines
    }

    /// Lines without their "\n", dropping lines that contain only spaces, tabs, carriage returns, vertical tabs or form feeds.
    /// Everything else, including leading and trailing whitespace of non-blank lines, is kept byte for byte.
    static func nonBlankLines(_ bytes: [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        for line in splitLinesKeepingTerminators(bytes) {
            var content = Array(line)
            if content.last == 0x0A {
                content.removeLast()
            }
            let isBlank = content.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0B || $0 == 0x0C }
            if !isBlank {
                result.append(content)
            }
        }
        return result
    }

    static func sequence(_ haystack: [[UInt8]], at offset: Int, startsWith needle: [[UInt8]]) -> Bool {
        guard offset >= 0, offset + needle.count <= haystack.count else { return false }
        for index in needle.indices where haystack[offset + index] != needle[index] {
            return false
        }
        return true
    }
}
