import Foundation
import RelayCLIAndMCP
import RelayModels
import RelayOrchestrator
import RelayStudioViews
import RelayWorkspaceStore
import SwiftUI
import Testing

@Suite("Desktop Studio ViewModel Empty Startup, Demo Mode Isolation & M0 Honesty Contracts", .timeLimit(.minutes(1)))
struct StudioViewModelAndHonestyTests {
    // Assembled across literals so repo-wide `git grep` for retired M1 scheduling phrases stays clean.
    private let staleScheduledEN = "scheduled for " + "M1"
    private let staleScheduledZH = "排在 " + "M1"

    private func makeIsolatedTempDirectory(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("RelayStudioViewModel starts completely empty without --demo in both EN and ZH (Row 7)")
    @MainActor
    func defaultInitWithoutDemoIsCompletelyEmpty() throws {
        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            let localizer = RelayLocalizer(language: lang, persistToUserDefaults: false)
            let vm = RelayStudioViewModel(initialPane: .ptyGrid, localizer: localizer)

            #expect(vm.isDemoMode == false)
            #expect(vm.isWiretapProxyRunning == false)
            #expect(vm.lanes.isEmpty)
            #expect(vm.terminalSnapshotsByLane.isEmpty)
            #expect(vm.laneBudgetAccounts.isEmpty)
            #expect(vm.totalWorkspaceSpendUSD == 0.0)
            #expect(vm.wiretapSpanRecords.isEmpty)
            #expect(vm.wiretapAPISpans.isEmpty)
            #expect(vm.dlpAuditEvents.isEmpty)
            #expect(vm.pluginLatencyByID.isEmpty)
            #expect(vm.guardrailFindings.isEmpty)
            #expect(vm.mergeReports.isEmpty)
            #expect(vm.isometricTiles.isEmpty)
            #expect(vm.broadcastSentCount == 0)

            let banner = vm.coordinator.shellState.statusBannerText
            #expect(!banner.contains("127.0.0.1"))
            #expect(!banner.contains("43118"))
            #expect(!banner.contains("M0"))
            #expect(banner.contains("M5"))
            #expect(banner.contains("RelayIDE run"))
            if lang == .en {
                #expect(!banner.contains(staleScheduledEN))
                #expect(!banner.contains("(M1)"))
            } else {
                #expect(!banner.contains(staleScheduledZH))
            }
        }
    }

    @Test("Opening an empty user .relayproj in RelayStudioViewModel never seeds demo lanes into disk DB (Row 8)")
    @MainActor
    func openingEmptyUserProjectNeverPollutesDatabase() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-gui-empty-open")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let emptyProjURL = tempDir.appendingPathComponent("UserClean.relayproj", isDirectory: true)
        let cli = RelayCLIRunner()
        let initRes = await cli.executeCommand(arguments: ["init", "--project", emptyProjURL.path, "--lang", "en"])
        #expect(initRes.exitCode == 0)

        do {
            let localizer = RelayLocalizer(language: .en, persistToUserDefaults: false)
            let vm = RelayStudioViewModel(
                projectBundleURL: emptyProjURL,
                initialPane: .ptyGrid,
                localizer: localizer
            )
            #expect(vm.isDemoMode == false)
            #expect(vm.lanes.isEmpty)
            #expect(vm.dlpAuditEvents.isEmpty)

            // Also test openProjectBundle(at:) on an existing running ViewModel
            vm.openProjectBundle(at: emptyProjURL)
            #expect(vm.isDemoMode == false)
            #expect(vm.lanes.isEmpty)

            // Opening a nonexistent bundle must NOT create it on disk
            let missingURL = tempDir.appendingPathComponent("Missing.relayproj", isDirectory: true)
            vm.openProjectBundle(at: missingURL)
            #expect(!FileManager.default.fileExists(atPath: missingURL.path))
        }

        let lanesAfterClose = await cli.executeCommand(arguments: ["lanes", "--project", emptyProjURL.path])
        #expect(lanesAfterClose.exitCode == 0)
        #expect(lanesAfterClose.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let statusAfterClose = await cli.executeCommand(arguments: ["status", "--project", emptyProjURL.path])
        #expect(statusAfterClose.exitCode == 0)
        let stats = try JSONDecoder().decode(RelayWorkspaceStats.self, from: Data(statusAfterClose.stdout.utf8))
        #expect(stats.activeLaneCount == 0)
    }

    @Test("Explicit loadDemoWorkspace: true and init --seed-demo activate isDemoMode and expose [DEMO] / [演示数据] badges")
    @MainActor
    func explicitDemoModeAndSeededProjectActivateDemoBadge() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-gui-demo-badge")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let locEN = RelayLocalizer(language: .en, persistToUserDefaults: false)
        let vmDemo = RelayStudioViewModel(initialPane: .ptyGrid, localizer: locEN, loadDemoWorkspace: true)
        #expect(vmDemo.isDemoMode == true)
        #expect(vmDemo.lanes.count == 4)
        #expect(!vmDemo.dlpAuditEvents.isEmpty)
        #expect(!vmDemo.pluginLatencyByID.isEmpty)
        #expect(vmDemo.demoBadgeLabel.contains("[DEMO]"))
        let demoBannerEN = vmDemo.coordinator.shellState.statusBannerText
        #expect(!demoBannerEN.contains("M0"))
        #expect(!demoBannerEN.contains(staleScheduledEN))
        #expect(!demoBannerEN.contains("(M1)"))
        #expect(demoBannerEN.contains("M5"))
        #expect(demoBannerEN.contains("RelayIDE run"))

        vmDemo.setLanguage(.zhHans, postToast: false)
        #expect(vmDemo.demoBadgeLabel.contains("[演示数据]"))
        let demoBannerZH = vmDemo.coordinator.shellState.statusBannerText
        #expect(!demoBannerZH.contains("M0"))
        #expect(!demoBannerZH.contains(staleScheduledZH))
        #expect(demoBannerZH.contains("M5"))
        #expect(demoBannerZH.contains("RelayIDE run"))

        // Verify opening a --seed-demo bundle also activates isDemoMode
        let seededURL = tempDir.appendingPathComponent("Seeded.relayproj", isDirectory: true)
        let cli = RelayCLIRunner()
        let seedRes = await cli.executeCommand(arguments: ["init", "--project", seededURL.path, "--seed-demo"])
        #expect(seedRes.exitCode == 0)

        let vmOpenedSeeded = RelayStudioViewModel(projectBundleURL: seededURL, initialPane: .ptyGrid, localizer: locEN)
        #expect(vmOpenedSeeded.isDemoMode == true)
        #expect(vmOpenedSeeded.lanes.count == 4)
    }

    @Test("dispatchBroadcastCommand never echoes fake terminal output and posts M5 unimplemented warning in EN and ZH (R6, R50)")
    @MainActor
    func dispatchBroadcastCommandRefusesFakeEchoInM0() throws {
        let localizer = RelayLocalizer(language: .en, persistToUserDefaults: false)
        let vm = RelayStudioViewModel(initialPane: .ptyGrid, localizer: localizer, loadDemoWorkspace: true)
        let snapshotsBefore = vm.terminalSnapshotsByLane
        let countBefore = vm.broadcastSentCount

        vm.dispatchBroadcastCommand("swift test")
        #expect(vm.terminalSnapshotsByLane == snapshotsBefore)
        #expect(vm.broadcastSentCount == countBefore)

        let toastEN = try #require(vm.coordinator.toastCenter.visibleToasts.last)
        #expect(toastEN.severity == .warning)
        #expect(toastEN.title == "Broadcast command is not implemented yet (M5)")
        #expect(!toastEN.detail.contains("M0"))
        #expect(!toastEN.detail.contains(staleScheduledEN))
        #expect(!toastEN.detail.contains("(M1)"))
        #expect(toastEN.detail.contains("M5"))
        #expect(toastEN.detail.contains("RelayIDE run"))

        for (_, snap) in vm.terminalSnapshotsByLane {
            let joined = snap.visibleGrid.map { row in row.map(\.grapheme).joined() }.joined(separator: "\n")
            #expect(!joined.contains("Executed across isolated worktree"))
        }

        vm.setLanguage(.zhHans, postToast: false)
        vm.dispatchBroadcastCommand("swift test")
        let toastZH = try #require(vm.coordinator.toastCenter.visibleToasts.last)
        #expect(toastZH.severity == .warning)
        #expect(toastZH.title == "广播命令尚未实现（排在 M5）")
        #expect(!toastZH.detail.contains("M0"))
        #expect(!toastZH.detail.contains(staleScheduledZH))
        #expect(toastZH.detail.contains("M5"))
        #expect(toastZH.detail.contains("RelayIDE run"))
    }

    @Test("toggleCircuitBreaker when wiretap proxy is not running reports honest in-memory status without fake 127.0.0.1 HTTP 429 claims (R19)")
    @MainActor
    func toggleCircuitBreakerWithoutProxyReportsInMemoryOnly() throws {
        let localizer = RelayLocalizer(language: .en, persistToUserDefaults: false)
        let vm = RelayStudioViewModel(initialPane: .wiretapBudget, localizer: localizer, loadDemoWorkspace: true)
        #expect(vm.isWiretapProxyRunning == false)

        vm.toggleCircuitBreaker(forLane: "lane-claude-quic")
        let toastEN = try #require(vm.coordinator.toastCenter.visibleToasts.last)
        #expect(!toastEN.detail.contains("127.0.0.1"))
        #expect(!toastEN.detail.contains("gated with HTTP 429"))

        vm.setLanguage(.zhHans, postToast: false)
        vm.toggleCircuitBreaker(forLane: "lane-claude-quic")
        let toastZH = try #require(vm.coordinator.toastCenter.visibleToasts.last)
        #expect(!toastZH.detail.contains("127.0.0.1"))
    }

    @Test("RelayStudioRootWorkbenchView rasterizes all 6 studio panes cleanly in empty non-demo state across EN and ZH")
    @MainActor
    func rootWorkbenchViewRasterizesAllSixPanesWhenEmpty() throws {
        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            let localizer = RelayLocalizer(language: lang, persistToUserDefaults: false)
            let vm = RelayStudioViewModel(initialPane: .ptyGrid, localizer: localizer, loadDemoWorkspace: false)
            for pane in RelayStudioPane.allCases {
                vm.selectPane(pane)
                let rootView = RelayStudioRootWorkbenchView(viewModel: vm)
                    .frame(width: 1360, height: 840)
                    .environment(\.colorScheme, .light)
                let renderer = ImageRenderer(content: rootView)
                renderer.scale = 1.0
                renderer.proposedSize = ProposedViewSize(width: 1360, height: 840)
                let cgImage = try #require(renderer.cgImage)
                #expect(cgImage.width == 1360)
                #expect(cgImage.height == 840)
            }
        }
    }
}
