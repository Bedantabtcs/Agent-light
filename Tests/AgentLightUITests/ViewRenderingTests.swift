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

    func testSettingsRendersHonestCodexTrustFlowAndUserConfirmation() async throws {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        let hosting = host(SettingsView(viewModel: harness.viewModel))
        await nextMainTurn()

        var rendered = renderedText(in: hosting)
        XCTAssertTrue(rendered.contains("Trust required"), "\(rendered)")
        XCTAssertTrue(rendered.contains { $0.contains("/hooks") }, "\(rendered)")
        XCTAssertTrue(rendered.contains { $0.contains(AppIdentity.integrationIdentifier) }, "\(rendered)")

        try renderedButton("settings.integrations.confirmCodexTrust", in: hosting).performClick(nil)
        await nextMainTurn()
        hosting.layoutSubtreeIfNeeded()

        rendered = renderedText(in: hosting)
        XCTAssertTrue(rendered.contains("User confirmed"), "\(rendered)")
        let installCount = await harness.integrations.counts().install
        XCTAssertEqual(installCount, 1)
    }

    func testPendingLoginApprovalRendersExactGuidanceAndStatusOnlyRetryControl() async throws {
        let harness = ViewModelHarness()
        harness.loginItem.registerResult = .requiresApproval
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.viewModel.approveIntegrations()
        let hosting = host(SettingsView(viewModel: harness.viewModel))

        let rendered = renderedText(in: hosting)
        XCTAssertTrue(
            rendered.contains("Open System Settings > General > Login Items, then allow Agent Light."),
            "\(rendered)"
        )
        _ = try renderedButton("settings.general.retryLoginStatus", in: hosting)
    }

    func testRenderedLaunchAtLoginToggleDisablesPendingRegistrationAccessibly() async throws {
        let harness = ViewModelHarness()
        harness.loginItem.registerResult = .requiresApproval
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.viewModel.approveIntegrations()
        let hosting = host(SettingsView(viewModel: harness.viewModel))

        let loginSwitch = try XCTUnwrap(
            descendants(of: hosting)
                .compactMap { $0 as? NSSwitch }
                .first {
                    $0.accessibilityIdentifier() == AmbientAccessibilityID.settingsLaunchAtLogin
                }
        )
        XCTAssertEqual(loginSwitch.state, .on)
        XCTAssertEqual(loginSwitch.accessibilityLabel(), "Launch at login")
        XCTAssertEqual(loginSwitch.accessibilityRole(), .checkBox)
        loginSwitch.state = .off
        XCTAssertTrue(loginSwitch.sendAction(loginSwitch.action, to: loginSwitch.target))
        for _ in 0..<100 where harness.loginItem.disableCount == 0 {
            await nextMainTurn()
        }

        XCTAssertEqual(harness.loginItem.disableCount, 1)
        XCTAssertEqual(harness.viewModel.loginItemStatus, .notRegistered)
    }

    func testREADMEExplainsManualCodexTrustSequenceAndSkippedHooks() throws {
        let readmeURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "README.md")
        let readme = try String(contentsOf: readmeURL, encoding: .utf8)

        XCTAssertTrue(readme.contains("/hooks"))
        XCTAssertTrue(readme.contains("com.bbatchas.agentlight.hook.v1"))
        XCTAssertTrue(readme.localizedCaseInsensitiveContains("untrusted hooks are skipped"))
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

    func testRenderedMonitoringSwitchTracksActiveMonitorDuringRepair() async throws {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        await harness.integrations.setRepairError(TuyaClientError.transport)
        await harness.viewModel.repairIntegrations()
        let repairError = harness.viewModel.presentedError
        let hosting = host(SettingsView(viewModel: harness.viewModel))
        let monitoringSwitch = try XCTUnwrap(
            descendants(of: hosting)
                .compactMap { $0 as? NSSwitch }
                .first { $0.accessibilityIdentifier() == AmbientAccessibilityID.settingsMonitoring }
        )
        XCTAssertEqual(monitoringSwitch.state, .on)
        XCTAssertTrue(
            renderedText(in: hosting).contains("Monitoring is enabled"),
            "\(renderedText(in: hosting))"
        )

        monitoringSwitch.state = .off
        XCTAssertTrue(monitoringSwitch.sendAction(monitoringSwitch.action, to: monitoringSwitch.target))
        await harness.monitor.waitForPauseCount(1)
        for _ in 0..<100 where harness.viewModel.monitoringActive {
            await nextMainTurn()
        }
        await nextMainTurn()
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            renderedText(in: hosting).contains("Monitoring is disabled"),
            "\(renderedText(in: hosting))"
        )
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.presentedError, repairError)

        monitoringSwitch.state = .on
        XCTAssertTrue(monitoringSwitch.sendAction(monitoringSwitch.action, to: monitoringSwitch.target))
        await harness.monitor.waitForResumeCount(1)
        for _ in 0..<100 where !harness.viewModel.monitoringActive {
            await nextMainTurn()
        }
        await nextMainTurn()
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            renderedText(in: hosting).contains("Monitoring is enabled"),
            "\(renderedText(in: hosting))"
        )
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.presentedError, repairError)
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
        for _ in 0..<100 where replaceHarness.viewModel.phase != .onboarding {
            await nextMainTurn()
        }
        XCTAssertEqual(replaceHarness.viewModel.phase, .onboarding)

        let uninstallHarness = ViewModelHarness()
        await uninstallHarness.connectAndApprove()
        let uninstallHost = host(SettingsView(viewModel: uninstallHarness.viewModel))
        try renderedButton(AmbientAccessibilityID.settingsUninstall, in: uninstallHost).performClick(nil)
        await uninstallHarness.integrations.waitForUninstallCount(1)
        let uninstallCount = await uninstallHarness.integrations.counts().uninstall
        XCTAssertEqual(uninstallCount, 1)
        for _ in 0..<100 where uninstallHarness.viewModel.integrationStatus != .notInstalled {
            await nextMainTurn()
        }
        await nextMainTurn()
        uninstallHost.layoutSubtreeIfNeeded()
        let uninstallText = descendants(of: uninstallHost)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(uninstallText.contains("Not Installed"), "\(uninstallText)")

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

    func testRenderedOwnershipReceiptResetIsExplicitSanitizedAndReturnsToOnboarding() async throws {
        let store = ResettableCorruptSetupOwnershipStore()
        let harness = ViewModelHarness(ownershipStore: store)
        await harness.viewModel.synchronizeOwnership()
        let hosting = host(SettingsView(viewModel: harness.viewModel))

        let rendered = renderedText(in: hosting)
        XCTAssertTrue(rendered.contains("The saved ownership receipt cannot be used safely."), "\(rendered)")
        XCTAssertFalse(rendered.contains { $0.contains("setup-ownership-v1") }, "\(rendered)")
        try renderedButton(AmbientAccessibilityID.settingsResetOwnershipReceipt, in: hosting).performClick(nil)

        for _ in 0..<100 where await store.resetCount == 0 {
            await nextMainTurn()
        }
        let resetCount = await store.resetCount
        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(harness.viewModel.phase, .onboarding)
        XCTAssertTrue(harness.viewModel.outstandingObligations.isEmpty)
    }

    func testRenderedGenericOwnershipFailureShowsManualGuidanceWithoutResetControl() async {
        let store = ControllableSetupOwnershipStore()
        await store.failLoads(with: .unsafeReceipt)
        let harness = ViewModelHarness(ownershipStore: store)
        await harness.viewModel.synchronizeOwnership()
        let hosting = host(SettingsView(viewModel: harness.viewModel))

        let rendered = renderedText(in: hosting)
        XCTAssertTrue(
            rendered.contains("Ownership state could not be read or saved. Retry, then inspect Application Support permissions if the problem continues."),
            "\(rendered)"
        )
        XCTAssertFalse(rendered.contains { $0.contains("setup-ownership-v1") }, "\(rendered)")
        let reset = descendants(of: hosting)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == AmbientAccessibilityID.settingsResetOwnershipReceipt }
        XCTAssertNil(reset)
    }

    func testRenderedLoginOptOutCompensationReturnsSwitchOnThenOffRetrySucceeds() async throws {
        let store = ControllableSetupOwnershipStore()
        let harness = ViewModelHarness(ownershipStore: store)
        await harness.connectAndApprove()
        let hosting = host(SettingsView(viewModel: harness.viewModel))
        let nextWrite = await store.writes() + 1
        await store.failSaves([nextWrite])
        let loginSwitch = try XCTUnwrap(
            descendants(of: hosting)
                .compactMap { $0 as? NSSwitch }
                .first {
                    $0.accessibilityIdentifier() == AmbientAccessibilityID.settingsLaunchAtLogin
                }
        )

        loginSwitch.state = .off
        XCTAssertTrue(loginSwitch.sendAction(loginSwitch.action, to: loginSwitch.target))
        for _ in 0..<100 where harness.loginItem.enableCount < 2 {
            await nextMainTurn()
        }
        await nextMainTurn()
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(loginSwitch.state, .on)
        XCTAssertEqual(harness.viewModel.phase, .monitoring)
        XCTAssertEqual(harness.viewModel.presentedError, .operationFailed)
        XCTAssertNil(descendants(of: hosting).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == AmbientAccessibilityID.settingsRetryDisabledLoginState
        })

        loginSwitch.state = .off
        XCTAssertTrue(loginSwitch.sendAction(loginSwitch.action, to: loginSwitch.target))
        for _ in 0..<100 where harness.loginItem.disableCount < 2 {
            await nextMainTurn()
        }
        await nextMainTurn()
        hosting.layoutSubtreeIfNeeded()

        let receipt = await store.current()
        let rendered = renderedText(in: hosting)
        XCTAssertEqual(loginSwitch.state, .off)
        XCTAssertTrue(rendered.contains("Not enabled"), "\(rendered)")
        XCTAssertTrue(rendered.contains("Monitoring is enabled"), "\(rendered)")
        XCTAssertEqual(receipt?.login, PersistentLoginOwnership.none)
        XCTAssertEqual(harness.loginItem.disableCount, 2)
        XCTAssertEqual(harness.loginItem.enableCount, 2)
    }

    func testRenderedCompensationFailureExposesExplicitReceiptRetryWithoutUnregisteringAgain() async throws {
        let store = ControllableSetupOwnershipStore()
        let harness = ViewModelHarness(ownershipStore: store)
        await harness.connectAndApprove()
        harness.loginItem.enableError = HarnessSensitiveError("CANARY_COMPENSATION")
        let nextWrite = await store.writes() + 1
        await store.failSaves([nextWrite])
        let hosting = host(SettingsView(viewModel: harness.viewModel))
        let loginSwitch = try XCTUnwrap(
            descendants(of: hosting).compactMap { $0 as? NSSwitch }.first {
                $0.accessibilityIdentifier() == AmbientAccessibilityID.settingsLaunchAtLogin
            }
        )

        loginSwitch.state = .off
        XCTAssertTrue(loginSwitch.sendAction(loginSwitch.action, to: loginSwitch.target))
        for _ in 0..<100 where !harness.viewModel.loginDisabledStatePersistenceRetryRequired {
            await nextMainTurn()
        }
        hosting.layoutSubtreeIfNeeded()

        let retry = try renderedButton(
            AmbientAccessibilityID.settingsRetryDisabledLoginState,
            in: hosting
        )
        XCTAssertEqual(retry.accessibilityLabel(), "Retry saving disabled login state")
        retry.performClick(nil)
        for _ in 0..<100 where harness.viewModel.loginDisabledStatePersistenceRetryRequired {
            await nextMainTurn()
        }
        hosting.layoutSubtreeIfNeeded()

        let receipt = await store.current()
        XCTAssertEqual(receipt?.login, PersistentLoginOwnership.none)
        XCTAssertEqual(harness.viewModel.phase, .monitoring)
        XCTAssertNil(harness.viewModel.presentedError)
        XCTAssertEqual(harness.loginItem.disableCount, 1)
        XCTAssertEqual(harness.loginItem.enableCount, 2)
        XCTAssertNotNil(harness.credentials.storedCredentials())
        XCTAssertTrue(harness.viewModel.integrationInstalled)
    }

    func testRenderedRelaunchMismatchRetryPersistsNoneWithoutLoginMutation() async throws {
        let store = MemorySetupOwnershipStore()
        let harness = ViewModelHarness(ownershipStore: store)
        await harness.connectAndApprove()
        harness.loginItem.currentStatus = .notRegistered
        let relaunched = AppViewModel(
            credentials: harness.credentials,
            integrations: harness.integrations,
            monitor: harness.monitor,
            loginItem: harness.loginItem,
            verifier: harness.verifier,
            ownershipLedger: AppOwnershipLedger(store: store)
        )
        let loginCounts = (harness.loginItem.enableCount, harness.loginItem.disableCount)
        await relaunched.synchronizeOwnership()
        let hosting = host(SettingsView(viewModel: relaunched))

        try renderedButton(
            AmbientAccessibilityID.settingsRetryDisabledLoginState,
            in: hosting
        ).performClick(nil)
        for _ in 0..<100 where relaunched.loginDisabledStatePersistenceRetryRequired {
            await nextMainTurn()
        }

        let receipt = try await store.load()
        XCTAssertEqual(receipt?.login, PersistentLoginOwnership.none)
        XCTAssertEqual(relaunched.phase, .monitoring)
        XCTAssertEqual(harness.loginItem.enableCount, loginCounts.0)
        XCTAssertEqual(harness.loginItem.disableCount, loginCounts.1)
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
        let expected: [(String, String, NSAccessibility.Role)] = [
            (AmbientAccessibilityID.onboardingEndpoint, "Tuya data center", .popUpButton),
            (AmbientAccessibilityID.onboardingVerify, "Verify & Connect", .button),
            (AmbientAccessibilityID.integrationApprove, "Approve & Start Monitoring", .button),
            (AmbientAccessibilityID.monitorPause, "Pause Monitoring", .button),
            (AmbientAccessibilityID.monitorResume, "Resume Monitoring", .button),
            (AmbientAccessibilityID.monitorRepair, "Review Repair", .button),
            (AmbientAccessibilityID.monitorSettings, "Settings", .button),
            (AmbientAccessibilityID.monitorQuit, "Quit", .button),
            (AmbientAccessibilityID.settingsBack, "Back", .button),
            (AmbientAccessibilityID.settingsDisconnect, "Disconnect and restore light", .button),
            (AmbientAccessibilityID.settingsReconnect, "Reconnect Light", .button),
            (AmbientAccessibilityID.settingsReplaceDevice, "Replace Device", .button),
            (AmbientAccessibilityID.settingsRepair, "Preview Repair", .button),
            (AmbientAccessibilityID.settingsUninstall, "Uninstall Integrations", .button),
            (AmbientAccessibilityID.settingsLaunchAtLogin, "Launch at login", .checkBox),
            (AmbientAccessibilityID.settingsMonitoring, "Monitoring", .checkBox)
        ]
        for (identifier, label, role) in expected {
            XCTAssertTrue(identifiers.contains(identifier), "Missing rendered identifier \(identifier)")
            let control = roots.lazy
                .flatMap { self.descendants(of: $0) }
                .first { $0.accessibilityIdentifier() == identifier }
            XCTAssertEqual(control?.accessibilityLabel(), label, identifier)
            XCTAssertEqual(control?.accessibilityRole(), role, identifier)
            XCTAssertEqual(control?.isAccessibilityElement(), true, identifier)
        }
    }

    func testNativeControlsAndWrappingTextScaleForAccessibilityDynamicType() async throws {
        let session = AgentEvent(
            source: .codex,
            sessionID: "CANARY_DYNAMIC_SESSION",
            workspace: "/CANARY/DYNAMIC/WORKSPACE",
            state: .working,
            sequence: 1
        )
        let normalOnboarding = host(OnboardingView(viewModel: PreviewViewModel.onboarding()))
        let largeOnboarding = host(
            OnboardingView(viewModel: PreviewViewModel.onboarding())
                .dynamicTypeSize(.accessibility5)
        )
        let normalReview = host(MenuBarContentView(viewModel: await PreviewViewModel.integrationReview()))
        let largeReview = host(
            MenuBarContentView(viewModel: await PreviewViewModel.integrationReview())
                .dynamicTypeSize(.accessibility5)
        )
        let normalMonitor = host(MenuBarContentView(
            viewModel: await PreviewViewModel.monitoring(state: .working, sessions: [session])
        ))
        let largeMonitor = host(
            MenuBarContentView(
                viewModel: await PreviewViewModel.monitoring(state: .working, sessions: [session])
            )
            .dynamicTypeSize(.accessibility5)
        )
        let normalSettings = host(SettingsView(viewModel: await PreviewViewModel.monitoring(state: .idle)))
        let largeSettings = host(
            SettingsView(viewModel: await PreviewViewModel.monitoring(state: .idle))
                .dynamicTypeSize(.accessibility5)
        )

        let comparisons: [(NSView, NSView, String)] = [
            (normalOnboarding, largeOnboarding, AmbientAccessibilityID.onboardingEndpoint),
            (normalOnboarding, largeOnboarding, AmbientAccessibilityID.onboardingVerify),
            (normalReview, largeReview, "integrationReview.codex.path"),
            (normalReview, largeReview, "integrationReview.codex.before"),
            (normalMonitor, largeMonitor, "monitor.session.CANARY_DYNAMIC_SESSION.workspace"),
            (normalSettings, largeSettings, AmbientAccessibilityID.settingsMonitoring)
        ]
        for (normal, large, identifier) in comparisons {
            let normalSize = try renderedFontSize(identifier, in: normal)
            let largeSize = try renderedFontSize(identifier, in: large)
            XCTAssertGreaterThan(largeSize, normalSize, "\(identifier): \(normalSize) -> \(largeSize)")
        }
        assertFiniteLayout(largeOnboarding)
        assertFiniteLayout(largeReview)
        assertFiniteLayout(largeMonitor)
        assertFiniteLayout(largeSettings)
        XCTAssertTrue(descendants(of: largeReview).contains { view in
            guard let clip = view as? NSClipView, let document = clip.documentView else { return false }
            return document.frame.height > clip.bounds.height
        })
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

    private func renderedText(in view: NSView) -> [String] {
        descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func renderedButton(_ identifier: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == identifier },
            "Missing rendered button \(identifier)"
        )
    }

    private func renderedFontSize(_ identifier: String, in view: NSView) throws -> CGFloat {
        let rendered = try XCTUnwrap(
            descendants(of: view).first { $0.accessibilityIdentifier() == identifier },
            "Missing rendered view \(identifier)"
        )
        if let control = rendered as? NSControl {
            return try XCTUnwrap(control.font?.pointSize, "Missing control font for \(identifier)")
        }
        if let text = rendered as? NSTextField {
            return try XCTUnwrap(text.font?.pointSize, "Missing text font for \(identifier)")
        }
        XCTFail("Rendered view has no font: \(identifier)")
        return 0
    }

    private func nextMainTurn() async {
        let rendered = expectation(description: "next main turn")
        DispatchQueue.main.async { rendered.fulfill() }
        await fulfillment(of: [rendered])
    }

}
