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

    init() {
        let args = Array(CommandLine.arguments.dropFirst())
        var initialBundleURL: URL?
        if let openIdx = args.firstIndex(of: "--project"), openIdx + 1 < args.count {
            initialBundleURL = URL(fileURLWithPath: args[openIdx + 1])
        } else if let directProj = args.first(where: { $0.hasSuffix(".relayproj") }) {
            initialBundleURL = URL(fileURLWithPath: directProj)
        }
        let vm = RelayStudioViewModel(projectBundleURL: initialBundleURL, initialPane: .ptyGrid)
        _viewModel = StateObject(wrappedValue: vm)

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("RelayIDE — Multi-Agent Orchestration Workbench") {
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
    private static let cliSubcommands: Set<String> = [
        "init",
        "status",
        "lanes",
        "dag-waves",
        "semantic-merge",
        "audit-plugins",
        "export-html",
        "mcp",
        "help",
        "--help",
        "-h",
        "version",
        "--version"
    ]

    static func main() async {
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        let filteredArgs = rawArguments.filter { arg in
            !arg.hasPrefix("-psn_") && arg != "-NSDocumentRevisionsDebugMode" && arg != "YES" && arg != "NO"
        }

        // 1. Deterministic 2x Retina Screenshot Export Mode
        if let exportDir = parseExportScreenshotsDirectory(from: filteredArgs) {
            do {
                let records = try runHeadlessRetinaExport(to: exportDir)
                for rec in records {
                    print("Exported \(rec.fileName) (\(rec.pixelWidth)x\(rec.pixelHeight) px) -> \(rec.outputURL.path)")
                }
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("RelayIDE screenshot export error: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }

        // 2. Headless CLI & JSON-RPC 2.0 MCP Server Subcommands
        if let firstArg = filteredArgs.first, cliSubcommands.contains(firstArg) {
            let runner = RelayCLIRunner()
            do {
                let output = try await runner.execute(arguments: filteredArgs)
                if firstArg == "export-html", let htmlOutURL = parseExportHTMLTargetURL(from: filteredArgs) {
                    try RelayHallmarkDossierNormalizer.normalizeFileIfPresent(at: htmlOutURL)
                }
                if !output.isEmpty {
                    print(output)
                }
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("RelayIDE CLI error: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }

        // 3. Native macOS AppKit / SwiftUI Desktop Workbench Launch
        launchDesktopWorkbench()
    }

    private static func parseExportScreenshotsDirectory(from args: [String]) -> URL? {
        if let flagIdx = args.firstIndex(of: "--export-screenshots") {
            let path = (flagIdx + 1 < args.count) ? args[flagIdx + 1] : "./docs"
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        for arg in args where arg.hasPrefix("--export-screenshots=") {
            let path = String(arg.dropFirst("--export-screenshots=".count))
            return URL(fileURLWithPath: path.isEmpty ? "./docs" : path, isDirectory: true)
        }
        return nil
    }

    private static func parseExportHTMLTargetURL(from args: [String]) -> URL? {
        if let outIdx = args.firstIndex(of: "--output"), outIdx + 1 < args.count {
            return URL(fileURLWithPath: args[outIdx + 1])
        }
        var idx = 1
        while idx < args.count {
            let token = args[idx]
            if token == "--project" || token == "-p" {
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
    private static func runHeadlessRetinaExport(to directoryURL: URL) throws -> [RelayRetinaScreenshotExporter.ExportedScreenshotRecord] {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        return try RelayRetinaScreenshotExporter.exportFlagshipScreenshots(to: directoryURL)
    }

    @MainActor
    private static func launchDesktopWorkbench() {
        RelayStudioDesktopApp.main()
    }
}
