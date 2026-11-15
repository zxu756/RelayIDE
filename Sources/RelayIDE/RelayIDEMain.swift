import AppKit
import Darwin
import Foundation
import RelayCLIAndMCP
import RelayModels
import RelayStudioViews
import SwiftUI

// MARK: - Native macOS SwiftUI Desktop Workbench Scene

@MainActor
struct RelayStudioDesktopApp: App {
    @StateObject private var viewModel: RelayStudioViewModel
    @ObservedObject private var localizer: RelayLocalizer

    init() {
        let args = Array(CommandLine.arguments.dropFirst())
        var initialBundleURL: URL?
        if let openIdx = args.firstIndex(of: "--project"), openIdx + 1 < args.count {
            initialBundleURL = URL(fileURLWithPath: args[openIdx + 1])
        } else if let directProj = args.first(where: { $0.hasSuffix(".relayproj") }) {
            initialBundleURL = URL(fileURLWithPath: directProj)
        }
        let sharedLocalizer = RelayLocalizer.shared
        let loadDemo = args.contains("--demo")
        let vm = RelayStudioViewModel(
            projectBundleURL: initialBundleURL,
            initialPane: .ptyGrid,
            localizer: sharedLocalizer,
            loadDemoWorkspace: loadDemo
        )
        _viewModel = StateObject(wrappedValue: vm)
        self.localizer = sharedLocalizer

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup(localizer.L(
            "RelayIDE · Multi-Agent Orchestration Workbench",
            "RelayIDE · 多智能体接力编排工作台"
        )) {
            RelayStudioRootWorkbenchView(viewModel: viewModel)
                .frame(minWidth: 1240, minHeight: 780)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1360, height: 840)
        .commands {
            RelayStudioMenuCommands(viewModel: viewModel)
        }
    }
}

// MARK: - Unified Desktop + Headless CLI + MCP + Retina Screenshot Entry Point

@MainActor
@main
enum RelayIDEBootstrap {
    static func main() async {
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        let disposition = RelayCLIRunner.classifyLaunchArguments(rawArguments)

        switch disposition {
        case .exportScreenshots(let exportDir):
            let filteredArgs = RelayCLIRunner.filterSystemLaunchArguments(rawArguments)
            let cliLang = RelayLocalizer.parseCLILanguageOverride(arguments: filteredArgs)
            do {
                let records = try runHeadlessRetinaExport(to: exportDir, language: cliLang)
                for rec in records {
                    print("Exported \(rec.fileName) (\(rec.pixelWidth)x\(rec.pixelHeight) px) -> \(rec.outputURL.path)")
                }
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("RelayIDE screenshot export error: \(error.localizedDescription)\n".utf8))
                Darwin.exit(125)
            }

        case .headlessCLI(let filteredArgs, let subcommand):
            let stderrLock = NSLock()
            let liveStderrWriter: @Sendable (String) -> Void = { line in
                stderrLock.lock()
                FileHandle.standardError.write(Data((line + "\n").utf8))
                stderrLock.unlock()
            }
            let runner: RelayCLIRunner
            let signalForwarder: RelayCLISignalForwarder?
            if subcommand == "run" {
                let ctx = RelayCLIRunner.makeSignalForwardedRunContext()
                runner = ctx.runner
                signalForwarder = ctx.forwarder
            } else {
                runner = RelayCLIRunner()
                signalForwarder = nil
            }
            defer { signalForwarder?.stop() }
            let result = await runner.executeCommand(
                arguments: filteredArgs,
                onLiveStderrLine: liveStderrWriter
            )
            if result.exitCode == 0, subcommand == "export-html" {
                let subcommandArgs = stripLeadingLanguageFlags(from: filteredArgs)
                if let htmlOutURL = parseExportHTMLTargetURL(from: subcommandArgs) {
                    try? RelayHallmarkDossierNormalizer.normalizeFileIfPresent(at: htmlOutURL)
                }
            }
            writeCLIResultAndExit(result)

        case .unknownSubcommand(let filteredArgs, _):
            let runner = RelayCLIRunner()
            let result = await runner.executeCommand(arguments: filteredArgs)
            writeCLIResultAndExit(result)

        case .desktopWorkbench:
            launchDesktopWorkbench()
        }
    }

    private static func writeCLIResultAndExit(_ result: RelayCLIExecutionResult) -> Never {
        if !result.stdout.isEmpty {
            if result.stdoutIsVerbatim {
                // Merged file content: written byte for byte, without the newline `print` would append.
                FileHandle.standardOutput.write(Data(result.stdout.utf8))
            } else {
                print(result.stdout)
            }
        }
        if !result.stderr.isEmpty && !result.stderrAlreadyStreamed {
            FileHandle.standardError.write(Data((result.stderr + "\n").utf8))
        }
        Darwin.exit(result.exitCode)
    }

    private static func stripLeadingLanguageFlags(from args: [String]) -> [String] {
        var cleaned: [String] = []
        var idx = 0
        while idx < args.count {
            let tok = args[idx]
            if tok == "--lang" {
                idx += 2
                continue
            }
            if tok.hasPrefix("--lang=") {
                idx += 1
                continue
            }
            cleaned.append(tok)
            idx += 1
        }
        return cleaned
    }

    private static func parseExportHTMLTargetURL(from args: [String]) -> URL? {
        if let outIdx = args.firstIndex(of: "--output"), outIdx + 1 < args.count {
            return URL(fileURLWithPath: args[outIdx + 1])
        }
        var idx = 1
        while idx < args.count {
            let token = args[idx]
            if token == "--project" || token == "-p" || token == "--lang" {
                idx += 2
                continue
            }
            if !token.hasPrefix("-") {
                return URL(fileURLWithPath: token)
            }
            idx += 1
        }
        return nil
    }

    @MainActor
    private static func runHeadlessRetinaExport(
        to directoryURL: URL,
        language: RelayLanguage?
    ) throws -> [RelayRetinaScreenshotExporter.ExportedScreenshotRecord] {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        return try RelayRetinaScreenshotExporter.exportFlagshipScreenshots(
            to: directoryURL,
            language: language
        )
    }

    @MainActor
    private static func launchDesktopWorkbench() {
        RelayStudioDesktopApp.main()
    }
}
