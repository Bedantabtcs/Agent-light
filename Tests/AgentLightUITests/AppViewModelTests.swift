import XCTest
import AgentLightCore
@testable import AgentLightUI

@MainActor
final class AppViewModelTests: XCTestCase {
    func testConnectTrimsEveryFieldBeforeVerificationAndDoesNotSaveCredentials() async throws {
        let harness = ViewModelHarness()
        let draft = ConnectionDraft(
            endpoint: "  https://openapi.tuyaus.com/  ",
            accessID: "  CANARY_ACCESS_ID  ",
            accessSecret: "  CANARY_ACCESS_SECRET  ",
            deviceID: "  CANARY_DEVICE_ID  "
        )

        await harness.viewModel.connect(using: draft)

        XCTAssertEqual(harness.viewModel.phase, .integrationReview)
        XCTAssertEqual(harness.credentials.saveCount, 0)
        let captured = await harness.verifier.capturedCredentials()
        let verified = try XCTUnwrap(captured)
        XCTAssertEqual(verified.endpoint.absoluteString, "https://openapi.tuyaus.com/")
        XCTAssertEqual(verified.accessID, "CANARY_ACCESS_ID")
        XCTAssertEqual(verified.accessSecret, "CANARY_ACCESS_SECRET")
        XCTAssertEqual(verified.deviceID, "CANARY_DEVICE_ID")
        let integrationCounts = await harness.integrations.counts()
        XCTAssertEqual(integrationCounts.preview, 1)
    }

    func testConnectRejectsInvalidFieldsBeforeCallingDependencies() async {
        let invalidDrafts = [
            ConnectionDraft(endpoint: "http://openapi.tuyaus.com", accessID: "a", accessSecret: "s", deviceID: "d"),
            ConnectionDraft(endpoint: "https://user@openapi.tuyaus.com", accessID: "a", accessSecret: "s", deviceID: "d"),
            ConnectionDraft(endpoint: "https://openapi.tuyaus.com/path", accessID: "a", accessSecret: "s", deviceID: "d"),
            ConnectionDraft(endpoint: "https://openapi.tuyaus.com", accessID: " ", accessSecret: "s", deviceID: "d"),
            ConnectionDraft(endpoint: "https://openapi.tuyaus.com", accessID: "a", accessSecret: " ", deviceID: "d"),
            ConnectionDraft(endpoint: "https://openapi.tuyaus.com", accessID: "a", accessSecret: "s", deviceID: " ")
        ]

        for draft in invalidDrafts {
            let harness = ViewModelHarness()
            await harness.viewModel.connect(using: draft)
            XCTAssertEqual(harness.viewModel.phase, .onboarding)
            XCTAssertEqual(
                harness.viewModel.presentedError,
                draft.endpoint.hasPrefix("https://") && !draft.endpoint.contains("@") && !draft.endpoint.contains("/path")
                    ? .invalidCredential
                    : .invalidEndpoint
            )
            let verifyCount = await harness.verifier.count()
            let previewCount = await harness.integrations.counts().preview
            XCTAssertEqual(verifyCount, 0)
            XCTAssertEqual(previewCount, 0)
        }
    }

    func testApprovedIntegrationsPersistEnableLoginAndStartObservationInOrder() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)

        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.phase, .monitoring)
        XCTAssertEqual(harness.viewModel.connectionStatus, .connected)
        XCTAssertEqual(harness.credentials.saveCount, 1)
        XCTAssertTrue(harness.loginItem.enabled)
        let metrics = await harness.monitor.metrics()
        XCTAssertEqual(metrics.start, 1)
        XCTAssertEqual(metrics.subscriptions, 1)
        XCTAssertEqual(
            harness.calls.values,
            [.verify, .preview, .install, .loadCredentials, .saveCredentials, .enableLogin,
             .startMonitoring, .currentSnapshot, .updates]
        )
    }

    func testApprovalFailureBoundariesCompensateOnlyCompletedStepsInReverseOrder() async {
        struct Scenario {
            let point: HarnessFailurePoint
            let expectedTail: [HarnessCall]
        }
        let scenarios = [
            Scenario(point: .install, expectedTail: [.install]),
            Scenario(point: .saveCredentials, expectedTail: [.install, .loadCredentials, .saveCredentials, .uninstall]),
            Scenario(
                point: .enableLogin,
                expectedTail: [.install, .loadCredentials, .saveCredentials, .enableLogin, .deleteCredentials, .uninstall]
            ),
            Scenario(
                point: .startMonitoring,
                expectedTail: [.install, .loadCredentials, .saveCredentials, .enableLogin, .startMonitoring,
                               .disableLogin, .deleteCredentials, .uninstall]
            )
        ]

        for scenario in scenarios {
            let harness = ViewModelHarness()
            await harness.viewModel.connect(using: harness.validDraft)
            harness.calls.removeAll()
            await harness.configureFailure(scenario.point, error: HarnessSensitiveError("CANARY_SECRET_FAILURE"))

            await harness.viewModel.approveIntegrations()

            XCTAssertEqual(harness.viewModel.phase, .integrationReview, "failure point: \(scenario.point)")
            XCTAssertEqual(harness.viewModel.presentedError, .operationFailed)
            XCTAssertEqual(harness.calls.values, scenario.expectedTail)
            let subscriptions = await harness.monitor.metrics().subscriptions
            XCTAssertEqual(subscriptions, 0)
        }
    }

    func testLoginApprovalPendingRollsBackWithoutDisablingLoginItDidNotEnable() async {
        let harness = ViewModelHarness()
        harness.loginItem.approvalRequired = true
        await harness.viewModel.connect(using: harness.validDraft)
        harness.calls.removeAll()

        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.phase, .integrationReview)
        XCTAssertEqual(harness.viewModel.presentedError, .loginApprovalRequired)
        XCTAssertEqual(
            harness.calls.values,
            [.install, .loadCredentials, .saveCredentials, .enableLogin, .deleteCredentials, .uninstall]
        )
        XCTAssertEqual(harness.loginItem.disableCount, 0)
        let startCount = await harness.monitor.metrics().start
        XCTAssertEqual(startCount, 0)
    }

    func testCompensationFailurePreservesOriginalErrorAndRepairState() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.monitor.setStartError(TuyaClientError.httpStatus(429))
        await harness.integrations.setUninstallError(HarnessSensitiveError("CANARY_ROLLBACK_SECRET"))

        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.presentedError, .rateLimited)
        XCTAssertTrue(harness.viewModel.requiresRepair)
        XCTAssertFalse(String(describing: harness.viewModel.presentedError).contains("CANARY"))
    }

    func testSecondConnectSupersedesCancellationIgnoringFirstVerification() async {
        let harness = ViewModelHarness()
        await harness.verifier.block(call: 1)
        let first = Task { await harness.viewModel.connect(using: harness.validDraft) }
        await harness.verifier.waitForVerifyCount(1)

        var secondDraft = harness.validDraft
        secondDraft.deviceID = "CANARY_SECOND_DEVICE"
        await harness.viewModel.connect(using: secondDraft)
        await harness.verifier.release(call: 1)
        await first.value

        XCTAssertEqual(harness.viewModel.phase, .integrationReview)
        let captured = await harness.verifier.capturedCredentials()
        let previewCount = await harness.integrations.counts().preview
        XCTAssertEqual(captured?.deviceID, "CANARY_SECOND_DEVICE")
        XCTAssertEqual(previewCount, 1)
    }

    func testSecondConnectSupersedesCancellationIgnoringFirstPreview() async {
        let harness = ViewModelHarness()
        await harness.integrations.blockPreview()
        let first = Task { await harness.viewModel.connect(using: harness.validDraft) }
        await harness.integrations.waitForPreviewCount(1)

        var secondDraft = harness.validDraft
        secondDraft.deviceID = "CANARY_SECOND_DEVICE"
        let second = Task { await harness.viewModel.connect(using: secondDraft) }
        await harness.integrations.releasePreview()
        await first.value
        await second.value

        XCTAssertEqual(harness.viewModel.phase, .integrationReview)
        let captured = await harness.verifier.capturedCredentials()
        XCTAssertEqual(captured?.deviceID, "CANARY_SECOND_DEVICE")
    }

    func testDisconnectDuringVerificationPreventsStaleCompletionMutation() async {
        let harness = ViewModelHarness()
        await harness.verifier.block(call: 1)
        let connect = Task { await harness.viewModel.connect(using: harness.validDraft) }
        await harness.verifier.waitForVerifyCount(1)

        await harness.viewModel.disconnect()
        await harness.verifier.release(call: 1)
        await connect.value

        XCTAssertEqual(harness.viewModel.phase, .onboarding)
        XCTAssertEqual(harness.viewModel.connectionStatus, .disconnected)
        let previewCount = await harness.integrations.counts().preview
        XCTAssertEqual(previewCount, 0)
        XCTAssertNil(harness.viewModel.presentedError)
    }

    func testDoubleApprovalDoesNotRepeatSideEffects() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.blockInstall()
        let first = Task { await harness.viewModel.approveIntegrations() }
        await harness.integrations.waitForInstallCount(1)
        let second = Task { await harness.viewModel.approveIntegrations() }
        await Task.yield()
        await harness.integrations.releaseInstall()
        await first.value
        await second.value

        let installCount = await harness.integrations.counts().install
        let startCount = await harness.monitor.metrics().start
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(harness.credentials.saveCount, 1)
        XCTAssertEqual(startCount, 1)
    }

    func testDisconnectDuringCancellationIgnoringInstallWaitsThenCompensates() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.blockInstall()
        let approval = Task { await harness.viewModel.approveIntegrations() }
        await harness.integrations.waitForInstallCount(1)

        let disconnect = Task { await harness.viewModel.disconnect() }
        await Task.yield()
        await harness.integrations.releaseInstall()
        await approval.value
        await disconnect.value

        let counts = await harness.integrations.counts()
        XCTAssertEqual(harness.viewModel.phase, .onboarding)
        XCTAssertEqual(counts.uninstall, 1)
        XCTAssertEqual(harness.credentials.saveCount, 0)
    }

    func testCredentialLoadFailureCompensatesInstalledHooks() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        harness.credentials.setLoadError(HarnessSensitiveError("CANARY_LOAD_SECRET"))
        harness.calls.removeAll()

        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.phase, .integrationReview)
        XCTAssertEqual(harness.viewModel.presentedError, .operationFailed)
        XCTAssertEqual(harness.calls.values, [.install, .loadCredentials, .uninstall])
    }

    func testCommittedInstallFailureUninstallsCommittedOwnedHooks() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.setInstallError(
            IntegrationError.committedWithCleanupFailure(["CANARY_PRIVATE_PATH"])
        )
        harness.calls.removeAll()

        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.phase, .integrationReview)
        XCTAssertEqual(harness.viewModel.presentedError, .integrationConflict)
        XCTAssertEqual(harness.calls.values, [.install, .uninstall])
    }

    func testUncertainInstallRollbackPreservesRepairStateWithoutDestructiveCompensation() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.setInstallError(
            IntegrationError.rollbackFailed(["CANARY_PRIVATE_PATH"])
        )
        harness.calls.removeAll()

        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.presentedError, .integrationConflict)
        XCTAssertTrue(harness.viewModel.requiresRepair)
        XCTAssertEqual(harness.calls.values, [.install])

        await harness.viewModel.disconnect()

        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.presentedError, .integrationConflict)
        XCTAssertTrue(harness.viewModel.requiresRepair)
    }

    func testPreviewConflictRemainsOnboardingAndNeverPersists() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewError(IntegrationError.destinationChanged("CANARY_PRIVATE_PATH"))

        await harness.viewModel.connect(using: harness.validDraft)

        XCTAssertEqual(harness.viewModel.phase, .onboarding)
        XCTAssertEqual(harness.viewModel.presentedError, .integrationConflict)
        XCTAssertEqual(harness.credentials.saveCount, 0)
    }

    func testMonitoringAppliesInitialAndStreamSnapshotsConsistently() async {
        let initial = MonitoringSnapshot(state: .thinking, sessions: [.canaryThinking], connection: .connected)
        let harness = ViewModelHarness(initialSnapshot: initial)
        await harness.connectAndApprove()

        XCTAssertEqual(harness.viewModel.currentState, .thinking)
        XCTAssertEqual(harness.viewModel.sessions, [.canaryThinking])
        XCTAssertEqual(harness.viewModel.connectionStatus, .connected)

        let update = MonitoringSnapshot(state: .error, sessions: [.canaryError], connection: .disconnected)
        await harness.monitor.emit(update)
        await waitUntil { harness.viewModel.currentState == .error }

        XCTAssertEqual(harness.viewModel.sessions, [.canaryError])
        XCTAssertEqual(harness.viewModel.connectionStatus, .disconnected)
    }

    func testPauseAndResumeAreIdempotentAndReplaceObservationSubscription() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()

        await harness.viewModel.pause()
        await harness.viewModel.pause()
        await waitUntil { await harness.monitor.terminationCount == 1 }

        XCTAssertEqual(harness.viewModel.phase, .paused)
        XCTAssertEqual(harness.viewModel.currentState, .idle)
        XCTAssertEqual(harness.viewModel.sessions, [])
        let pausedMetrics = await harness.monitor.metrics()
        XCTAssertEqual(pausedMetrics.pause, 1)

        await harness.viewModel.resume()
        await harness.viewModel.resume()

        XCTAssertEqual(harness.viewModel.phase, .monitoring)
        let resumedMetrics = await harness.monitor.metrics()
        XCTAssertEqual(resumedMetrics.resume, 1)
        XCTAssertEqual(resumedMetrics.subscriptions, 2)
        XCTAssertEqual(resumedMetrics.activeSubscriptions, 1)
    }

    func testResumeRequestedDuringPauseRunsAfterPauseCompletes() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        await harness.monitor.blockPause()
        let pause = Task { await harness.viewModel.pause() }
        await harness.monitor.waitForPauseCount(1)

        let resume = Task { await harness.viewModel.resume() }
        await Task.yield()
        await harness.monitor.releasePause()
        await pause.value
        await resume.value

        let metrics = await harness.monitor.metrics()
        XCTAssertEqual(harness.viewModel.phase, .monitoring)
        XCTAssertEqual(metrics.pause, 1)
        XCTAssertEqual(metrics.resume, 1)
        XCTAssertEqual(metrics.activeSubscriptions, 1)
    }

    func testOldMonitoringStreamCannotMutateNewEpoch() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        let oldSubscriptionValue = await harness.monitor.metrics().latestSubscriptionID
        let oldSubscription = try! XCTUnwrap(oldSubscriptionValue)
        await harness.viewModel.pause()
        await harness.viewModel.resume()

        await harness.monitor.emit(
            MonitoringSnapshot(state: .error, sessions: [.canaryError], connection: .disconnected),
            to: oldSubscription
        )
        await Task.yield()

        XCTAssertNotEqual(harness.viewModel.currentState, .error)
        let activeSubscriptions = await harness.monitor.metrics().activeSubscriptions
        XCTAssertEqual(activeSubscriptions, 1)
    }

    func testRepairIsIdempotentAndReportsConflict() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        await harness.integrations.blockRepair()
        let first = Task { await harness.viewModel.repairIntegrations() }
        await harness.integrations.waitForRepairCount(1)
        let second = Task { await harness.viewModel.repairIntegrations() }
        await Task.yield()
        await harness.integrations.releaseRepair()
        await first.value
        await second.value
        let repairCount = await harness.integrations.counts().repair
        XCTAssertEqual(repairCount, 1)

        await harness.integrations.setRepairError(IntegrationError.destinationChanged("CANARY_PRIVATE_PATH"))
        await harness.viewModel.repairIntegrations()
        XCTAssertEqual(harness.viewModel.presentedError, .integrationConflict)
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
    }

    func testDisconnectIsIdempotentAndRemovesOwnedStateInOrder() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        harness.calls.removeAll()

        let first = Task { await harness.viewModel.disconnect() }
        let second = Task { await harness.viewModel.disconnect() }
        await first.value
        await second.value

        XCTAssertEqual(harness.viewModel.phase, .onboarding)
        XCTAssertEqual(harness.viewModel.currentState, .idle)
        XCTAssertEqual(harness.viewModel.sessions, [])
        XCTAssertEqual(harness.viewModel.connectionStatus, .disconnected)
        XCTAssertEqual(harness.calls.values, [.stopMonitoring, .disableLogin, .deleteCredentials, .uninstall])
        let stopCount = await harness.monitor.metrics().stop
        let uninstallCount = await harness.integrations.counts().uninstall
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(harness.credentials.deleteCount, 1)
        XCTAssertEqual(uninstallCount, 1)
    }

    func testTypedErrorsMapToAllowlistedPresentationErrorsWithoutDescriptions() async {
        let cases: [(any Error & Sendable, PresentationError)] = [
            (TuyaClientError.invalidEndpoint, .invalidEndpoint),
            (TuyaClientError.authenticationFailure, .invalidCredential),
            (TuyaClientError.httpStatus(429), .rateLimited),
            (TuyaClientError.transport, .bulbOffline),
            (CapabilityError.missingColor, .unsupportedBulb),
            (IntegrationError.destinationChanged("CANARY_PRIVATE_PATH"), .integrationConflict),
            (HarnessSensitiveError("CANARY_ACCESS_SECRET"), .operationFailed)
        ]

        for (error, expected) in cases {
            let harness = ViewModelHarness()
            await harness.verifier.setError(error, forCall: 1)
            await harness.viewModel.connect(using: harness.validDraft)
            XCTAssertEqual(harness.viewModel.presentedError, expected)
            XCTAssertFalse(String(describing: harness.viewModel.presentedError).contains("CANARY"))
        }
    }

    private func waitUntil(
        _ predicate: @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 where !(await predicate()) {
            await Task.yield()
        }
        let satisfied = await predicate()
        XCTAssertTrue(satisfied, file: file, line: line)
    }
}
