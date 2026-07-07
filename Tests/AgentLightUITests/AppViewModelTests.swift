import XCTest
import AgentLightCore
import Observation
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
            ConnectionDraft(endpoint: "http://openapi.tuyaus.com", accessID: "CANARY_ID", accessSecret: "CANARY_SECRET", deviceID: "CANARY_DEVICE"),
            ConnectionDraft(endpoint: "https://user@openapi.tuyaus.com", accessID: "CANARY_ID", accessSecret: "CANARY_SECRET", deviceID: "CANARY_DEVICE"),
            ConnectionDraft(endpoint: "https://openapi.tuyaus.com/path", accessID: "CANARY_ID", accessSecret: "CANARY_SECRET", deviceID: "CANARY_DEVICE"),
            ConnectionDraft(endpoint: "https://openapi.tuyaus.com", accessID: " ", accessSecret: "CANARY_SECRET", deviceID: "CANARY_DEVICE"),
            ConnectionDraft(endpoint: "https://openapi.tuyaus.com", accessID: "CANARY_ID", accessSecret: " ", deviceID: "CANARY_DEVICE"),
            ConnectionDraft(endpoint: "https://openapi.tuyaus.com", accessID: "CANARY_ID", accessSecret: "CANARY_SECRET", deviceID: " ")
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
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integration])
        XCTAssertFalse(String(describing: harness.viewModel.presentedError).contains("CANARY"))
    }

    func testSecondConnectDuringVerificationIsIgnoredWithoutCancelingFirst() async {
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
        XCTAssertEqual(captured?.deviceID, "CANARY_DEVICE_ID")
        XCTAssertEqual(previewCount, 1)
    }

    func testSecondConnectDuringPreviewIsIgnoredWithoutCancelingFirst() async {
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
        XCTAssertEqual(captured?.deviceID, "CANARY_DEVICE_ID")
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
        let overlap = AsyncInvocationBarrier()
        let second = Task {
            await overlap.arrive()
            await harness.viewModel.approveIntegrations()
        }
        await overlap.wait()
        await harness.integrations.releaseInstall()
        await first.value
        await second.value

        let installCount = await harness.integrations.counts().install
        let startCount = await harness.monitor.metrics().start
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(harness.credentials.saveCount, 1)
        XCTAssertEqual(startCount, 1)
    }

    func testConnectDuringApprovalIsIgnoredWithoutStartingAnotherVerification() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.blockInstall()
        let approval = Task { await harness.viewModel.approveIntegrations() }
        await harness.integrations.waitForInstallCount(1)

        await harness.viewModel.connect(using: harness.validDraft)

        let verifyCount = await harness.verifier.count()
        XCTAssertEqual(verifyCount, 1)
        await harness.integrations.releaseInstall()
        await approval.value
        XCTAssertEqual(harness.viewModel.phase, .monitoring)
    }

    func testDisconnectDuringCancellationIgnoringInstallWaitsThenCompensates() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.blockInstall()
        let approval = Task { await harness.viewModel.approveIntegrations() }
        await harness.integrations.waitForInstallCount(1)

        let overlap = AsyncInvocationBarrier()
        let disconnect = Task {
            await overlap.arrive()
            await harness.viewModel.disconnect()
        }
        await overlap.wait()
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

    func testDisconnectRestoresCredentialsThatPreexistedApproval() async throws {
        let harness = ViewModelHarness()
        let previous = harness.previousCredentials
        harness.credentials.seed(previous)
        await harness.connectAndApprove()

        await harness.viewModel.disconnect()

        XCTAssertEqual(harness.credentials.storedCredentials(), previous)
        XCTAssertEqual(harness.credentials.saveCount, 2)
        XCTAssertEqual(harness.credentials.deleteCount, 0)
        XCTAssertEqual(harness.viewModel.phase, .onboarding)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
    }

    func testCredentialRestoreFailureCreatesTypedObligationAndRetryClearsIt() async {
        let harness = ViewModelHarness()
        harness.credentials.seed(harness.previousCredentials)
        harness.credentials.setSaveError(HarnessSensitiveError("CANARY_RESTORE_FAILURE"), forCall: 2)
        await harness.connectAndApprove()

        await harness.viewModel.disconnect()

        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.credentialRestore])
        XCTAssertEqual(harness.viewModel.presentedError, .operationFailed)

        harness.credentials.setSaveError(nil, forCall: 2)
        await harness.viewModel.disconnect()

        XCTAssertEqual(harness.credentials.storedCredentials(), harness.previousCredentials)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
        XCTAssertEqual(harness.viewModel.phase, .onboarding)
    }

    func testApprovalCompensationRestoreFailurePreservesOriginalRateLimitError() async {
        let harness = ViewModelHarness()
        harness.credentials.seed(harness.previousCredentials)
        harness.credentials.setSaveError(HarnessSensitiveError("CANARY_RESTORE_FAILURE"), forCall: 2)
        await harness.monitor.setStartError(TuyaClientError.httpStatus(429))
        await harness.viewModel.connect(using: harness.validDraft)

        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.presentedError, .rateLimited)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.credentialRestore])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
    }

    func testCredentialDeleteFailureCreatesTypedObligationAndRetryClearsIt() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        harness.credentials.setDeleteError(HarnessSensitiveError("CANARY_DELETE_FAILURE"))

        await harness.viewModel.disconnect()

        XCTAssertEqual(harness.viewModel.outstandingObligations, [.credentialDelete])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)

        harness.credentials.setDeleteError(nil)
        await harness.viewModel.disconnect()

        XCTAssertNil(harness.credentials.storedCredentials())
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
        XCTAssertEqual(harness.viewModel.phase, .onboarding)
    }

    func testPreenabledLoginItemIsNeverDisabledByDisconnect() async {
        let harness = ViewModelHarness()
        harness.loginItem.currentStatus = .enabled
        await harness.connectAndApprove()

        await harness.viewModel.disconnect()

        XCTAssertEqual(harness.loginItem.currentStatus, .enabled)
        XCTAssertEqual(harness.loginItem.disableCount, 0)
    }

    func testNewApprovalPendingRegistrationIsUnregisteredDuringCompensation() async {
        let harness = ViewModelHarness()
        harness.loginItem.registerResult = .requiresApproval
        await harness.viewModel.connect(using: harness.validDraft)

        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.presentedError, .loginApprovalRequired)
        XCTAssertEqual(harness.loginItem.currentStatus, .notRegistered)
        XCTAssertEqual(harness.loginItem.disableCount, 1)
    }

    func testNewApprovalPendingUnregisterFailurePreservesOriginalErrorAndTypedObligation() async {
        let harness = ViewModelHarness()
        harness.loginItem.registerResult = .requiresApproval
        harness.loginItem.disableError = HarnessSensitiveError("CANARY_UNREGISTER_FAILURE")
        await harness.viewModel.connect(using: harness.validDraft)

        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.presentedError, .loginApprovalRequired)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.loginRegistrationCleanup])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)

        harness.loginItem.disableError = nil
        await harness.viewModel.disconnect()
        XCTAssertEqual(harness.loginItem.currentStatus, .notRegistered)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
    }

    func testPreexistingApprovalPendingRegistrationIsNeverUnregistered() async {
        let harness = ViewModelHarness()
        harness.loginItem.currentStatus = .requiresApproval
        await harness.viewModel.connect(using: harness.validDraft)

        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.presentedError, .loginApprovalRequired)
        XCTAssertEqual(harness.loginItem.currentStatus, .requiresApproval)
        XCTAssertEqual(harness.loginItem.disableCount, 0)
    }

    func testLoginUnregisterFailureCreatesTypedCleanupObligation() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        harness.loginItem.disableError = HarnessSensitiveError("CANARY_UNREGISTER_FAILURE")

        await harness.viewModel.disconnect()

        XCTAssertEqual(harness.viewModel.outstandingObligations, [.loginRegistrationCleanup])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
    }

    func testPreexistingIntegrationsAreNeverUninstalled() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([true, true, true])
        await harness.connectAndApprove()

        await harness.viewModel.disconnect()

        let uninstallCount = await harness.integrations.counts().uninstall
        XCTAssertEqual(uninstallCount, 0)
        XCTAssertFalse(harness.viewModel.outstandingObligations.contains(.integration))
        XCTAssertEqual(harness.viewModel.phase, .onboarding)
    }

    func testPartialPreexistingIntegrationsPreserveEntriesAndCreateExplicitObligation() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([true, false, false])
        await harness.connectAndApprove()

        await harness.viewModel.disconnect()

        let uninstallCount = await harness.integrations.counts().uninstall
        XCTAssertEqual(uninstallCount, 0)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integration])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
    }

    func testApprovalFailureNeverUninstallsFullyPreexistingIntegrations() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([true, true, true])
        await harness.monitor.setStartError(TuyaClientError.transport)
        await harness.viewModel.connect(using: harness.validDraft)

        await harness.viewModel.approveIntegrations()

        let uninstallCount = await harness.integrations.counts().uninstall
        XCTAssertEqual(uninstallCount, 0)
        XCTAssertEqual(harness.viewModel.phase, .integrationReview)
        XCTAssertEqual(harness.viewModel.presentedError, .bulbOffline)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
    }

    func testApprovalFailurePreservesPartialIntegrationsAsExplicitObligation() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([true, false, false])
        await harness.monitor.setStartError(TuyaClientError.transport)
        await harness.viewModel.connect(using: harness.validDraft)

        await harness.viewModel.approveIntegrations()

        let uninstallCount = await harness.integrations.counts().uninstall
        XCTAssertEqual(uninstallCount, 0)
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.presentedError, .bulbOffline)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integration])
    }

    func testRepairClearsOnlyIntegrationObligationAndPreservesOtherCleanupFailure() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([true, false, false])
        await harness.connectAndApprove()
        harness.credentials.setDeleteError(HarnessSensitiveError("CANARY_DELETE_FAILURE"))
        await harness.viewModel.disconnect()
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integration, .credentialDelete])

        await harness.viewModel.repairIntegrations()

        XCTAssertEqual(harness.viewModel.outstandingObligations, [.credentialDelete])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)

        harness.credentials.setDeleteError(nil)
        await harness.viewModel.disconnect()
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
        XCTAssertEqual(harness.viewModel.phase, .onboarding)
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
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integration])
        XCTAssertEqual(harness.calls.values, [.install])

        await harness.viewModel.approveIntegrations()
        let installCount = await harness.integrations.counts().install
        XCTAssertEqual(installCount, 1)

        await harness.viewModel.disconnect()

        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.presentedError, .integrationConflict)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integration])
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
        let changed = expectation(description: "monitor snapshot applied")
        withObservationTracking {
            _ = harness.viewModel.currentState
        } onChange: {
            changed.fulfill()
        }
        await harness.monitor.emit(update)
        await fulfillment(of: [changed])

        XCTAssertEqual(harness.viewModel.sessions, [.canaryError])
        XCTAssertEqual(harness.viewModel.connectionStatus, .disconnected)
    }

    func testPauseAndResumeAreIdempotentAndReplaceObservationSubscription() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()

        await harness.viewModel.pause()
        await harness.viewModel.pause()
        await harness.monitor.waitForTerminationCount(1)

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

    func testOverlappingDuplicatePauseAndResumeShareEachInFlightOperation() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        await harness.monitor.blockPause()
        let firstPause = Task { await harness.viewModel.pause() }
        await harness.monitor.waitForPauseCount(1)
        let pauseOverlap = AsyncInvocationBarrier()
        let secondPause = Task {
            await pauseOverlap.arrive()
            await harness.viewModel.pause()
        }
        await pauseOverlap.wait()
        await harness.monitor.releasePause()
        await firstPause.value
        await secondPause.value
        let pauseCount = await harness.monitor.metrics().pause
        XCTAssertEqual(pauseCount, 1)

        await harness.monitor.blockResume()
        let firstResume = Task { await harness.viewModel.resume() }
        await harness.monitor.waitForResumeCount(1)
        let resumeOverlap = AsyncInvocationBarrier()
        let secondResume = Task {
            await resumeOverlap.arrive()
            await harness.viewModel.resume()
        }
        await resumeOverlap.wait()
        await harness.monitor.releaseResume()
        await firstResume.value
        await secondResume.value
        let resumeCount = await harness.monitor.metrics().resume
        XCTAssertEqual(resumeCount, 1)
    }

    func testResumeRequestedDuringPauseRunsAfterPauseCompletes() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        await harness.monitor.blockPause()
        let pause = Task { await harness.viewModel.pause() }
        await harness.monitor.waitForPauseCount(1)

        let overlap = AsyncInvocationBarrier()
        let resume = Task {
            await overlap.arrive()
            await harness.viewModel.resume()
        }
        await overlap.wait()
        await harness.monitor.releasePause()
        await pause.value
        await resume.value

        let metrics = await harness.monitor.metrics()
        XCTAssertEqual(harness.viewModel.phase, .monitoring)
        XCTAssertEqual(metrics.pause, 1)
        XCTAssertEqual(metrics.resume, 1)
        XCTAssertEqual(metrics.activeSubscriptions, 1)
    }

    func testOldMonitoringStreamCannotMutateNewEpoch() async throws {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        let oldSubscriptionValue = await harness.monitor.metrics().latestSubscriptionID
        let oldSubscription = try XCTUnwrap(oldSubscriptionValue)
        await harness.viewModel.pause()
        await harness.viewModel.resume()

        await harness.monitor.emit(
            MonitoringSnapshot(state: .error, sessions: [.canaryError], connection: .disconnected),
            to: oldSubscription
        )
        XCTAssertNotEqual(harness.viewModel.currentState, .error)
        let activeSubscriptions = await harness.monitor.metrics().activeSubscriptions
        XCTAssertEqual(activeSubscriptions, 1)
    }

    func testNaturalStreamEndClearsHandleMarksDisconnectedAndAllowsResubscribe() async throws {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        let subscriptionValue = await harness.monitor.metrics().latestSubscriptionID
        let subscription = try XCTUnwrap(subscriptionValue)
        let disconnected = expectation(description: "stream end marks disconnected")
        withObservationTracking {
            _ = harness.viewModel.connectionStatus
        } onChange: {
            disconnected.fulfill()
        }

        await harness.monitor.finish(subscription)
        await fulfillment(of: [disconnected], timeout: 1)
        await harness.monitor.waitForTerminationCount(1)

        XCTAssertEqual(harness.viewModel.connectionStatus, .disconnected)
        guard harness.viewModel.connectionStatus == .disconnected else { return }
        await harness.viewModel.observeMonitoring()
        await harness.monitor.waitForSubscriptionCount(2)
        let activeSubscriptions = await harness.monitor.metrics().activeSubscriptions
        XCTAssertEqual(activeSubscriptions, 1)
    }

    func testObservationTaskDoesNotRetainViewModelAfterOwnerRelease() async {
        let harness = ViewModelHarness()
        let weakBox = WeakViewModelBox()
        do {
            let model = AppViewModel(
                credentials: harness.credentials,
                integrations: harness.integrations,
                monitor: harness.monitor,
                loginItem: harness.loginItem,
                verifier: harness.verifier
            )
            weakBox.value = model
            await model.connect(using: harness.validDraft)
            await model.approveIntegrations()
            await harness.monitor.waitForSubscriptionCount(1)
        }

        XCTAssertNil(weakBox.value)
        guard weakBox.value == nil else { return }
        await harness.monitor.waitForTerminationCount(1)
    }

    func testConnectIsIgnoredWhileMonitoringWithoutCancelingObservation() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        let before = await harness.monitor.metrics()

        await harness.viewModel.connect(using: harness.validDraft)

        let after = await harness.monitor.metrics()
        XCTAssertEqual(harness.viewModel.phase, .monitoring)
        XCTAssertEqual(after.subscriptions, before.subscriptions)
        XCTAssertEqual(after.activeSubscriptions, 1)
        let verifyCount = await harness.verifier.count()
        XCTAssertEqual(verifyCount, 1)
    }

    func testConnectIsIgnoredWhilePausedWithoutRestartingOrObservingMonitor() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        await harness.viewModel.pause()
        await harness.monitor.waitForTerminationCount(1)

        await harness.viewModel.connect(using: harness.validDraft)

        XCTAssertEqual(harness.viewModel.phase, .paused)
        let activeSubscriptions = await harness.monitor.metrics().activeSubscriptions
        let verifyCount = await harness.verifier.count()
        XCTAssertEqual(activeSubscriptions, 0)
        XCTAssertEqual(verifyCount, 1)
    }

    func testConnectIsBlockedWhileAnyCleanupObligationRemains() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([true, false, false])
        await harness.connectAndApprove()
        await harness.viewModel.disconnect()
        let verifyCount = await harness.verifier.count()

        await harness.viewModel.connect(using: harness.validDraft)

        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        let afterVerifyCount = await harness.verifier.count()
        XCTAssertEqual(afterVerifyCount, verifyCount)
    }

    func testResumeFailureStaysPausedWithSanitizedOfflineError() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        await harness.viewModel.pause()
        await harness.monitor.setResumeError(TuyaClientError.transport)

        await harness.viewModel.resume()

        XCTAssertEqual(harness.viewModel.phase, .paused)
        XCTAssertEqual(harness.viewModel.presentedError, .bulbOffline)
        let activeSubscriptions = await harness.monitor.metrics().activeSubscriptions
        XCTAssertEqual(activeSubscriptions, 0)
    }

    func testRepairIsIdempotentAndReportsConflict() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        await harness.integrations.blockRepair()
        let first = Task { await harness.viewModel.repairIntegrations() }
        await harness.integrations.waitForRepairCount(1)
        let overlap = AsyncInvocationBarrier()
        let second = Task {
            await overlap.arrive()
            await harness.viewModel.repairIntegrations()
        }
        await overlap.wait()
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

        await harness.monitor.blockStop()
        let first = Task { await harness.viewModel.disconnect() }
        await harness.monitor.waitForStopCount(1)
        let overlap = AsyncInvocationBarrier()
        let second = Task {
            await overlap.arrive()
            await harness.viewModel.disconnect()
        }
        await overlap.wait()
        await harness.monitor.releaseStop()
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
            (TuyaClientError.httpStatus(408), .bulbOffline),
            (TuyaClientError.httpStatus(500), .bulbOffline),
            (TuyaClientError.httpStatus(503), .bulbOffline),
            (TuyaClientError.transport, .bulbOffline),
            (URLError(.timedOut), .bulbOffline),
            (URLError(.notConnectedToInternet), .bulbOffline),
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

}
