import AppKit
import SwiftUI
import XCTest
import AgentLightCore
import AgentLightProtocol
@testable import AgentLightUI

@MainActor
final class ViewRenderingTests: XCTestCase {
    private var windows: [NSWindow] = []

    func testMonitoringViewRendersAtCompactSizeWithLongContent() async {
        let sessions = (0..<14).map { index in
            AgentEvent(
                source: AgentSource.allCases[index % AgentSource.allCases.count],
                sessionID: "CANARY_SESSION_\(index)_WITH_A_LONG_IDENTIFIER",
                workspace: "/CANARY/WORKSPACE/WITH/A/VERY/LONG/PATH/\(index)",
                state: index.isMultiple(of: 2) ? .working : .thinking,
                sequence: UInt64(index + 1)
            )
        }
        let viewModel = await PreviewViewModel.monitoring(state: .thinking, sessions: sessions)

        let hosting = host(MenuBarContentView(viewModel: viewModel))

        assertFiniteLayout(hosting)
        XCTAssertEqual(hosting.frame.width, 380, accuracy: 1)
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }

    func testOnboardingViewRendersAtCompactSizeAndUsesSecureSecretEntry() {
        let viewModel = PreviewViewModel.onboarding()

        let hosting = host(OnboardingView(viewModel: viewModel))

        assertFiniteLayout(hosting)
        XCTAssertEqual(hosting.frame.width, 380, accuracy: 1)
        XCTAssertTrue(descendants(of: hosting).contains { $0 is NSSecureTextField })
    }

    func testIntegrationReviewRendersEverySourcePathAndConflictSummary() async {
        let viewModel = await PreviewViewModel.integrationReview()

        let hosting = host(MenuBarContentView(viewModel: viewModel))

        assertFiniteLayout(hosting)
        XCTAssertEqual(
            Set(viewModel.integrationPreviews.map(\.path)),
            Set(["/CANARY/codex.json", "/CANARY/claudeCode.json", "/CANARY/cursor.json"])
        )
        XCTAssertTrue(viewModel.integrationPreviews.allSatisfy { !$0.before.isEmpty && !$0.after.isEmpty })
    }

    func testPausedAndRepairViewsRenderAtCompactSize() async {
        let paused = await PreviewViewModel.paused()
        let repair = await PreviewViewModel.repairRequired()

        for viewModel in [paused, repair] {
            let hosting = host(MenuBarContentView(viewModel: viewModel))
            assertFiniteLayout(hosting)
            XCTAssertEqual(hosting.frame.width, 380, accuracy: 1)
        }
    }

    func testSettingsContainsOnlyApprovedSections() async {
        let viewModel = await PreviewViewModel.monitoring(state: .idle)

        let hosting = host(SettingsView(viewModel: viewModel))

        assertFiniteLayout(hosting)
        XCTAssertEqual(SettingsView.sectionTitles, ["Light", "Integrations", "General"])
        let visibleText = descendants(of: hosting)
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .joined(separator: " ")
        XCTAssertFalse(visibleText.localizedCaseInsensitiveContains("custom color"))
        XCTAssertFalse(visibleText.localizedCaseInsensitiveContains("timing"))
    }

    func testVerifyingAndApprovingProgressRender() async {
        let verifyingHarness = ViewModelHarness()
        await verifyingHarness.verifier.block(call: 1)
        let connect = Task {
            await verifyingHarness.viewModel.connect(using: verifyingHarness.validDraft)
        }
        await verifyingHarness.verifier.waitForVerifyCount(1)
        XCTAssertEqual(verifyingHarness.viewModel.phase, .verifying)
        assertFiniteLayout(host(MenuBarContentView(viewModel: verifyingHarness.viewModel)))
        await verifyingHarness.verifier.release(call: 1)
        await connect.value

        await verifyingHarness.integrations.blockInstall()
        let approval = Task { await verifyingHarness.viewModel.approveIntegrations() }
        await verifyingHarness.integrations.waitForInstallCount(1)
        XCTAssertEqual(verifyingHarness.viewModel.phase, .approving)
        assertFiniteLayout(host(MenuBarContentView(viewModel: verifyingHarness.viewModel)))
        await verifyingHarness.integrations.releaseInstall()
        await approval.value
    }

    func testHighContrastReduceMotionAndAccessibilityTypeRender() async {
        let view = AmbientBulbView(
            state: .needsYou,
            reduceMotionOverride: true,
            highContrastOverride: true
        )
        .dynamicTypeSize(.accessibility5)
        .frame(width: 380)

        let hosting = host(view)

        assertFiniteLayout(hosting)
        XCTAssertEqual(hosting.frame.width, 380, accuracy: 1)
    }

    func testApprovePauseAndQuitControlsInvokeActionsOnce() async throws {
        let approvalHarness = ViewModelHarness()
        await approvalHarness.viewModel.connect(using: approvalHarness.validDraft)
        let approvalHost = host(MenuBarContentView(viewModel: approvalHarness.viewModel))
        approvalHost.rootView.perform(.approve)
        await approvalHarness.integrations.waitForInstallCount(1)
        let approvalCounts = await approvalHarness.integrations.counts()
        XCTAssertEqual(approvalCounts.install, 1)

        let pauseHarness = ViewModelHarness()
        await pauseHarness.connectAndApprove()
        let pauseHost = host(MenuBarContentView(viewModel: pauseHarness.viewModel))
        pauseHost.rootView.perform(.pause)
        await pauseHarness.monitor.waitForPauseCount(1)
        let pauseMetrics = await pauseHarness.monitor.metrics()
        XCTAssertEqual(pauseMetrics.pause, 1)

        var quitCount = 0
        let quitHost = host(MenuBarContentView(viewModel: pauseHarness.viewModel) {
            quitCount += 1
        })
        quitHost.rootView.perform(.quit)
        XCTAssertEqual(quitCount, 1)
    }

    func testEveryAppButtonHasStableAccessibilityIdentifier() async {
        let onboarding = host(OnboardingView(viewModel: PreviewViewModel.onboarding()))
        let review = host(MenuBarContentView(viewModel: await PreviewViewModel.integrationReview()))
        let monitoring = host(MenuBarContentView(viewModel: await PreviewViewModel.monitoring(state: .working)))
        let settings = host(SettingsView(viewModel: await PreviewViewModel.monitoring(state: .idle)))
        assertFiniteLayout(onboarding)
        assertFiniteLayout(review)
        assertFiniteLayout(monitoring)
        assertFiniteLayout(settings)
        let identifiers = AmbientAccessibilityID.interactive
        XCTAssertTrue(identifiers.contains("onboarding.verifyConnect"))
        XCTAssertTrue(identifiers.contains("integrationReview.approve"))
        XCTAssertTrue(identifiers.contains("monitor.pause"))
        XCTAssertTrue(identifiers.contains("monitor.settings"))
        XCTAssertTrue(identifiers.contains("monitor.quit"))
        XCTAssertTrue(identifiers.contains("settings.light.disconnect"))
        XCTAssertTrue(identifiers.contains("settings.integrations.repair"))
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    private func host<Content: View>(_ content: Content) -> NSHostingView<Content> {
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 540)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        windows.append(window)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private func assertFiniteLayout<Content: View>(_ hosting: NSHostingView<Content>) {
        XCTAssertTrue(hosting.fittingSize.width.isFinite)
        XCTAssertTrue(hosting.fittingSize.height.isFinite)
        XCTAssertGreaterThan(hosting.frame.width, 0)
        XCTAssertGreaterThan(hosting.frame.height, 0)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

}
