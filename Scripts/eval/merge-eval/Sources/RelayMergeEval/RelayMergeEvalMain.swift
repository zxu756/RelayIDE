import Foundation
import RelayModels
import RelaySemanticMerge

private func writeStderr(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func printUsage() {
    writeStderr("Usage: relay-merge-eval [--path <relative-path>] [-o <output-file>] <base-file> <left-file> <right-file>")
}

private func runMain() -> Int32 {
    let rawArgs = Array(CommandLine.arguments.dropFirst())
    var relativePathOverride: String?
    var outputPath: String?
    var positional: [String] = []

    var i = 0
    while i < rawArgs.count {
        let arg = rawArgs[i]
        if arg == "-h" || arg == "--help" {
            printUsage()
            return 0
        } else if arg == "--path" {
            guard i + 1 < rawArgs.count else {
                writeStderr("relay-merge-eval: missing value after --path")
                return 2
            }
            relativePathOverride = rawArgs[i + 1]
            i += 2
        } else if arg == "-o" || arg == "--output" {
            guard i + 1 < rawArgs.count else {
                writeStderr("relay-merge-eval: missing value after \(arg)")
                return 2
            }
            outputPath = rawArgs[i + 1]
            i += 2
        } else if arg.hasPrefix("-") {
            writeStderr("relay-merge-eval: unknown option '\(arg)'")
            return 2
        } else {
            positional.append(arg)
            i += 1
        }
    }

    guard positional.count == 3 else {
        printUsage()
        return 2
    }

    var sources: [String] = []
    sources.reserveCapacity(3)
    for path in positional {
        guard let data = FileManager.default.contents(atPath: path) else {
            writeStderr("relay-merge-eval: cannot read file '\(path)'")
            return 2
        }
        let text = String(decoding: data, as: UTF8.self)
        guard Array(text.utf8) == Array(data) else {
            writeStderr("relay-merge-eval: file '\(path)' is not valid UTF-8")
            return 2
        }
        sources.append(text)
    }

    let relativePath = relativePathOverride ?? (positional[0] as NSString).lastPathComponent
    let report = ThreeWaySemanticASTMerger().mergeFile(
        relativePath: relativePath,
        baseSource: sources[0],
        leftSource: sources[1],
        rightSource: sources[2],
        leftLaneID: "left",
        rightLaneID: "right"
    )

    guard report.isCleanlyMerged else {
        writeStderr(
            "relay-merge-eval: conflict (unresolved=\(report.unresolvedConflictCount), collisions=\(report.crossFileCollisions.count))"
        )
        return 1
    }

    let mergedBytes = Data(report.mergedText.utf8)
    if let outPath = outputPath {
        do {
            try mergedBytes.write(to: URL(fileURLWithPath: outPath))
        } catch {
            writeStderr("relay-merge-eval: failed writing output '\(outPath)': \(error.localizedDescription)")
            return 2
        }
    } else {
        FileHandle.standardOutput.write(mergedBytes)
    }
    return 0
}

Foundation.exit(runMain())
