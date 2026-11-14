import Foundation
import RelayModels

// MARK: - Real Language Parser Syntax Gate for 3-Way Semantic Merge (M0 Guardrail)

public struct SyntaxValidationVerdict: Sendable, Equatable {
    public let passed: Bool
    public let parserUsed: String?
    public let diagnostic: String

    public init(passed: Bool, parserUsed: String?, diagnostic: String = "") {
        self.passed = passed
        self.parserUsed = parserUsed
        self.diagnostic = diagnostic
    }
}

public enum LanguageSyntaxValidator {

    /// Validates `source` using the host machine's native language parser before emitting merged code.
    /// Never executes user code: uses `python3 -m py_compile` (Python), `xcrun swiftc -parse` (Swift),
    /// `node --check` (JavaScript), `module.stripTypeScriptTypes` + `node --check` (TypeScript), and `JSONSerialization` (JSON).
    public static func validate(source: String, filePath: String) -> SyntaxValidationVerdict {
        let ext = (filePath as NSString).pathExtension.lowercased()
        switch ext {
        case "py", "pyi":
            return validatePython(source: source)
        case "swift":
            return validateSwift(source: source)
        case "js", "mjs", "cjs":
            return validateJavaScript(source: source, fileExtension: ext)
        case "ts", "tsx":
            return validateTypeScript(source: source, fileExtension: ext)
        case "json":
            return validateJSON(source: source)
        default:
            return SyntaxValidationVerdict(passed: true, parserUsed: nil)
        }
    }

    // MARK: - Language Runners

    private static func validatePython(source: String) -> SyntaxValidationVerdict {
        guard let pythonExe = resolveExecutable(named: "python3", candidates: ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]) else {
            return SyntaxValidationVerdict(passed: false, parserUsed: "python3 -m py_compile", diagnostic: "python3 executable not found on host")
        }
        return withIsolatedTempFile(contents: source, fileName: "merged_check.py") { fileURL, _ in
            let res = runProcess(executable: pythonExe, arguments: ["-m", "py_compile", fileURL.path])
            if res.exitCode == 0 {
                return SyntaxValidationVerdict(passed: true, parserUsed: "python3 -m py_compile")
            }
            return SyntaxValidationVerdict(
                passed: false,
                parserUsed: "python3 -m py_compile",
                diagnostic: conciseDiagnostic(from: res.stderr.isEmpty ? res.stdout : res.stderr)
            )
        }
    }

    private static func validateSwift(source: String) -> SyntaxValidationVerdict {
        let xcrunPath = "/usr/bin/xcrun"
        guard FileManager.default.isExecutableFile(atPath: xcrunPath) else {
            return SyntaxValidationVerdict(passed: false, parserUsed: "swiftc -parse", diagnostic: "/usr/bin/xcrun not found on host")
        }
        return withIsolatedTempFile(contents: source, fileName: "MergedCheck.swift") { fileURL, _ in
            let res = runProcess(executable: xcrunPath, arguments: ["swiftc", "-parse", fileURL.path])
            if res.exitCode == 0 {
                return SyntaxValidationVerdict(passed: true, parserUsed: "swiftc -parse")
            }
            return SyntaxValidationVerdict(
                passed: false,
                parserUsed: "swiftc -parse",
                diagnostic: conciseDiagnostic(from: res.stderr.isEmpty ? res.stdout : res.stderr)
            )
        }
    }

    private static func validateJavaScript(source: String, fileExtension: String) -> SyntaxValidationVerdict {
        guard let nodeExe = resolveExecutable(named: "node", candidates: ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]) else {
            return SyntaxValidationVerdict(passed: false, parserUsed: "node --check", diagnostic: "node executable not found on host")
        }
        return withIsolatedTempFile(contents: source, fileName: "merged_check.\(fileExtension)") { fileURL, _ in
            let res = runProcess(executable: nodeExe, arguments: ["--no-warnings", "--check", fileURL.path])
            if res.exitCode == 0 {
                return SyntaxValidationVerdict(passed: true, parserUsed: "node --check")
            }
            return SyntaxValidationVerdict(
                passed: false,
                parserUsed: "node --check",
                diagnostic: conciseDiagnostic(from: res.stderr.isEmpty ? res.stdout : res.stderr)
            )
        }
    }

    private static func validateTypeScript(source: String, fileExtension: String) -> SyntaxValidationVerdict {
        if let tscExe = resolveExecutable(named: "tsc", candidates: ["/opt/homebrew/bin/tsc", "/usr/local/bin/tsc"]) {
            return withIsolatedTempFile(contents: source, fileName: "merged_check.\(fileExtension)") { fileURL, _ in
                let res = runProcess(executable: tscExe, arguments: ["--noEmit", "--pretty", "false", "--skipLibCheck", fileURL.path])
                if res.exitCode == 0 {
                    return SyntaxValidationVerdict(passed: true, parserUsed: "tsc --noEmit")
                }
                return SyntaxValidationVerdict(
                    passed: false,
                    parserUsed: "tsc --noEmit",
                    diagnostic: conciseDiagnostic(from: res.stderr.isEmpty ? res.stdout : res.stderr)
                )
            }
        }

        guard let nodeExe = resolveExecutable(named: "node", candidates: ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]) else {
            return SyntaxValidationVerdict(passed: false, parserUsed: "node stripTypeScriptTypes + --check", diagnostic: "neither tsc nor node found on host")
        }

        return withIsolatedTempFile(contents: source, fileName: "merged_check.\(fileExtension)") { tsURL, tempDir in
            let jsURL = tempDir.appendingPathComponent("stripped_check.js")
            let stripScript = #"const fs=require("fs"),m=require("module"); fs.writeFileSync(process.argv[2], m.stripTypeScriptTypes(fs.readFileSync(process.argv[1],"utf8")));"#
            let stripRes = runProcess(
                executable: nodeExe,
                arguments: ["--no-warnings", "-e", stripScript, tsURL.path, jsURL.path]
            )
            guard stripRes.exitCode == 0 else {
                return SyntaxValidationVerdict(
                    passed: false,
                    parserUsed: "node stripTypeScriptTypes",
                    diagnostic: conciseDiagnostic(from: stripRes.stderr.isEmpty ? stripRes.stdout : stripRes.stderr)
                )
            }

            let checkRes = runProcess(
                executable: nodeExe,
                arguments: ["--no-warnings", "--check", jsURL.path]
            )
            if checkRes.exitCode == 0 {
                return SyntaxValidationVerdict(passed: true, parserUsed: "node stripTypeScriptTypes + --check")
            }
            return SyntaxValidationVerdict(
                passed: false,
                parserUsed: "node --check",
                diagnostic: conciseDiagnostic(from: checkRes.stderr.isEmpty ? checkRes.stdout : checkRes.stderr)
            )
        }
    }

    private static func validateJSON(source: String) -> SyntaxValidationVerdict {
        do {
            _ = try JSONSerialization.jsonObject(with: Data(source.utf8), options: [.fragmentsAllowed])
            return SyntaxValidationVerdict(passed: true, parserUsed: "JSONSerialization")
        } catch {
            return SyntaxValidationVerdict(
                passed: false,
                parserUsed: "JSONSerialization",
                diagnostic: error.localizedDescription
            )
        }
    }

    // MARK: - Subprocess & Temp Helpers

    private static func withIsolatedTempFile(
        contents: String,
        fileName: String,
        body: (URL, URL) -> SyntaxValidationVerdict
    ) -> SyntaxValidationVerdict {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-syntax-check-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let fileURL = dir.appendingPathComponent(fileName)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            return body(fileURL, dir)
        } catch {
            return SyntaxValidationVerdict(passed: false, parserUsed: "tempfile", diagnostic: error.localizedDescription)
        }
    }

    private static func resolveExecutable(named name: String, candidates: [String]) -> String? {
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = (String(dir) as NSString).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    private static func runProcess(executable: String, arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        proc.environment = env

        do {
            try proc.run()
        } catch {
            return (exitCode: 127, stdout: "", stderr: error.localizedDescription)
        }

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

        return (
            exitCode: proc.terminationStatus,
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self)
        )
    }

    private static func conciseDiagnostic(from raw: String) -> String {
        let trimmed = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .joined(separator: " | ")
        return trimmed.isEmpty ? "syntax check exited with non-zero status" : trimmed
    }
}
