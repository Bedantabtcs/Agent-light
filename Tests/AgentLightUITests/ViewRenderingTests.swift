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
        XCTAssertEqual(hosting.fittingSize.width, 380, accuracy: 1)
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        let clipViews = descendants(of: hosting).compactMap { $0 as? NSClipView }
        XCTAssertTrue(clipViews.contains { clip in
            guard let document = clip.documentView else { return false }
            return document.frame.height > clip.bounds.height
        }, "\(clipViews.map { ($0.bounds.height, $0.documentView?.frame.height ?? -1) })")
        XCTAssertTrue(
            descendants(of: hosting)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("/CANARY/WORKSPACE/WITH/A/VERY/LONG/PATH/13")
        )
    }

    func testOnboardingViewRendersAtCompactSizeAndUsesSecureSecretEntry() {
        let viewModel = PreviewViewModel.onboarding()

        let hosting = host(OnboardingView(viewModel: viewModel))

        assertFiniteLayout(hosting)
        XCTAssertEqual(hosting.frame.width, 380, accuracy: 1)
        XCTAssertTrue(descendants(of: hosting).contains { $0 is NSSecureTextField })
    }

    func testOnboardingUsesAllowlistedDataCenterPickerInsteadOfEndpointTextEntry() {
        let hosting = host(OnboardingView(viewModel: PreviewViewModel.onboarding()))

        let controls = descendants(of: hosting)
        XCTAssertTrue(controls.contains { $0 is NSPopUpButton })
        XCTAssertFalse(
            controls.compactMap { $0 as? NSTextField }
                .contains { $0.accessibilityIdentifier() == "onboarding.endpoint" }
        )
    }

    func testKeyboardDefaultsAndSettingsEscapeUseRenderedNativeControls() async throws {
        let onboarding = host(OnboardingView(viewModel: PreviewViewModel.onboarding()))
        await nextMainTurn()
        let verify = try renderedButton(AmbientAccessibilityID.onboardingVerify, in: onboarding)
        XCTAssertEqual(verify.keyEquivalent, "\r")
        XCTAssertTrue(onboarding.window?.firstResponder is NSPopUpButton)

        var dismissCount = 0
        let settings = host(SettingsView(
            viewModel: await PreviewViewModel.monitoring(state: .idle),
            dismiss: { dismissCount += 1 }
        ))
        let back = try renderedButton(AmbientAccessibilityID.settingsBack, in: settings)
        XCTAssertEqual(back.keyEquivalent, "\u{1b}")
        back.performClick(nil)
        XCTAssertEqual(dismissCount, 1)
    }

    func testIntegrationReviewRendersEverySourcePathAndConflictSummary() async {
        let viewModel = await PreviewViewModel.integrationReview()

        let hosting = host(MenuBarContentView(viewModel: viewModel))

        assertFiniteLayout(hosting)
        let renderedText = Set(
            descendants(of: hosting)
                .compactMap { ($0 as? NSTextField)?.stringValue }
        )
        for source in AgentSource.allCases {
            XCTAssertTrue(renderedText.contains("/CANARY/\(source.rawValue).json"))
            XCTAssertTrue(renderedText.contains("{\"CANARY_EXISTING\":\"\(source.rawValue)\"}"))
            XCTAssertTrue(renderedText.contains("{\"CANARY_AGENT_LIGHT\":\"\(source.rawValue)\"}"))
        }
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
        let viewModel = await PreviewViewModel.monitoring(state: .needsYou)
        let view = MenuBarContentView(viewModel: viewModel)
            .ambientAccessibilityOverrides(reduceMotion: true, highContrast: true)
            .dynamicTypeSize(.accessibility5)

        let hosting = host(view)

        assertFiniteLayout(hosting)
        XCTAssertEqual(hosting.fittingSize.width, 380, accuracy: 1)
    }

    func testApprovePauseAndQuitControlsInvokeActionsOnce() async throws {
        let approvalHarness = ViewModelHarness()
        await approvalHarness.viewModel.connect(using: approvalHarness.validDraft)
        let approvalHost = host(MenuBarContentView(viewModel: approvalHarness.viewModel))
        try renderedButton(AmbientAccessibilityID.integrationApprove, in: approvalHost).performClick(nil)
        await approvalHarness.integrations.waitForInstallCount(1)
        let approvalCounts = await approvalHarness.integrations.counts()
        XCTAssertEqual(approvalCounts.install, 1)

        let pauseHarness = ViewModelHarness()
        await pauseHarness.connectAndApprove()
        let pauseHost = host(MenuBarContentView(viewModel: pauseHarness.viewModel))
        try renderedButton(AmbientAccessibilityID.monitorPause, in: pauseHost).performClick(nil)
        await pauseHarness.monitor.waitForPauseCount(1)
        let pauseMetrics = await pauseHarness.monitor.metrics()
        XCTAssertEqual(pauseMetrics.pause, 1)

        var quitCount = 0
        let quitHost = host(MenuBarContentView(viewModel: pauseHarness.viewModel) {
            quitCount += 1
        })
        try renderedButton(AmbientAccessibilityID.monitorQuit, in: quitHost).performClick(nil)
        XCTAssertEqual(quitCount, 1)
    }

    func testRenderedMonitoringToggleInvokesPauseOnce() async throws {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        let hosting = host(SettingsView(viewModel: harness.viewModel))

        let monitoringSwitch = try XCTUnwrap(
            descendants(of: hosting)
                .compactMap { $0 as? NSSwitch }
                .first { $0.accessibilityIdentifier() == AmbientAccessibilityID.settingsMonitoring }
        )
        monitoringSwitch.state = .off
        XCTAssertTrue(monitoringSwitch.sendAction(monitoringSwitch.action, to: monitoringSwitch.target))
        await harness.monitor.waitForPauseCount(1)
        let pauseCount = await harness.monitor.metrics().pause

        XCTAssertEqual(pauseCount, 1)
    }

    func testRenderedSettingsActionsInvokeOnceAndRepairRequiresPreviewConfirmation() async throws {
        let reconnectHarness = ViewModelHarness()
        await reconnectHarness.connectAndApprove()
        let reconnectHost = host(SettingsView(viewModel: reconnectHarness.viewModel))
        try renderedButton(AmbientAccessibilityID.settingsReconnect, in: reconnectHost).performClick(nil)
        await reconnectHarness.monitor.waitForReconnectCount(1)
        let reconnectCount = await reconnectHarness.monitor.metrics().reconnect
        XCTAssertEqual(reconnectCount, 1)

        let replaceHarness = ViewModelHarness()
        await replaceHarness.connectAndApprove()
        let replaceHost = host(SettingsView(viewModel: replaceHarness.viewModel))
        try renderedButton(AmbientAccessibilityID.settingsReplaceDevice, in: replaceHost).performClick(nil)
        await replaceHarness.monitor.waitForStopCount(1)
        await replaceHarness.integrations.waitForUninstallCount(1)
        await nextMainTurn()
        XCTAssertEqual(replaceHarness.viewModel.phase, .onboarding)

        let uninstallHarness = ViewModelHarness()
        await uninstallHarness.connectAndApprove()
        let uninstallHost = host(SettingsView(viewModel: uninstallHarness.viewModel))
        try renderedButton(AmbientAccessibilityID.settingsUninstall, in: uninstallHost).performClick(nil)
        await uninstallHarness.integrations.waitForUninstallCount(1)
        let uninstallCount = await uninstallHarness.integrations.counts().uninstall
        XCTAssertEqual(uninstallCount, 1)

        let repairHarness = ViewModelHarness()
        await repairHarness.connectAndApprove()
        let repairHost = host(SettingsView(viewModel: repairHarness.viewModel))
        XCTAssertNil(
            descendants(of: repairHost)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == AmbientAccessibilityID.settingsConfirmRepair }
        )
        try renderedButton(AmbientAccessibilityID.settingsRepair, in: repairHost).performClick(nil)
        await repairHarness.integrations.waitForPreviewCount(2)
        await nextMainTurn()
        repairHost.layoutSubtreeIfNeeded()
        let paths = descendants(of: repairHost).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(paths.contains("/CANARY/codex.json"))
        try renderedButton(AmbientAccessibilityID.settingsConfirmRepair, in: repairHost).performClick(nil)
        await repairHarness.integrations.waitForRepairCount(1)
        let repairCount = await repairHarness.integrations.counts().repair
        XCTAssertEqual(repairCount, 1)
    }

    func testRenderedPrimaryControlsHaveStableAccessibilityIdentifiers() async {
        let onboarding = host(OnboardingView(viewModel: PreviewViewModel.onboarding()))
        let review = host(MenuBarContentView(viewModel: await PreviewViewModel.integrationReview()))
        let monitoring = host(MenuBarContentView(viewModel: await PreviewViewModel.monitoring(state: .working)))
        let paused = host(MenuBarContentView(viewModel: await PreviewViewModel.paused()))
        let repair = host(MenuBarContentView(viewModel: await PreviewViewModel.repairRequired()))
        let settings = host(SettingsView(
            viewModel: await PreviewViewModel.monitoring(state: .idle),
            dismiss: {}
        ))
        assertFiniteLayout(onboarding)
        assertFiniteLayout(review)
        assertFiniteLayout(monitoring)
        assertFiniteLayout(paused)
        assertFiniteLayout(repair)
        assertFiniteLayout(settings)
        let roots: [NSView] = [onboarding, review, monitoring, paused, repair, settings]
        let identifiers = Set(roots.flatMap { root in
            descendants(of: root)
                .map { $0.accessibilityIdentifier() }
                .filter { !$0.isEmpty }
        })
        let expected = [
            AmbientAccessibilityID.onboardingEndpoint,
            AmbientAccessibilityID.onboardingVerify,
            AmbientAccessibilityID.integrationApprove,
            AmbientAccessibilityID.monitorPause,
            AmbientAccessibilityID.monitorResume,
            AmbientAccessibilityID.monitorRepair,
            AmbientAccessibilityID.monitorSettings,
            AmbientAccessibilityID.monitorQuit,
            AmbientAccessibilityID.settingsBack,
            AmbientAccessibilityID.settingsDisconnect,
            AmbientAccessibilityID.settingsReconnect,
            AmbientAccessibilityID.settingsReplaceDevice,
            AmbientAccessibilityID.settingsRepair,
            AmbientAccessibilityID.settingsUninstall,
            AmbientAccessibilityID.settingsMonitoring
        ]
        for identifier in expected {
            XCTAssertTrue(identifiers.contains(identifier), "Missing rendered identifier \(identifier)")
        }
    }

    func testRenderedSettingsAccessibilityContainsInteractiveControls() async {
        let hosting = host(SettingsView(viewModel: await PreviewViewModel.monitoring(state: .working)))
        let identifiers = descendants(of: hosting)
            .map { $0.accessibilityIdentifier() }
            .filter { !$0.isEmpty }

        XCTAssertTrue(identifiers.contains(AmbientAccessibilityID.settingsReconnect), "\(identifiers)")
        XCTAssertTrue(identifiers.contains(AmbientAccessibilityID.settingsReplaceDevice), "\(identifiers)")
        XCTAssertTrue(identifiers.contains(AmbientAccessibilityID.settingsRepair), "\(identifiers)")
        XCTAssertTrue(identifiers.contains(AmbientAccessibilityID.settingsUninstall), "\(identifiers)")
        XCTAssertTrue(identifiers.contains(AmbientAccessibilityID.settingsMonitoring), "\(identifiers)")
    }

    private func host<Content: View>(_ content: Content) -> NSHostingView<Content> {
        NSApplication.shared.setActivationPolicy(.regular)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 540)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        windows.append(window)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private func assertFiniteLayout<Content: View>(_ hosting: NSHostingView<Content>) {
        XCTAssertTrue(hosting.fittingSize.width.isFinite)
        XCTAssertTrue(hosting.fittingSize.height.isFinite)
        XCTAssertEqual(hosting.fittingSize.width, 380, accuracy: 1)
        XCTAssertGreaterThan(hosting.frame.width, 0)
        XCTAssertGreaterThan(hosting.frame.height, 0)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func renderedButton(_ identifier: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == identifier },
            "Missing rendered button \(identifier)"
        )
    }

    private func nextMainTurn() async {
        let rendered = expectation(description: "next main turn")
        DispatchQueue.main.async { rendered.fulfill() }
        await fulfillment(of: [rendered])
    }

}
