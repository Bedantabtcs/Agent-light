import XCTest
import AgentLightCore
import Observation
@testable import AgentLightUI

@MainActor
final class AppViewModelTests: XCTestCase {
    func testLaunchAtLoginStatusAndRetryUseViewModelBoundary() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        XCTAssertEqual(harness.viewModel.loginItemStatus, .enabled)

        harness.loginItem.currentStatus = .notRegistered
        await harness.viewModel.requestLaunchAtLogin()

        XCTAssertEqual(harness.viewModel.loginItemStatus, .enabled)
        XCTAssertEqual(harness.loginItem.enableCount, 2)
    }

    func testLegacyViewModelConformerGetsDefaultSynchronization() async {
        let model = LegacyAppViewModelConformer()

        await model.synchronizeOwnership()

        XCTAssertEqual(model.phase, .onboarding)
    }

    func testFiveDependencyInitializerRemainsSourceCompatible() {
        let harness = ViewModelHarness()
        _ = AppViewModel(
            credentials: harness.credentials,
            integrations: harness.integrations,
            monitor: harness.monitor,
            loginItem: harness.loginItem,
            verifier: harness.verifier
        )
    }
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
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationUninstallRetry])
        XCTAssertFalse(String(describing: harness.viewModel.presentedError).contains("CANARY"))
    }

    func testCompensationArtifactCleanupFailureIsNotDowngradedToUninstallRetry() async {
        let harness = ViewModelHarness()
        await harness.monitor.setStartError(TuyaClientError.transport)
        await harness.integrations.setUninstallError(
            IntegrationError.artifactCleanupFailure(["CANARY_ARTIFACT"])
        )
        await harness.viewModel.connect(using: harness.validDraft)

        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationArtifactCleanup])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
    }

    func testCompensationMapsEveryCommittedCleanupErrorToArtifactObligation() async {
        let harness = ViewModelHarness()
        let errors: [IntegrationError] = [
            .committedWithCleanupFailure(["CANARY_LEGACY"]),
            .committedWithReceiptCleanupFailure(
                receipt: harness.freshInstallReceipt,
                failures: ["CANARY_RECEIPT"]
            )
        ]
        for error in errors {
            let scenario = ViewModelHarness()
            await scenario.monitor.setStartError(TuyaClientError.transport)
            await scenario.integrations.setUninstallError(error)
            await scenario.viewModel.connect(using: scenario.validDraft)

            await scenario.viewModel.approveIntegrations()

            XCTAssertEqual(scenario.viewModel.outstandingObligations, [.integrationArtifactCleanup])
        }
    }

    func testDisconnectArtifactCleanupFailureIsNotDowngradedToUninstallRetry() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        await harness.integrations.setUninstallError(
            IntegrationError.artifactCleanupFailure(["CANARY_ARTIFACT"])
        )

        await harness.viewModel.disconnect()

        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationArtifactCleanup])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
    }

    func testRepairOfUninstallRetryCallsUninstallRatherThanInstallOrRepair() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.monitor.setStartError(TuyaClientError.transport)
        await harness.integrations.setUninstallError(HarnessSensitiveError("CANARY_UNINSTALL_FAILURE"))
        await harness.viewModel.approveIntegrations()
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationUninstallRetry])
        await harness.integrations.setUninstallError(nil)

        await harness.viewModel.repairIntegrations()

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.uninstall, 2)
        XCTAssertEqual(counts.repair, 0)
        XCTAssertEqual(counts.install, 1)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
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
        await harness.viewModel.waitForActionEntry(.connect, count: 2)
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
        await harness.viewModel.waitForOperationWaiterCount(.approval, count: 1)
        let second = Task { await harness.viewModel.approveIntegrations() }
        await harness.viewModel.waitForOperationWaiterCount(.approval, count: 2)
        await cancelAndAwait(first, operation: "first shared approval waiter")
        await harness.integrations.releaseInstall()
        await second.value

        let installCount = await harness.integrations.counts().install
        let startCount = await harness.monitor.metrics().start
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(harness.credentials.saveCount, 1)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(harness.viewModel.phase, .monitoring)
    }

    func testCancelingNoninitiatingApprovalWaiterKeepsSharedDriverAlive() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.blockInstall()
        let initiating = Task { await harness.viewModel.approveIntegrations() }
        await harness.integrations.waitForInstallCount(1)
        await harness.viewModel.waitForOperationWaiterCount(.approval, count: 1)
        let noninitiating = Task { await harness.viewModel.approveIntegrations() }
        await harness.viewModel.waitForOperationWaiterCount(.approval, count: 2)

        await cancelAndAwait(noninitiating, operation: "noninitiating approval waiter")
        await harness.integrations.releaseInstall()
        await initiating.value

        XCTAssertEqual(harness.viewModel.phase, .monitoring)
        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.install, 1)
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

        let disconnect = Task { await harness.viewModel.disconnect() }
        await harness.integrations.releaseInstall()
        await approval.value
        await disconnect.value

        let counts = await harness.integrations.counts()
        XCTAssertEqual(harness.viewModel.phase, .onboarding)
        XCTAssertEqual(counts.uninstall, 1)
        XCTAssertEqual(harness.credentials.saveCount, 0)
    }

    func testDisconnectAwaitingApprovalRetainsAbandonedInstallArtifactFailure() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.blockInstall()
        await harness.integrations.setUninstallError(
            IntegrationError.artifactCleanupFailure(["CANARY_ARTIFACT"])
        )
        let approval = Task { await harness.viewModel.approveIntegrations() }
        await harness.integrations.waitForInstallCount(1)
        let disconnect = Task { await harness.viewModel.disconnect() }
        await harness.viewModel.waitForOperationWaiterCount(.disconnect, count: 1)

        await harness.integrations.releaseInstall()
        await approval.value
        await disconnect.value

        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationArtifactCleanup])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
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

    func testLoginCleanupRetainsObligationWhenTransitionEndsUnknown() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        harness.loginItem.disableResult = .unknown

        await harness.viewModel.disconnect()

        XCTAssertEqual(harness.loginItem.currentStatus, .unknown)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.loginRegistrationCleanup])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)

        harness.loginItem.currentStatus = .notRegistered
        await harness.viewModel.disconnect()
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
    }

    func testPreexistingIntegrationsAreNeverUninstalled() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([true, true, true])
        await harness.connectAndApprove()

        await harness.viewModel.disconnect()

        let uninstallCount = await harness.integrations.counts().uninstall
        XCTAssertEqual(uninstallCount, 0)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
        XCTAssertEqual(harness.viewModel.phase, .onboarding)
    }

    func testCommitTimeReceiptOverridesFreshPreviewWhenEntriesAppearBeforeInstall() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([false, false, false])
        await harness.integrations.setInstallOwnership([
            .fullyPreexisting, .fullyPreexisting, .fullyPreexisting
        ])
        await harness.connectAndApprove()

        await harness.viewModel.disconnect()

        let uninstallCount = await harness.integrations.counts().uninstall
        XCTAssertEqual(uninstallCount, 0)
        XCTAssertEqual(harness.viewModel.phase, .onboarding)
    }

    func testPartialPreexistingIntegrationsPreserveEntriesAndCreateExplicitObligation() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([true, false, false])
        await harness.connectAndApprove()

        await harness.viewModel.disconnect()

        let uninstallCount = await harness.integrations.counts().uninstall
        XCTAssertEqual(uninstallCount, 0)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationMixedAdoption])
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
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationMixedAdoption])
    }

    func testRepairClearsOnlyIntegrationObligationAndPreservesOtherCleanupFailure() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([true, false, false])
        await harness.connectAndApprove()
        harness.credentials.setDeleteError(HarnessSensitiveError("CANARY_DELETE_FAILURE"))
        await harness.viewModel.disconnect()
        XCTAssertEqual(
            harness.viewModel.outstandingObligations,
            [.integrationMixedAdoption, .credentialDelete]
        )

        await harness.viewModel.repairIntegrations()

        XCTAssertEqual(harness.viewModel.outstandingObligations, [.credentialDelete])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)

        harness.credentials.setDeleteError(nil)
        await harness.viewModel.disconnect()
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
        XCTAssertEqual(harness.viewModel.phase, .onboarding)
    }

    func testRepairOfMixedAdoptionUsesAuthoritativeInstallNotRepairOrUninstall() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([true, false, false])
        await harness.connectAndApprove()
        await harness.viewModel.disconnect()
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationMixedAdoption])

        await harness.viewModel.repairIntegrations()

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.install, 2)
        XCTAssertEqual(counts.repair, 0)
        XCTAssertEqual(counts.uninstall, 0)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
    }

    func testMixedAdoptionLegacyCommittedCleanupRetainsMixedAndArtifactObligations() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([true, false, false])
        await harness.connectAndApprove()
        await harness.viewModel.disconnect()
        await harness.integrations.setInstallError(
            IntegrationError.committedWithCleanupFailure(["CANARY_ARTIFACT"])
        )

        await harness.viewModel.repairIntegrations()

        XCTAssertEqual(
            harness.viewModel.outstandingObligations,
            [.integrationMixedAdoption, .integrationArtifactCleanup]
        )
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
    }

    func testMixedAdoptionMalformedCommittedReceiptRetainsMixedThroughArtifactVerification() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.setInstallOwnership([.fresh])
        await harness.viewModel.approveIntegrations()
        let malformedReceipt = IntegrationInstallReceipt(
            sources: [
                IntegrationSourceReceipt(source: .cursor, ownership: .fresh),
                IntegrationSourceReceipt(source: .cursor, ownership: .fresh),
                IntegrationSourceReceipt(source: .claudeCode, ownership: .fresh)
            ]
        )
        await harness.integrations.setInstallError(
            IntegrationError.committedWithReceiptCleanupFailure(
                receipt: malformedReceipt,
                failures: ["CANARY_ARTIFACT"]
            )
        )

        await harness.viewModel.repairIntegrations()

        XCTAssertEqual(
            harness.viewModel.outstandingObligations,
            [.integrationMixedAdoption, .integrationArtifactCleanup]
        )
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)

        await harness.integrations.setInstallError(nil)
        await harness.integrations.setArtifactVerification(clean: true)
        await harness.viewModel.repairIntegrations()

        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationMixedAdoption])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)

        await harness.integrations.setInstallOwnership([.fresh, .fresh, .fresh])
        await harness.viewModel.repairIntegrations()

        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
        XCTAssertEqual(harness.viewModel.phase, .integrationReview)
    }

    func testMalformedCommittedReceiptCannotClearRollbackOrUninstallOwnership() async {
        let malformedReceipt = IntegrationInstallReceipt(
            sources: [
                IntegrationSourceReceipt(source: .codex, ownership: .fresh),
                IntegrationSourceReceipt(source: .codex, ownership: .fresh),
                IntegrationSourceReceipt(source: .cursor, ownership: .fresh)
            ]
        )
        let malformedError = IntegrationError.committedWithReceiptCleanupFailure(
            receipt: malformedReceipt,
            failures: ["CANARY_ARTIFACT"]
        )

        let rollback = ViewModelHarness()
        await rollback.viewModel.connect(using: rollback.validDraft)
        await rollback.integrations.setInstallError(
            IntegrationError.rollbackFailed(["CANARY_ROLLBACK"])
        )
        await rollback.viewModel.approveIntegrations()
        await rollback.integrations.setRepairError(malformedError)
        await rollback.viewModel.repairIntegrations()
        XCTAssertEqual(
            rollback.viewModel.outstandingObligations,
            [.integrationRollbackRepair, .integrationArtifactCleanup]
        )

        let uninstall = ViewModelHarness()
        await uninstall.connectAndApprove()
        await uninstall.integrations.setUninstallError(HarnessSensitiveError("CANARY_UNINSTALL"))
        await uninstall.viewModel.disconnect()
        await uninstall.integrations.setUninstallError(malformedError)
        await uninstall.viewModel.repairIntegrations()
        XCTAssertEqual(
            uninstall.viewModel.outstandingObligations,
            [.integrationUninstallRetry, .integrationArtifactCleanup]
        )
    }

    func testMalformedCommittedReceiptCannotClearHealthOrArtifactOnlyOwnership() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        let malformedReceipt = IntegrationInstallReceipt(
            sources: [
                IntegrationSourceReceipt(source: .claudeCode, ownership: .fresh),
                IntegrationSourceReceipt(source: .claudeCode, ownership: .fresh),
                IntegrationSourceReceipt(source: .cursor, ownership: .fresh)
            ]
        )
        let malformedError = IntegrationError.committedWithReceiptCleanupFailure(
            receipt: malformedReceipt,
            failures: ["CANARY_ARTIFACT"]
        )
        await harness.integrations.setRepairError(malformedError)
        await harness.viewModel.repairIntegrations()
        await harness.integrations.setRepairError(nil)
        await harness.integrations.setArtifactVerification(clean: false, error: malformedError)

        await harness.viewModel.repairIntegrations()
        await harness.viewModel.disconnect()

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.uninstall, 1)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationArtifactCleanup])
    }

    func testMixedAdoptionValidCommittedReceiptAppliesAuthoritativeCleanupTransition() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.setInstallOwnership([.fresh])
        await harness.viewModel.approveIntegrations()
        await harness.integrations.setInstallError(
            IntegrationError.committedWithReceiptCleanupFailure(
                receipt: harness.freshInstallReceipt,
                failures: ["CANARY_ARTIFACT"]
            )
        )

        await harness.viewModel.repairIntegrations()

        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationArtifactCleanup])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)

        await harness.integrations.setInstallError(nil)
        await harness.integrations.setArtifactVerification(clean: true)
        await harness.viewModel.repairIntegrations()

        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
        XCTAssertEqual(harness.viewModel.phase, .integrationReview)
    }

    func testMixedAdoptionInvalidReceiptRetainsMixedObligation() async {
        let harness = ViewModelHarness()
        await harness.integrations.setPreviewOwnership([true, false, false])
        await harness.connectAndApprove()
        await harness.viewModel.disconnect()
        await harness.integrations.setInstallOwnership([.fresh])

        await harness.viewModel.repairIntegrations()

        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationMixedAdoption])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
    }

    func testCommittedInstallFailureUninstallsCommittedOwnedHooks() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.setInstallError(
            IntegrationError.committedWithReceiptCleanupFailure(
                receipt: harness.freshInstallReceipt,
                failures: ["CANARY_PRIVATE_PATH"]
            )
        )
        harness.calls.removeAll()

        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.presentedError, .integrationConflict)
        XCTAssertEqual(harness.calls.values, [.install, .uninstall])
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationArtifactCleanup])

        await harness.viewModel.repairIntegrations()
        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.install, 1)
        XCTAssertEqual(counts.repair, 0)
        XCTAssertEqual(counts.uninstall, 1)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationArtifactCleanup])
    }

    func testArtifactObligationClearsOnlyAfterVerificationConfirmsAbsence() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.setInstallError(
            IntegrationError.committedWithReceiptCleanupFailure(
                receipt: harness.freshInstallReceipt,
                failures: ["CANARY_PRIVATE_PATH"]
            )
        )
        await harness.viewModel.approveIntegrations()

        await harness.integrations.setArtifactVerification(clean: false)
        await harness.viewModel.repairIntegrations()
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationArtifactCleanup])

        await harness.integrations.setArtifactVerification(clean: true)
        await harness.viewModel.repairIntegrations()
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
        XCTAssertEqual(harness.viewModel.phase, .integrationReview)
    }

    func testArtifactVerificationErrorRetainsObligationAndRepairState() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.setInstallError(
            IntegrationError.committedWithReceiptCleanupFailure(
                receipt: harness.freshInstallReceipt,
                failures: ["CANARY_PRIVATE_PATH"]
            )
        )
        await harness.viewModel.approveIntegrations()
        await harness.integrations.setArtifactVerification(
            clean: false,
            error: IntegrationError.fileOperation("CANARY_SCAN_ERROR")
        )

        await harness.viewModel.repairIntegrations()

        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationArtifactCleanup])
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.presentedError, .integrationConflict)
    }

    func testInvalidInstallReceiptRequiresRepairWithoutDestructiveCleanup() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.setInstallOwnership([.fresh])

        await harness.viewModel.approveIntegrations()

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.uninstall, 0)
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationMixedAdoption])
    }

    func testLegacyCommittedCleanupErrorCreatesArtifactAndMixedObligations() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.setInstallError(
            IntegrationError.committedWithCleanupFailure(["CANARY_ARTIFACT"])
        )

        await harness.viewModel.approveIntegrations()

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.uninstall, 0)
        XCTAssertEqual(
            harness.viewModel.outstandingObligations,
            [.integrationArtifactCleanup, .integrationMixedAdoption]
        )
        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
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
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationRollbackRepair])
        XCTAssertEqual(harness.calls.values, [.install])

        await harness.viewModel.approveIntegrations()
        let installCount = await harness.integrations.counts().install
        XCTAssertEqual(installCount, 1)

        await harness.viewModel.disconnect()

        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.presentedError, .integrationConflict)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationRollbackRepair])
    }

    func testRepairOfRollbackFailureUsesRepairWithoutRepeatingInstall() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.setInstallError(
            IntegrationError.rollbackFailed(["CANARY_PRIVATE_PATH"])
        )
        await harness.viewModel.approveIntegrations()

        await harness.viewModel.repairIntegrations()

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.install, 1)
        XCTAssertEqual(counts.repair, 1)
        XCTAssertEqual(counts.uninstall, 0)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
        XCTAssertEqual(harness.viewModel.phase, .integrationReview)
    }

    func testHealthRepairCommittedCleanupPreservesOwnedHooksForDisconnect() async {
        for errorKind in 0..<3 {
            let harness = ViewModelHarness()
            await harness.connectAndApprove()
            let error: any Error & Sendable
            switch errorKind {
            case 0:
                error = IntegrationError.artifactCleanupFailure(["CANARY_ARTIFACT"])
            case 1:
                error = IntegrationError.committedWithCleanupFailure(["CANARY_LEGACY"])
            default:
                error = IntegrationError.committedWithReceiptCleanupFailure(
                    receipt: harness.freshInstallReceipt,
                    failures: ["CANARY_RECEIPT"]
                )
            }
            await harness.integrations.setRepairError(error)

            await harness.viewModel.repairIntegrations()
            await harness.integrations.setRepairError(nil)
            await harness.viewModel.disconnect()

            let counts = await harness.integrations.counts()
            XCTAssertEqual(counts.uninstall, 1, "error kind \(errorKind)")
            XCTAssertEqual(
                harness.viewModel.outstandingObligations,
                [.integrationArtifactCleanup],
                "error kind \(errorKind)"
            )
        }
    }

    func testArtifactOnlyVerificationPreservesOwnedHooksAfterHealthCleanupFailure() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        await harness.integrations.setRepairError(
            IntegrationError.committedWithCleanupFailure(["CANARY_ARTIFACT"])
        )
        await harness.viewModel.repairIntegrations()
        await harness.integrations.setRepairError(nil)
        await harness.integrations.setArtifactVerification(clean: true)

        await harness.viewModel.repairIntegrations()
        await harness.viewModel.disconnect()

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.uninstall, 1)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
        XCTAssertEqual(harness.viewModel.phase, .onboarding)
    }

    func testRollbackRepairClearsCleanupOwnershipAndAllowsApprovalRetry() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.setInstallError(
            IntegrationError.rollbackFailed(["CANARY_PRIVATE_PATH"])
        )
        await harness.viewModel.approveIntegrations()

        await harness.viewModel.repairIntegrations()
        await harness.integrations.setInstallError(nil)
        await harness.viewModel.approveIntegrations()

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.install, 2)
        XCTAssertEqual(counts.repair, 1)
        XCTAssertEqual(harness.viewModel.phase, .monitoring)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
    }

    func testMixedAdoptionRepairClearsCleanupOwnershipAndAllowsApprovalRetry() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.setInstallOwnership([.fresh])
        await harness.viewModel.approveIntegrations()
        await harness.integrations.setInstallOwnership([.fresh, .fresh, .fresh])

        await harness.viewModel.repairIntegrations()
        await harness.viewModel.approveIntegrations()

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.install, 3)
        XCTAssertEqual(counts.repair, 0)
        XCTAssertEqual(harness.viewModel.phase, .monitoring)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
    }

    func testReplacementReconcilesAfterRollbackRepairClearsCleanupOwnership() async {
        let harness = ViewModelHarness()
        let owner = makeViewModel(using: harness)
        await owner.connect(using: harness.validDraft)
        await harness.integrations.setInstallError(
            IntegrationError.rollbackFailed(["CANARY_PRIVATE_PATH"])
        )
        await owner.approveIntegrations()
        let replacement = makeViewModel(using: harness)
        await replacement.synchronizeOwnership()
        XCTAssertEqual(replacement.phase, .repairRequired)

        await owner.repairIntegrations()
        await replacement.synchronizeOwnership()

        XCTAssertEqual(replacement.outstandingObligations, [])
        XCTAssertEqual(replacement.phase, .onboarding)
        XCTAssertNil(replacement.presentedError)
    }

    func testReplacementReconcilesAfterMixedAdoptionClearsCleanupOwnership() async {
        let harness = ViewModelHarness()
        let owner = makeViewModel(using: harness)
        await owner.connect(using: harness.validDraft)
        await harness.integrations.setInstallOwnership([.fresh])
        await owner.approveIntegrations()
        let replacement = makeViewModel(using: harness)
        await replacement.synchronizeOwnership()
        XCTAssertEqual(replacement.phase, .repairRequired)
        await harness.integrations.setInstallOwnership([.fresh, .fresh, .fresh])

        await owner.repairIntegrations()
        await replacement.synchronizeOwnership()

        XCTAssertEqual(replacement.outstandingObligations, [])
        XCTAssertEqual(replacement.phase, .onboarding)
        XCTAssertNil(replacement.presentedError)
    }

    func testPresentationHandleRegistryPrunesDeallocatedReplacements() async {
        let harness = ViewModelHarness()
        for _ in 0..<25 {
            var replacement: AppViewModel? = makeViewModel(using: harness)
            await replacement?.synchronizeOwnership()
            weak var weakReplacement = replacement
            replacement = nil
            XCTAssertNil(weakReplacement)
        }
        let live = makeViewModel(using: harness)
        await live.synchronizeOwnership()

        let liveHandleCount = await harness.ownershipLedger.livePresentationHandleCountForTesting()
        await live.disconnect()

        XCTAssertEqual(liveHandleCount, 1)
        XCTAssertEqual(live.phase, .onboarding)
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
        let secondPause = Task { await harness.viewModel.pause() }
        await harness.viewModel.waitForOperationWaiterCount(.pause, count: 2)
        await harness.monitor.releasePause()
        await firstPause.value
        await secondPause.value
        let pauseCount = await harness.monitor.metrics().pause
        XCTAssertEqual(pauseCount, 1)

        await harness.monitor.blockResume()
        let firstResume = Task { await harness.viewModel.resume() }
        await harness.monitor.waitForResumeCount(1)
        let secondResume = Task { await harness.viewModel.resume() }
        await harness.viewModel.waitForOperationWaiterCount(.resume, count: 2)
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

        let resume = Task { await harness.viewModel.resume() }
        await harness.viewModel.waitForActionEntry(.resume, count: 1)
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
                verifier: harness.verifier,
                ownershipLedger: harness.ownershipLedger
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

    func testCanceledConnectCallerReturnsAndBlockedVerifierDoesNotRetainViewModel() async {
        let harness = ViewModelHarness()
        await harness.verifier.block(call: 1)
        var model: AppViewModel? = AppViewModel(
            credentials: harness.credentials,
            integrations: harness.integrations,
            monitor: harness.monitor,
            loginItem: harness.loginItem,
            verifier: harness.verifier,
            ownershipLedger: harness.ownershipLedger
        )
        weak var weakModel = model
        let call = Task { [weak model] in
            await model?.connect(using: harness.validDraft)
        }
        await harness.verifier.waitForVerifyCount(1)

        call.cancel()
        let returned = expectation(description: "canceled connect caller returns")
        Task {
            await call.value
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 1)
        model = nil

        XCTAssertNil(weakModel)
        await harness.verifier.release(call: 1)
    }

    func testPreCanceledConnectWaiterUnregistersAndCancelsZeroWaiterDriver() async {
        let harness = ViewModelHarness()
        await harness.verifier.block(call: 1)
        var model: AppViewModel? = makeViewModel(using: harness)
        weak var weakModel = model
        let call = Task { [weak model] in _ = await model?.connect(using: harness.validDraft) }
        call.cancel()

        await call.value
        await harness.verifier.waitForVerifyCount(1)
        await harness.verifier.waitForCancellationCount(1)
        model = nil

        XCTAssertNil(weakModel)
        await harness.verifier.release(call: 1)
    }

    func testCanceledApprovalCallerReturnsAndBlockedInstallerDoesNotRetainViewModel() async {
        let harness = ViewModelHarness()
        var model: AppViewModel? = makeViewModel(using: harness)
        await model?.connect(using: harness.validDraft)
        await harness.integrations.blockInstall()
        weak var weakModel = model
        let call = Task { [weak model] in _ = await model?.approveIntegrations() }
        await harness.integrations.waitForInstallCount(1)

        await cancelAndAwait(call, operation: "approval")
        model = nil

        XCTAssertNil(weakModel)
        await harness.integrations.releaseInstall()
    }

    func testBlockedMonitorStartDoesNotRetainViewModelAfterApprovalCallerCancellation() async {
        let harness = ViewModelHarness()
        var model: AppViewModel? = makeViewModel(using: harness)
        await model?.connect(using: harness.validDraft)
        await harness.monitor.blockStart()
        weak var weakModel = model
        let call = Task { [weak model] in _ = await model?.approveIntegrations() }
        await harness.monitor.waitForStartCount(1)

        await cancelAndAwait(call, operation: "approval blocked at monitor start")
        model = nil

        XCTAssertNil(weakModel)
        await harness.monitor.releaseStart()
        await harness.monitor.waitForStopCount(1)
        await harness.integrations.waitForUninstallCount(1)
    }

    func testApprovalCompensationCompletesFromLedgerAfterViewModelDeinit() async {
        let harness = ViewModelHarness()
        var model: AppViewModel? = makeViewModel(using: harness)
        await model?.connect(using: harness.validDraft)
        await harness.monitor.blockSnapshot()
        await harness.monitor.blockStop()
        weak var weakModel = model
        let call = Task { [weak model] in _ = await model?.approveIntegrations() }
        await harness.monitor.waitForSnapshotCount(1)

        await cancelAndAwait(call, operation: "approval compensation")
        model = nil
        await harness.monitor.releaseSnapshot()
        await harness.monitor.waitForStopCount(1)

        XCTAssertNil(weakModel)
        await harness.monitor.releaseStop()
        await harness.integrations.waitForUninstallCount(1)
        XCTAssertEqual(harness.credentials.deleteCount, 1)
        XCTAssertEqual(harness.loginItem.disableCount, 1)
    }

    func testCanceledApprovalCleanupFailurePresentsSanitizedRecoveryError() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.monitor.blockSnapshot()
        await harness.integrations.setUninstallError(HarnessSensitiveError("CANARY_UNINSTALL"))
        let approval = Task { await harness.viewModel.approveIntegrations() }
        await harness.monitor.waitForSnapshotCount(1)

        approval.cancel()
        await approval.value
        await harness.monitor.releaseSnapshot()
        await harness.viewModel.approveIntegrations()

        XCTAssertEqual(harness.viewModel.phase, .repairRequired)
        XCTAssertEqual(harness.viewModel.presentedError, .integrationConflict)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [.integrationUninstallRetry])
    }

    func testCanceledDisconnectAwaitingApprovalStillCleansLedgerAfterDeinit() async {
        let harness = ViewModelHarness()
        var model: AppViewModel? = makeViewModel(using: harness)
        await model?.connect(using: harness.validDraft)
        await harness.integrations.blockInstall()
        let approval = Task { [weak model] in _ = await model?.approveIntegrations() }
        await harness.integrations.waitForInstallCount(1)
        weak var weakModel = model
        let disconnect = Task { [weak model] in _ = await model?.disconnect() }
        await model?.waitForOperationWaiterCount(.disconnect, count: 1)

        await cancelAndAwait(disconnect, operation: "disconnect awaiting approval")
        model = nil
        await harness.integrations.releaseInstall()
        await harness.integrations.waitForUninstallCount(1)
        await approval.value

        XCTAssertNil(weakModel)
    }

    func testReplacementViewModelRehydratesSharedLedgerAndRetriesCleanup() async {
        let harness = ViewModelHarness()
        var first: AppViewModel? = makeViewModel(using: harness)
        await first?.connect(using: harness.validDraft)
        await first?.approveIntegrations()
        harness.credentials.setDeleteError(HarnessSensitiveError("CANARY_DELETE"))
        harness.loginItem.disableError = HarnessSensitiveError("CANARY_LOGIN")
        await harness.integrations.setUninstallError(
            IntegrationError.committedWithCleanupFailure(["CANARY_ARTIFACT"])
        )
        await first?.disconnect()
        first = nil

        let replacement = makeViewModel(using: harness)
        await replacement.synchronizeOwnership()

        XCTAssertEqual(replacement.phase, .repairRequired)
        XCTAssertEqual(
            replacement.outstandingObligations,
            [.credentialDelete, .loginRegistrationCleanup, .integrationArtifactCleanup]
        )

        harness.credentials.setDeleteError(nil)
        harness.loginItem.disableError = nil
        await harness.integrations.setUninstallError(nil)
        await harness.integrations.setArtifactVerification(clean: true)
        await replacement.disconnect()
        await replacement.repairIntegrations()

        XCTAssertEqual(replacement.outstandingObligations, [])
        XCTAssertEqual(replacement.phase, .onboarding)
    }

    func testReplacementViewModelRetriesOrdinaryIntegrationCleanupFromSharedLedger() async {
        let harness = ViewModelHarness()
        var first: AppViewModel? = makeViewModel(using: harness)
        await first?.connect(using: harness.validDraft)
        await first?.approveIntegrations()
        await harness.integrations.setUninstallError(HarnessSensitiveError("CANARY_UNINSTALL"))
        await first?.disconnect()
        first = nil

        let replacement = makeViewModel(using: harness)
        await replacement.synchronizeOwnership()
        XCTAssertEqual(replacement.outstandingObligations, [.integrationUninstallRetry])
        await harness.integrations.setUninstallError(nil)

        await replacement.disconnect()

        XCTAssertEqual(replacement.outstandingObligations, [])
        XCTAssertEqual(replacement.phase, .onboarding)
    }

    func testSynchronizeReconcilesStaleRepairPresentationAfterAnotherViewModelClearsLedger() async {
        let harness = ViewModelHarness()
        let owner = makeViewModel(using: harness)
        await owner.connect(using: harness.validDraft)
        await owner.approveIntegrations()
        await harness.integrations.setUninstallError(HarnessSensitiveError("CANARY_UNINSTALL"))
        await owner.disconnect()
        let stale = makeViewModel(using: harness)
        await stale.synchronizeOwnership()
        XCTAssertEqual(stale.phase, .repairRequired)

        await harness.integrations.setUninstallError(nil)
        let cleaner = makeViewModel(using: harness)
        await cleaner.synchronizeOwnership()
        await cleaner.repairIntegrations()
        await stale.synchronizeOwnership()

        XCTAssertEqual(stale.outstandingObligations, [])
        XCTAssertEqual(stale.phase, .onboarding)
        XCTAssertNil(stale.presentedError)
    }

    func testSequentialStaleRepairDoesNotFallBackToHealthRepair() async {
        let harness = ViewModelHarness()
        let owner = makeViewModel(using: harness)
        await owner.connect(using: harness.validDraft)
        await owner.approveIntegrations()
        await harness.integrations.setUninstallError(HarnessSensitiveError("CANARY_UNINSTALL"))
        await owner.disconnect()
        let stale = makeViewModel(using: harness)
        let cleaner = makeViewModel(using: harness)
        await stale.synchronizeOwnership()
        await cleaner.synchronizeOwnership()
        await harness.integrations.setUninstallError(nil)
        await cleaner.repairIntegrations()
        let countsBefore = await harness.integrations.counts()

        await stale.repairIntegrations()

        let countsAfter = await harness.integrations.counts()
        XCTAssertEqual(countsAfter.uninstall, countsBefore.uninstall)
        XCTAssertEqual(countsAfter.repair, countsBefore.repair)
        XCTAssertEqual(countsAfter.install, countsBefore.install)
        XCTAssertEqual(stale.outstandingObligations, [])
        XCTAssertEqual(stale.phase, .onboarding)
    }

    func testQueuedStaleRepairRechecksLedgerAndDoesNotFallBackToHealthRepair() async {
        let harness = ViewModelHarness()
        let owner = makeViewModel(using: harness)
        await owner.connect(using: harness.validDraft)
        await owner.approveIntegrations()
        await harness.integrations.setUninstallError(HarnessSensitiveError("CANARY_UNINSTALL"))
        await owner.disconnect()
        await harness.integrations.setUninstallError(nil)
        let first = makeViewModel(using: harness)
        let stale = makeViewModel(using: harness)
        await first.synchronizeOwnership()
        await stale.synchronizeOwnership()
        await harness.integrations.blockUninstall()
        let firstRepair = Task { await first.repairIntegrations() }
        await harness.integrations.waitForUninstallCount(2)

        let staleRepair = Task { await stale.repairIntegrations() }
        await stale.waitForActionEntry(.repair, count: 1)
        await harness.integrations.releaseUninstall()
        await firstRepair.value
        await staleRepair.value

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.uninstall, 2)
        XCTAssertEqual(counts.repair, 0)
        XCTAssertEqual(counts.install, 1)
        XCTAssertEqual(stale.outstandingObligations, [])
        XCTAssertEqual(stale.phase, .onboarding)
    }

    func testEveryActionRehydratesAPreviouslySynchronizedReplacement() async {
        let harness = ViewModelHarness()
        let owner = makeViewModel(using: harness)
        await owner.connect(using: harness.validDraft)
        await owner.approveIntegrations()
        let replacement = makeViewModel(using: harness)
        await replacement.synchronizeOwnership()
        await harness.integrations.setUninstallError(HarnessSensitiveError("CANARY_UNINSTALL"))
        await owner.disconnect()

        await replacement.connect(using: harness.validDraft)

        let verifyCount = await harness.verifier.count()
        XCTAssertEqual(verifyCount, 1)
        XCTAssertEqual(replacement.phase, .repairRequired)
        XCTAssertEqual(replacement.outstandingObligations, [.integrationUninstallRetry])
    }

    func testReplacementConnectWaitsForBlockedCleanupLeaseAndPreservesFinalObligation() async {
        let harness = ViewModelHarness()
        let owner = makeViewModel(using: harness)
        await owner.connect(using: harness.validDraft)
        await owner.approveIntegrations()
        let replacement = makeViewModel(using: harness)
        await replacement.synchronizeOwnership()
        await harness.integrations.setUninstallError(HarnessSensitiveError("CANARY_UNINSTALL"))
        await harness.integrations.blockUninstall()
        let cleanup = Task { await owner.disconnect() }
        await harness.integrations.waitForUninstallCount(1)

        let connect = Task { await replacement.connect(using: harness.validDraft) }
        await replacement.waitForActionEntry(.connect, count: 1)

        let blockedVerifyCount = await harness.verifier.count()
        let blockedUninstallCount = await harness.integrations.counts().uninstall
        XCTAssertEqual(blockedVerifyCount, 1)
        XCTAssertEqual(blockedUninstallCount, 1)
        await harness.integrations.releaseUninstall()
        await cleanup.value
        await connect.value

        let finalVerifyCount = await harness.verifier.count()
        let finalUninstallCount = await harness.integrations.counts().uninstall
        XCTAssertEqual(finalVerifyCount, 1)
        XCTAssertEqual(finalUninstallCount, 1)
        XCTAssertEqual(replacement.phase, .repairRequired)
        XCTAssertEqual(replacement.outstandingObligations, [.integrationUninstallRetry])
    }

    func testReplacementDisconnectJoinsBlockedCleanupWithoutRepeatingExternalCleanup() async {
        let harness = ViewModelHarness()
        let owner = makeViewModel(using: harness)
        await owner.connect(using: harness.validDraft)
        await owner.approveIntegrations()
        let replacement = makeViewModel(using: harness)
        await harness.integrations.blockUninstall()
        let ownerCleanup = Task { await owner.disconnect() }
        await harness.integrations.waitForUninstallCount(1)

        let replacementCleanup = Task { await replacement.disconnect() }
        await replacement.waitForActionEntry(.disconnect, count: 1)
        let blockedUninstallCount = await harness.integrations.counts().uninstall
        XCTAssertEqual(blockedUninstallCount, 1)
        await harness.integrations.releaseUninstall()
        await ownerCleanup.value
        await replacementCleanup.value

        let finalUninstallCount = await harness.integrations.counts().uninstall
        let monitorStopCount = await harness.monitor.metrics().stop
        XCTAssertEqual(finalUninstallCount, 1)
        XCTAssertEqual(harness.credentials.deleteCount, 1)
        XCTAssertEqual(harness.loginItem.disableCount, 1)
        XCTAssertEqual(monitorStopCount, 1)
        XCTAssertEqual(replacement.outstandingObligations, [])
        XCTAssertEqual(replacement.phase, .onboarding)
    }

    func testSynchronizeDuringLocalConnectCancelsAndPreventsStaleApply() async {
        let harness = ViewModelHarness()
        await harness.verifier.block(call: 1)
        let connect = Task { await harness.viewModel.connect(using: harness.validDraft) }
        await harness.verifier.waitForVerifyCount(1)

        let synchronization = Task { await harness.viewModel.synchronizeOwnership() }
        await harness.verifier.waitForCancellationCount(1)
        await harness.verifier.release(call: 1)
        await connect.value
        await synchronization.value

        XCTAssertEqual(harness.viewModel.phase, .onboarding)
        XCTAssertEqual(harness.viewModel.integrationPreviews, [])
        XCTAssertNil(harness.viewModel.presentedError)
    }

    func testSynchronizeDuringLocalApprovalWaitsForFinalTransactionWithoutStaleApply() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.integrations.blockInstall()
        let approval = Task { await harness.viewModel.approveIntegrations() }
        await harness.integrations.waitForInstallCount(1)

        let synchronization = Task { await harness.viewModel.synchronizeOwnership() }
        await harness.integrations.releaseInstall()
        await approval.value
        await synchronization.value

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.install, 1)
        XCTAssertEqual(harness.credentials.saveCount, 1)
        XCTAssertEqual(harness.viewModel.phase, .monitoring)
        XCTAssertEqual(harness.viewModel.outstandingObligations, [])
    }

    func testQueuedApprovalRevalidatesLedgerAfterAcquiringLease() async {
        let harness = ViewModelHarness()
        let first = makeViewModel(using: harness)
        let second = makeViewModel(using: harness)
        await first.connect(using: harness.validDraft)
        await second.connect(using: harness.validDraft)
        await harness.integrations.blockInstall()
        let firstApproval = Task { await first.approveIntegrations() }
        await harness.integrations.waitForInstallCount(1)
        let secondApproval = Task { await second.approveIntegrations() }
        await second.waitForActionEntry(.approval, count: 1)

        await harness.integrations.releaseInstall()
        await firstApproval.value
        await secondApproval.value

        let installCount = await harness.integrations.counts().install
        let monitorStartCount = await harness.monitor.metrics().start
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(harness.credentials.saveCount, 1)
        XCTAssertEqual(harness.loginItem.enableCount, 1)
        XCTAssertEqual(monitorStartCount, 1)
    }

    func testCanceledQueuedApprovalRemovesLeaseWaiterBeforeDurableDisconnect() async {
        let harness = ViewModelHarness()
        let model = makeViewModel(using: harness)
        let cleanupModel = makeViewModel(using: harness)
        await model.connect(using: harness.validDraft)
        let token = await harness.ownershipLedger.acquireDurableLeaseForTesting()
        let approval = Task { await model.approveIntegrations() }
        await harness.ownershipLedger.waitForLeaseWaiterCount(1)
        let disconnect = Task { await cleanupModel.disconnect() }
        await harness.ownershipLedger.waitForLeaseWaiterCount(2)

        await cancelAndAwait(approval, operation: "queued approval")
        await harness.ownershipLedger.waitForLeaseWaiterCount(1)
        await harness.ownershipLedger.releaseLeaseForTesting(token)
        await disconnect.value

        let counts = await harness.integrations.counts()
        let waiterCount = await harness.ownershipLedger.leaseWaiterCountForTesting()
        XCTAssertEqual(counts.install, 0)
        XCTAssertEqual(harness.credentials.saveCount, 0)
        XCTAssertEqual(waiterCount, 0)
    }

    func testCanceledQueuedRepairRemovesLeaseWaiterBeforeDurableDisconnect() async {
        let harness = ViewModelHarness()
        let owner = makeViewModel(using: harness)
        await owner.connect(using: harness.validDraft)
        await owner.approveIntegrations()
        await harness.integrations.setUninstallError(HarnessSensitiveError("CANARY_UNINSTALL"))
        await owner.disconnect()
        await harness.integrations.setUninstallError(nil)
        let repairModel = makeViewModel(using: harness)
        let cleanupModel = makeViewModel(using: harness)
        await repairModel.synchronizeOwnership()
        let token = await harness.ownershipLedger.acquireDurableLeaseForTesting()
        let repair = Task { await repairModel.repairIntegrations() }
        await harness.ownershipLedger.waitForLeaseWaiterCount(1)
        let cleanup = Task { await cleanupModel.disconnect() }
        await harness.ownershipLedger.waitForLeaseWaiterCount(2)

        await cancelAndAwait(repair, operation: "queued repair")
        await harness.ownershipLedger.waitForLeaseWaiterCount(1)
        await harness.ownershipLedger.releaseLeaseForTesting(token)
        await cleanup.value

        let counts = await harness.integrations.counts()
        let waiterCount = await harness.ownershipLedger.leaseWaiterCountForTesting()
        XCTAssertEqual(counts.uninstall, 2)
        XCTAssertEqual(counts.repair, 0)
        XCTAssertEqual(waiterCount, 0)
    }

    func testCanceledApprovalAtLeaseGrantMakesNoDependencyCallsAndYieldsToDisconnect() async {
        let harness = ViewModelHarness()
        let model = makeViewModel(using: harness)
        let cleanupModel = makeViewModel(using: harness)
        await model.connect(using: harness.validDraft)
        let token = await harness.ownershipLedger.acquireDurableLeaseForTesting()
        let approval = Task { await model.approveIntegrations() }
        await harness.ownershipLedger.waitForLeaseWaiterCount(1)
        let cleanup = Task { await cleanupModel.disconnect() }
        await harness.ownershipLedger.waitForLeaseWaiterCount(2)
        await harness.ownershipLedger.blockNextCancellableLeaseAcquisitionReturnForTesting()

        await harness.ownershipLedger.releaseLeaseForTesting(token)
        await harness.ownershipLedger.waitForBlockedCancellableLeaseAcquisitionForTesting()
        approval.cancel()
        await harness.ownershipLedger.resumeBlockedCancellableLeaseAcquisitionForTesting()
        await approval.value
        await cleanup.value

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.install, 0)
        XCTAssertEqual(harness.credentials.saveCount, 0)
    }

    func testCanceledRepairAtLeaseGrantMakesNoDependencyCallsAndYieldsToDisconnect() async {
        let harness = ViewModelHarness()
        let owner = makeViewModel(using: harness)
        await owner.connect(using: harness.validDraft)
        await owner.approveIntegrations()
        await harness.integrations.setUninstallError(HarnessSensitiveError("CANARY_UNINSTALL"))
        await owner.disconnect()
        await harness.integrations.setUninstallError(nil)
        let repairModel = makeViewModel(using: harness)
        let cleanupModel = makeViewModel(using: harness)
        await repairModel.synchronizeOwnership()
        let token = await harness.ownershipLedger.acquireDurableLeaseForTesting()
        let repair = Task { await repairModel.repairIntegrations() }
        await harness.ownershipLedger.waitForLeaseWaiterCount(1)
        let cleanup = Task { await cleanupModel.disconnect() }
        await harness.ownershipLedger.waitForLeaseWaiterCount(2)
        await harness.ownershipLedger.blockNextCancellableLeaseAcquisitionReturnForTesting()

        await harness.ownershipLedger.releaseLeaseForTesting(token)
        await harness.ownershipLedger.waitForBlockedCancellableLeaseAcquisitionForTesting()
        repair.cancel()
        await harness.ownershipLedger.resumeBlockedCancellableLeaseAcquisitionForTesting()
        await repair.value
        await cleanup.value

        let counts = await harness.integrations.counts()
        XCTAssertEqual(counts.uninstall, 2)
        XCTAssertEqual(counts.repair, 0)
    }

    func testApprovalCommitsMonitoringPresentationBeforeReleasingLease() async {
        let harness = ViewModelHarness()
        let model = makeViewModel(using: harness)
        await model.connect(using: harness.validDraft)
        await harness.integrations.blockInstall()
        let approval = Task { await model.approveIntegrations() }
        await harness.integrations.waitForInstallCount(1)
        let observedPhase = Task { @MainActor in
            let token = await harness.ownershipLedger.acquireDurableLeaseForTesting()
            let phase = model.phase
            await harness.ownershipLedger.releaseLeaseForTesting(token)
            return phase
        }
        await harness.ownershipLedger.waitForLeaseWaiterCount(1)
        await harness.ownershipLedger.blockNextLeaseReleaseReturnForTesting()

        await harness.integrations.releaseInstall()
        await harness.ownershipLedger.waitForBlockedLeaseReleaseForTesting()
        let phase = await observedPhase.value
        await harness.ownershipLedger.resumeBlockedLeaseReleaseForTesting()
        await approval.value
        XCTAssertEqual(phase, .monitoring)
    }

    func testRepairCommitsOnboardingPresentationBeforeReleasingLease() async {
        let harness = ViewModelHarness()
        let owner = makeViewModel(using: harness)
        await owner.connect(using: harness.validDraft)
        await owner.approveIntegrations()
        await harness.integrations.setUninstallError(HarnessSensitiveError("CANARY_UNINSTALL"))
        await owner.disconnect()
        await harness.integrations.setUninstallError(nil)
        let model = makeViewModel(using: harness)
        await model.synchronizeOwnership()
        await harness.integrations.blockUninstall()
        let repair = Task { await model.repairIntegrations() }
        await harness.integrations.waitForUninstallCount(2)
        let observedPhase = Task { @MainActor in
            let token = await harness.ownershipLedger.acquireDurableLeaseForTesting()
            let phase = model.phase
            await harness.ownershipLedger.releaseLeaseForTesting(token)
            return phase
        }
        await harness.ownershipLedger.waitForLeaseWaiterCount(1)
        await harness.ownershipLedger.blockNextLeaseReleaseReturnForTesting()

        await harness.integrations.releaseUninstall()
        await harness.ownershipLedger.waitForBlockedLeaseReleaseForTesting()
        let phase = await observedPhase.value
        await harness.ownershipLedger.resumeBlockedLeaseReleaseForTesting()
        await repair.value
        XCTAssertEqual(phase, .onboarding)
    }

    func testDisconnectCommitsOnboardingPresentationBeforeReleasingLease() async {
        let harness = ViewModelHarness()
        let model = makeViewModel(using: harness)
        await model.connect(using: harness.validDraft)
        await model.approveIntegrations()
        await harness.integrations.blockUninstall()
        let disconnect = Task { await model.disconnect() }
        await harness.integrations.waitForUninstallCount(1)
        let observedPhase = Task { @MainActor in
            let token = await harness.ownershipLedger.acquireDurableLeaseForTesting()
            let phase = model.phase
            await harness.ownershipLedger.releaseLeaseForTesting(token)
            return phase
        }
        await harness.ownershipLedger.waitForLeaseWaiterCount(1)
        await harness.ownershipLedger.blockNextLeaseReleaseReturnForTesting()

        await harness.integrations.releaseUninstall()
        await harness.ownershipLedger.waitForBlockedLeaseReleaseForTesting()
        let phase = await observedPhase.value
        await harness.ownershipLedger.resumeBlockedLeaseReleaseForTesting()
        await disconnect.value
        XCTAssertEqual(phase, .onboarding)
    }

    func testReplacementDisconnectReconcilesEarlierApprovingViewModelAfterCleanup() async {
        let harness = ViewModelHarness()
        let approvingModel = makeViewModel(using: harness)
        let replacement = makeViewModel(using: harness)
        await approvingModel.connect(using: harness.validDraft)
        await harness.integrations.blockInstall()
        let approval = Task { await approvingModel.approveIntegrations() }
        await harness.integrations.waitForInstallCount(1)
        let cleanup = Task { await replacement.disconnect() }
        await harness.ownershipLedger.waitForLeaseWaiterCount(1)

        await harness.integrations.releaseInstall()
        await approval.value
        await cleanup.value

        XCTAssertEqual(approvingModel.phase, .onboarding)
        XCTAssertEqual(approvingModel.connectionStatus, .disconnected)
        XCTAssertEqual(approvingModel.outstandingObligations, [])
    }

    func testCanceledPauseCallerReturnsAndBlockedMonitorDoesNotRetainViewModel() async {
        let harness = ViewModelHarness()
        var model: AppViewModel? = makeViewModel(using: harness)
        await model?.connect(using: harness.validDraft)
        await model?.approveIntegrations()
        await harness.monitor.blockPause()
        weak var weakModel = model
        let call = Task { [weak model] in _ = await model?.pause() }
        await harness.monitor.waitForPauseCount(1)

        await cancelAndAwait(call, operation: "pause")
        model = nil

        XCTAssertNil(weakModel)
        await harness.monitor.releasePause()
    }

    func testCanceledPauseWithFailedResumeCommitsSafePausedState() async {
        let harness = ViewModelHarness()
        await harness.connectAndApprove()
        await harness.monitor.blockPause()
        await harness.monitor.setResumeError(TuyaClientError.transport)
        let call = Task { await harness.viewModel.pause() }
        await harness.monitor.waitForPauseCount(1)

        await cancelAndAwait(call, operation: "pause with failed cancellation compensation")
        await harness.monitor.releasePause()
        await harness.monitor.waitForResumeCount(1)
        await harness.viewModel.pause()

        XCTAssertEqual(harness.viewModel.phase, .paused)
        XCTAssertEqual(harness.viewModel.currentState, .idle)
        XCTAssertEqual(harness.viewModel.presentedError, .bulbOffline)
    }

    func testCanceledResumeCallerReturnsAndBlockedMonitorDoesNotRetainViewModel() async {
        let harness = ViewModelHarness()
        var model: AppViewModel? = makeViewModel(using: harness)
        await model?.connect(using: harness.validDraft)
        await model?.approveIntegrations()
        await model?.pause()
        await harness.monitor.blockResume()
        weak var weakModel = model
        let call = Task { [weak model] in _ = await model?.resume() }
        await harness.monitor.waitForResumeCount(1)

        await cancelAndAwait(call, operation: "resume")
        model = nil

        XCTAssertNil(weakModel)
        await harness.monitor.releaseResume()
    }

    func testCanceledRepairCallerReturnsAndBlockedInstallerDoesNotRetainViewModel() async {
        let harness = ViewModelHarness()
        var model: AppViewModel? = makeViewModel(using: harness)
        await model?.connect(using: harness.validDraft)
        await model?.approveIntegrations()
        await harness.integrations.blockRepair()
        weak var weakModel = model
        let call = Task { [weak model] in _ = await model?.repairIntegrations() }
        await harness.integrations.waitForRepairCount(1)

        await cancelAndAwait(call, operation: "repair")
        model = nil

        XCTAssertNil(weakModel)
        await harness.integrations.releaseRepair()
    }

    func testCanceledDisconnectCallerReturnsAndBlockedCleanupDoesNotRetainViewModel() async {
        let harness = ViewModelHarness()
        var model: AppViewModel? = makeViewModel(using: harness)
        await model?.connect(using: harness.validDraft)
        await model?.approveIntegrations()
        await harness.integrations.blockUninstall()
        weak var weakModel = model
        let call = Task { [weak model] in _ = await model?.disconnect() }
        await harness.integrations.waitForUninstallCount(1)

        await cancelAndAwait(call, operation: "disconnect")
        model = nil

        XCTAssertNil(weakModel)
        await harness.integrations.releaseUninstall()
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
        let second = Task { await harness.viewModel.repairIntegrations() }
        await harness.viewModel.waitForOperationWaiterCount(.repair, count: 2)
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
        let second = Task { await harness.viewModel.disconnect() }
        await harness.viewModel.waitForOperationWaiterCount(.disconnect, count: 2)
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

    func testHTTP401MapsDirectlyToInvalidCredential() async {
        let harness = ViewModelHarness()
        await harness.verifier.setError(TuyaClientError.httpStatus(401), forCall: 1)

        await harness.viewModel.connect(using: harness.validDraft)

        XCTAssertEqual(harness.viewModel.presentedError, .invalidCredential)
    }

    func testHTTP403MapsDirectlyToInvalidCredential() async {
        let harness = ViewModelHarness()
        await harness.verifier.setError(TuyaClientError.httpStatus(403), forCall: 1)

        await harness.viewModel.connect(using: harness.validDraft)

        XCTAssertEqual(harness.viewModel.presentedError, .invalidCredential)
    }

    private func makeViewModel(using harness: ViewModelHarness) -> AppViewModel {
        AppViewModel(
            credentials: harness.credentials,
            integrations: harness.integrations,
            monitor: harness.monitor,
            loginItem: harness.loginItem,
            verifier: harness.verifier,
            ownershipLedger: harness.ownershipLedger
        )
    }

    private func cancelAndAwait(_ task: Task<Void, Never>, operation: String) async {
        task.cancel()
        let returned = expectation(description: "canceled \(operation) caller returns")
        Task {
            await task.value
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 1)
    }

}

@MainActor
private final class LegacyAppViewModelConformer: AppViewModeling {
    let phase: AppPhase = .onboarding
    let connectionStatus: LightConnectionStatus = .disconnected
    let currentState: AgentState = .idle
    let sessions: [AgentEvent] = []
    let integrationPreviews: [IntegrationPreview] = []
    let presentedError: PresentationError? = nil
    let outstandingObligations: Set<OutstandingObligation> = []

    func connect(using draft: ConnectionDraft) async {}
    func approveIntegrations() async {}
    func pause() async {}
    func resume() async {}
    func repairIntegrations() async {}
    func disconnect() async {}
    func observeMonitoring() async {}
}
