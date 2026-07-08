import Darwin
import Foundation
import XCTest
import AppKit
import SwiftUI
import AgentLightCore
import AgentLightProtocol
import AgentLightUI
@testable import AgentLightApp

@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testStartupLoadingAndFailureRenderAtIntrinsicMenuWidthAndInvokeButtons() throws {
        let loading = NSHostingView(rootView: StartupStatusView(status: .loading, retry: {}, quit: {}))
        loading.layoutSubtreeIfNeeded()
        XCTAssertEqual(loading.fittingSize.width, 380, accuracy: 1)
        XCTAssertGreaterThan(loading.fittingSize.height, 200)

        var retryCount = 0
        var quitCount = 0
        let failure = NSHostingView(rootView: StartupStatusView(
            status: .failed,
            retry: { retryCount += 1 },
            quit: { quitCount += 1 }
        ))
        failure.layoutSubtreeIfNeeded()
        try appButton("app.startup.retry", in: failure).performClick(nil)
        try appButton("app.startup.quit", in: failure).performClick(nil)
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(quitCount, 1)

        let resetFailure = NSHostingView(rootView: StartupStatusView(
            status: .credentialResetFailed,
            retry: { retryCount += 1 },
            quit: {}
        ))
        resetFailure.layoutSubtreeIfNeeded()
        let reset = try appButton("app.startup.retry", in: resetFailure)
        XCTAssertEqual(reset.title, "Reset Stored Credentials & Retry")
        reset.performClick(nil)
        XCTAssertEqual(retryCount, 2)
    }

    func testProductionVerifierResolvesCapabilityWithoutSendingCommands() async throws {
        let service = VerifierService()
        let verifier = ProductionTuyaConnectionVerifier { credentials in
            XCTAssertEqual(credentials.accessID, "CANARY_ACCESS_ID")
            return service
        }
        let credentials = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyaus.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )

        let capabilities = try await verifier.verify(credentials)
        let sendCount = await service.sendCount()

        XCTAssertEqual(capabilities.powerCode, "switch_led")
        XCTAssertEqual(sendCount, 0)
    }

    func testProductionCompositionStartsLoadingWithoutExternalMutation() {
        let composition = ProductionAppComposition.make()

        XCTAssertEqual(composition.environment.status, .loading)
        XCTAssertEqual(composition.viewModel.phase, .onboarding)
    }

    func testApplicationLaunchStartsWithoutMenuPresentationAndCannotStartTwice() {
        var starts = 0
        let launch = ApplicationLaunchController {
            starts += 1
        }

        XCTAssertEqual(starts, 1)

        launch.startIfNeeded()

        XCTAssertEqual(starts, 1)
    }

    func testApplicationSupportPreparationRejectsSymlinkAndNonprivateExistingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agent-light-app-support-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        let linked = root.appending(path: "linked", directoryHint: .isDirectory)
        XCTAssertEqual(symlink(target.path, linked.path), 0)

        do {
            try await ProductionAppComposition.prepareApplicationSupport(at: linked)
            XCTFail("Expected symlink rejection")
        } catch {}
        var linkedMetadata = stat()
        XCTAssertEqual(lstat(linked.path, &linkedMetadata), 0)
        XCTAssertEqual(linkedMetadata.st_mode & S_IFMT, S_IFLNK)

        let nonprivate = root.appending(path: "nonprivate", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nonprivate, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nonprivate.path)
        do {
            try await ProductionAppComposition.prepareApplicationSupport(at: nonprivate)
            XCTFail("Expected nonprivate directory rejection")
        } catch {}
        let attributes = try FileManager.default.attributesOfItem(atPath: nonprivate.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testApplicationSupportPreparationCreatesAndValidatesPrivateDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agent-light-app-support-create-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appending(path: "private", directoryHint: .isDirectory)

        try await ProductionAppComposition.prepareApplicationSupport(at: directory)
        try await ProductionAppComposition.prepareApplicationSupport(at: directory)

        var metadata = stat()
        XCTAssertEqual(lstat(directory.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(metadata.st_mode & mode_t(0o7777), mode_t(0o700))
        XCTAssertEqual(metadata.st_uid, geteuid())
    }

    func testRecoveryFinishesBeforeCredentialsLoadAndRelayAcceptance() async {
        let recorder = EnvironmentRecorder()
        let monitor = EnvironmentMonitor(recorder: recorder)
        await monitor.blockRecovery()
        let relay = EnvironmentRelay(recorder: recorder)
        let coordinator = EnvironmentCoordinator(recorder: recorder)
        let credentials = EnvironmentCredentials(recorder: recorder, stored: nil)
        let viewModel = EnvironmentViewModel(recorder: recorder)
        let environment = AppEnvironment(
            viewModel: viewModel,
            credentials: credentials,
            monitor: monitor,
            relay: relay,
            coordinator: coordinator,
            prepareStorage: { recorder.append(.prepare) }
        )

        let startup = Task { await environment.start() }
        await monitor.waitForRecovery()
        let relayStartsBeforeRecovery = await relay.count()
        let acceptedBeforeRecovery = await coordinator.count()
        XCTAssertEqual(relayStartsBeforeRecovery, 0)
        XCTAssertEqual(acceptedBeforeRecovery, 0)

        await monitor.releaseRecovery()
        await startup.value
        await relay.deliver(Data("CANARY_RELAY".utf8))

        XCTAssertEqual(
            recorder.values,
            [.prepare, .recover, .synchronize, .loadCredentials, .relayStart, .relayAccept]
        )
    }

    func testStoredCredentialsWithoutDurableOwnershipStopAtIntegrationReview() async throws {
        let recorder = EnvironmentRecorder()
        let stored = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyaus.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )
        let viewModel = EnvironmentViewModel(recorder: recorder)
        let environment = AppEnvironment(
            viewModel: viewModel,
            credentials: EnvironmentCredentials(recorder: recorder, stored: stored),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: EnvironmentRelay(recorder: recorder),
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: { recorder.append(.prepare) }
        )

        await environment.start()

        XCTAssertEqual(
            recorder.values,
            [.prepare, .recover, .synchronize, .loadCredentials, .connect, .relayStart]
        )
        XCTAssertEqual(viewModel.phase, .integrationReview)
        XCTAssertFalse(recorder.values.contains(.approve))
        XCTAssertEqual(viewModel.lastDraft?.accessSecret, "CANARY_ACCESS_SECRET")
    }

    func testStoredCredentialsWithoutReceiptNeverInstallHooksOrRegisterLogin() async throws {
        let fixture = try PathLifecycleFixture(seededSetup: false)
        let environment = fixture.makeEnvironment()

        await environment.start()

        let metrics = await fixture.metrics()
        XCTAssertEqual(metrics.credentialSaves, 0)
        XCTAssertEqual(metrics.integrationInstalls, 0)
        XCTAssertEqual(metrics.loginRegisters, 0)
        XCTAssertEqual(fixture.viewModel.phase, .integrationReview)
        let receipt = try await fixture.receiptStore.load()
        XCTAssertNil(receipt)
    }

    func testStopClosesRelayBeforeNonDestructiveMonitoringShutdown() async {
        let recorder = EnvironmentRecorder()
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: EnvironmentRelay(recorder: recorder),
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )

        await environment.stop()

        XCTAssertEqual(recorder.values, [.relayStop, .shutdownMonitoring])
    }

    func testQuitStopsNonDestructivelyBeforeInjectedApplicationTermination() async {
        let recorder = EnvironmentRecorder()
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: EnvironmentRelay(recorder: recorder),
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {},
            terminateApplication: { recorder.append(.terminate) }
        )

        environment.requestQuit()
        await spinMainActor(until: { recorder.values.contains(.terminate) })

        XCTAssertEqual(recorder.values, [.relayStop, .shutdownMonitoring, .terminate])
    }

    func testRelayStartupFailureCleansHydratedMonitoringOwnership() async throws {
        let recorder = EnvironmentRecorder()
        let stored = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyaus.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )
        let relay = EnvironmentRelay(recorder: recorder)
        await relay.failStart()
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: stored),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )

        await environment.start()

        XCTAssertEqual(environment.status, .failed)
        XCTAssertEqual(Array(recorder.values.suffix(2)), [.relayStop, .shutdownMonitoring])
    }

    func testStopCancelsOwnedStartupBeforeRelayCanAcceptEvents() async {
        let recorder = EnvironmentRecorder()
        let monitor = EnvironmentMonitor(recorder: recorder)
        await monitor.blockRecovery()
        let relay = EnvironmentRelay(recorder: recorder)
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: monitor,
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        environment.requestStart()
        await monitor.waitForRecovery()

        let stopping = Task { await environment.stop() }
        await monitor.releaseRecovery()
        await stopping.value
        let relayStarts = await relay.count()

        XCTAssertEqual(relayStarts, 0)
        XCTAssertFalse(recorder.values.contains(.relayStart))
    }

    func testStopClaimsShutdownBeforeCancelingBlockedApproval() async throws {
        let recorder = EnvironmentRecorder()
        let viewModel = EnvironmentViewModel(
            recorder: recorder,
            automaticSetupResumeAuthorized: true
        )
        await viewModel.blockApproval()
        let stored = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyain.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )
        let environment = AppEnvironment(
            viewModel: viewModel,
            credentials: EnvironmentCredentials(recorder: recorder, stored: stored),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: EnvironmentRelay(recorder: recorder),
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        environment.requestStart()
        await viewModel.waitForApproval()

        let stopping = Task { await environment.stop() }
        await spinMainActor(until: { recorder.values.contains(.shutdownMonitoring) })

        XCTAssertTrue(recorder.values.contains(.relayStop))
        XCTAssertTrue(recorder.values.contains(.shutdownMonitoring))
        await viewModel.releaseApproval()
        await stopping.value
        XCTAssertFalse(recorder.values.contains(.disconnect))
        XCTAssertFalse(recorder.values.contains(.relayStart))
    }

    func testStopAdvancesShutdownBeforeApprovalMethodEntry() async throws {
        let recorder = EnvironmentRecorder()
        let approvalEntryGate = EnvironmentGate()
        await approvalEntryGate.block()
        let viewModel = EnvironmentViewModel(
            recorder: recorder,
            automaticSetupResumeAuthorized: true
        )
        let stored = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyain.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )
        let environment = AppEnvironment(
            viewModel: viewModel,
            credentials: EnvironmentCredentials(recorder: recorder, stored: stored),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: EnvironmentRelay(recorder: recorder),
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {},
            beforeApproval: { await approvalEntryGate.enter() }
        )
        environment.requestStart()
        await approvalEntryGate.waitForEntry()

        let stopping = Task { await environment.stop() }
        await viewModel.waitForShutdownMonitoring()

        XCTAssertFalse(recorder.values.contains(.approve))
        await approvalEntryGate.release()
        await stopping.value
        XCTAssertFalse(recorder.values.contains(.relayStart))
    }

    func testStopDisarmsRelayBeforeStartOwnershipRegistration() async {
        let recorder = EnvironmentRecorder()
        let relayStartEntryGate = EnvironmentGate()
        await relayStartEntryGate.block()
        let relay = EnvironmentRelay(recorder: recorder)
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {},
            beforeRelayStart: { await relayStartEntryGate.enter() }
        )
        environment.requestStart()
        await relayStartEntryGate.waitForEntry()

        let stopping = Task {
            await environment.stop()
            recorder.append(.environmentStopComplete)
        }
        await spinMainActor(until: { recorder.values.contains(.environmentStopComplete) })

        let startsBeforeRelease = await relay.count()
        let activeBeforeRelease = await relay.active()
        XCTAssertTrue(recorder.values.contains(.environmentStopComplete))
        XCTAssertEqual(startsBeforeRelease, 0)
        XCTAssertFalse(activeBeforeRelease)

        await relayStartEntryGate.release()
        await stopping.value
        await spinMainActor()

        let finalStartCount = await relay.count()
        let isFinallyActive = await relay.active()
        XCTAssertEqual(finalStartCount, 0)
        XCTAssertFalse(isFinallyActive)
    }

    func testStopWaitsForRegisteredRelayStartThenStopsIt() async {
        let recorder = EnvironmentRecorder()
        let relay = EnvironmentRelay(recorder: recorder)
        await relay.blockStart()
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        environment.requestStart()
        await relay.waitForStart()

        let stopping = Task {
            await environment.stop()
            recorder.append(.environmentStopComplete)
        }
        await spinMainActor()

        XCTAssertFalse(recorder.values.contains(.relayStop))
        XCTAssertFalse(recorder.values.contains(.environmentStopComplete))

        await relay.releaseStart()
        await stopping.value

        let calls = recorder.values
        let startIndex = calls.firstIndex(of: .relayStart)
        let stopIndex = calls.firstIndex(of: .relayStop)
        XCTAssertNotNil(startIndex)
        XCTAssertNotNil(stopIndex)
        if let startIndex, let stopIndex {
            XCTAssertLessThan(startIndex, stopIndex)
        }
        let startCount = await relay.count()
        let stopCount = await relay.stopCount()
        let isActive = await relay.active()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(isActive)
    }

    func testConcurrentRetryRequestsShareOneOwnedRecoveryAndRelayStart() async {
        let recorder = EnvironmentRecorder()
        let monitor = EnvironmentMonitor(recorder: recorder)
        await monitor.blockRecovery()
        let relay = EnvironmentRelay(recorder: recorder)
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: monitor,
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )

        environment.requestStart()
        environment.requestStart()
        await monitor.waitForRecovery()
        let recoveriesWhileBlocked = await monitor.recoveryCount()
        XCTAssertEqual(recoveriesWhileBlocked, 1)

        await monitor.releaseRecovery()
        await environment.start()
        let finalRecoveries = await monitor.recoveryCount()
        let finalRelayStarts = await relay.count()
        XCTAssertEqual(finalRecoveries, 1)
        XCTAssertEqual(finalRelayStarts, 1)
    }

    func testEnvironmentDeinitCancelsBlockedRecoveryWithoutLaterRelayStart() async {
        let recorder = EnvironmentRecorder()
        let monitor = EnvironmentMonitor(recorder: recorder)
        await monitor.blockRecovery()
        let relay = EnvironmentRelay(recorder: recorder)
        weak var weakEnvironment: AppEnvironment?
        var environment: AppEnvironment? = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: monitor,
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        weakEnvironment = environment
        environment?.requestStart()
        await monitor.waitForRecovery()

        environment = nil
        XCTAssertNil(weakEnvironment)
        await monitor.releaseRecovery()
        await monitor.waitForRecoveryCancellation()
        let relayStarts = await relay.count()

        XCTAssertEqual(relayStarts, 0)
    }

    func testStartCanRetryAfterOneShotFailure() async {
        let recorder = EnvironmentRecorder()
        let monitor = EnvironmentMonitor(recorder: recorder)
        let relay = EnvironmentRelay(recorder: recorder)
        await relay.failNextStart()
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: monitor,
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )

        await environment.start()
        XCTAssertEqual(environment.status, .failed)
        await environment.start()

        let recoveryCount = await monitor.recoveryCount()
        let relayCount = await relay.count()
        XCTAssertEqual(environment.status, .ready)
        XCTAssertEqual(recoveryCount, 2)
        XCTAssertEqual(relayCount, 2)
    }

    func testStartRequestedDuringBlockedStartupStopQueuesAfterCleanup() async {
        let recorder = EnvironmentRecorder()
        let monitor = EnvironmentMonitor(recorder: recorder)
        await monitor.blockRecovery()
        let relay = EnvironmentRelay(recorder: recorder)
        await relay.blockStop()
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: monitor,
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        environment.requestStart()
        await monitor.waitForRecovery()

        let stopping = Task { await environment.stop() }
        await monitor.releaseRecovery()
        await relay.waitForStop()
        environment.requestStart()
        await spinMainActor()

        let blockedRecoveryCount = await monitor.recoveryCount()
        let blockedRelayCount = await relay.count()
        XCTAssertEqual(blockedRecoveryCount, 1)
        XCTAssertEqual(blockedRelayCount, 0)

        await relay.releaseStop()
        await stopping.value
        await spinMainActor(until: { environment.status == .ready })

        XCTAssertEqual(environment.status, .ready)
        let finalRecoveryCount = await monitor.recoveryCount()
        let finalRelayCount = await relay.count()
        XCTAssertEqual(finalRecoveryCount, 2)
        XCTAssertEqual(finalRelayCount, 1)
    }

    func testStartRequestedDuringReadyStopRunsOnceAfterCleanup() async {
        let recorder = EnvironmentRecorder()
        let relay = EnvironmentRelay(recorder: recorder)
        await relay.blockStop()
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        await environment.start()

        let stopping = Task { await environment.stop() }
        await relay.waitForStop()
        environment.requestStart()
        environment.requestStart()
        let blockedRelayCount = await relay.count()
        XCTAssertEqual(blockedRelayCount, 1)

        await relay.releaseStop()
        await stopping.value
        await spinMainActor(until: { environment.status == .ready })

        XCTAssertEqual(environment.status, .ready)
        let finalRelayCount = await relay.count()
        XCTAssertEqual(finalRelayCount, 2)
    }

    func testQueuedRestartWaitsForShutdownThenReusesExistingSetup() async throws {
        let recorder = EnvironmentRecorder()
        let relay = EnvironmentRelay(recorder: recorder)
        let stored = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyain.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: stored),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        await environment.start()
        recorder.removeAll()
        await relay.blockStop()

        let stopping = Task { await environment.stop() }
        await relay.waitForStop()
        environment.requestStart()
        await Task.yield()
        XCTAssertEqual(recorder.values, [.relayStop])

        await relay.releaseStop()
        await stopping.value
        await spinMainActor(until: { environment.status == .ready })

        XCTAssertEqual(
            recorder.values,
            [.relayStop, .shutdownMonitoring, .recover, .synchronize, .loadCredentials, .relayStart]
        )
        XCTAssertFalse(recorder.values.contains(.connect))
        XCTAssertFalse(recorder.values.contains(.approve))
    }

    func testReadyEnvironmentDeinitRunsDependencyOwnedShutdownExactlyOnce() async throws {
        let recorder = EnvironmentRecorder()
        let relay = EnvironmentRelay(recorder: recorder)
        await relay.blockStop()
        let viewModel = EnvironmentViewModel(recorder: recorder)
        await viewModel.blockShutdownMonitoring()
        let stored = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyain.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )
        weak var weakEnvironment: AppEnvironment?
        var environment: AppEnvironment? = AppEnvironment(
            viewModel: viewModel,
            credentials: EnvironmentCredentials(recorder: recorder, stored: stored),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        weakEnvironment = environment
        await environment?.start()

        environment = nil
        XCTAssertNil(weakEnvironment)
        await spinMainActor(until: { recorder.values.contains(.relayStop) })
        let relayStopCount = recorder.values.filter { $0 == .relayStop }.count
        XCTAssertEqual(relayStopCount, 1)
        XCTAssertFalse(recorder.values.contains(.shutdownMonitoring))
        guard relayStopCount == 1 else { return }

        await relay.releaseStop()
        await spinMainActor(until: { recorder.values.contains(.shutdownMonitoring) })
        let shutdownCount = recorder.values.filter { $0 == .shutdownMonitoring }.count
        XCTAssertEqual(shutdownCount, 1)
        guard shutdownCount == 1 else { return }
        await viewModel.releaseShutdownMonitoring()
        await spinMainActor()
        XCTAssertEqual(recorder.values.filter { $0 == .relayStop }.count, 1)
        XCTAssertEqual(recorder.values.filter { $0 == .shutdownMonitoring }.count, 1)
        XCTAssertFalse(recorder.values.contains(.disconnect))
    }

    func testMalformedAndLegacyCredentialsAreDeletedBeforeRelayStarts() async {
        for fixture in ["legacy arbitrary endpoint JSON", "malformed bytes"] {
            let recorder = EnvironmentRecorder()
            let credentials = EnvironmentCredentials(
                recorder: recorder,
                stored: nil,
                malformed: true
            )
            let relay = EnvironmentRelay(recorder: recorder)
            let viewModel = EnvironmentViewModel(recorder: recorder)
            let environment = AppEnvironment(
                viewModel: viewModel,
                credentials: credentials,
                monitor: EnvironmentMonitor(recorder: recorder),
                relay: relay,
                coordinator: EnvironmentCoordinator(recorder: recorder),
                prepareStorage: {}
            )

            await environment.start()

            XCTAssertEqual(environment.status, .ready, fixture)
            XCTAssertEqual(viewModel.phase, .onboarding, fixture)
            XCTAssertEqual(recorder.values.filter { $0 == .deleteCredentials }.count, 1, fixture)
            let relayCount = await relay.count()
            XCTAssertEqual(relayCount, 1, fixture)
            XCTAssertFalse(recorder.values.contains(.connect), fixture)
        }
    }

    func testMalformedCredentialDeleteFailureShowsResetRetryThenRecovers() async {
        let recorder = EnvironmentRecorder()
        let credentials = EnvironmentCredentials(
            recorder: recorder,
            stored: nil,
            malformed: true,
            deleteFailures: 1
        )
        let relay = EnvironmentRelay(recorder: recorder)
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: credentials,
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )

        await environment.start()
        XCTAssertEqual(environment.status, .credentialResetFailed)
        let firstRelayCount = await relay.count()
        XCTAssertEqual(firstRelayCount, 0)

        await environment.start()
        XCTAssertEqual(environment.status, .ready)
        XCTAssertEqual(recorder.values.filter { $0 == .deleteCredentials }.count, 2)
        let finalRelayCount = await relay.count()
        XCTAssertEqual(finalRelayCount, 1)
    }

    func testRealLifecycleStopRetainsSeededSetupAndRestoresOnce() async throws {
        let fixture = try PathLifecycleFixture(seededSetup: true)
        let environment = fixture.makeEnvironment()
        await environment.start()

        await environment.stop()

        let metrics = await fixture.metrics()
        let receipt = try await fixture.receiptStore.load()
        XCTAssertEqual(metrics, .retainedAfterSingleRestore)
        XCTAssertEqual(receipt, fixture.seededReceipt)
    }

    func testRealLifecycleQuitRetainsSeededSetupBeforeInjectedTermination() async throws {
        let fixture = try PathLifecycleFixture(seededSetup: true)
        let environment = fixture.makeEnvironment(
            terminateApplication: { fixture.recorder.append(.terminate) }
        )
        await environment.start()

        environment.requestQuit()
        await spinMainActor(until: { fixture.recorder.values.contains(.terminate) })

        let metrics = await fixture.metrics()
        let receipt = try await fixture.receiptStore.load()
        XCTAssertEqual(metrics, .retainedAfterSingleRestore)
        XCTAssertEqual(receipt, fixture.seededReceipt)
    }

    func testRealReadyEnvironmentDeinitRetainsSeededSetupAndRestoresOnce() async throws {
        let fixture = try PathLifecycleFixture(seededSetup: true)
        weak var weakEnvironment: AppEnvironment?
        var environment: AppEnvironment? = fixture.makeEnvironment()
        weakEnvironment = environment
        await environment?.start()

        environment = nil
        XCTAssertNil(weakEnvironment)
        await fixture.monitor.waitForStopCount(1)

        let metrics = await fixture.metrics()
        let receipt = try await fixture.receiptStore.load()
        XCTAssertEqual(metrics, .retainedAfterSingleRestore)
        XCTAssertEqual(receipt, fixture.seededReceipt)
    }

    func testRealEnvironmentStopConcurrentWithExplicitDisconnectRestoresOnceThenRemovesSetup() async throws {
        let fixture = try PathLifecycleFixture(seededSetup: true)
        let environment = fixture.makeEnvironment()
        await environment.start()
        await fixture.monitor.blockStop()

        let stopping = Task { await environment.stop() }
        await fixture.monitor.waitForStopCount(1)
        let disconnecting = Task { await fixture.viewModel.disconnect() }
        await Task.yield()
        let blockedMetrics = await fixture.monitor.metrics()
        XCTAssertEqual(blockedMetrics.stop, 1)

        await fixture.monitor.releaseStop()
        await stopping.value
        await disconnecting.value

        let metrics = await fixture.metrics()
        let receipt = try await fixture.receiptStore.load()
        XCTAssertEqual(metrics, .removedAfterSingleRestore)
        XCTAssertNil(receipt)
    }

    func testRealQueuedRestartReusesReceiptWithoutReinstallOrCredentialRewrite() async throws {
        let fixture = try PathLifecycleFixture(seededSetup: true)
        let environment = fixture.makeEnvironment()
        await environment.start()
        await fixture.monitor.blockStop()

        let stopping = Task { await environment.stop() }
        await fixture.monitor.waitForStopCount(1)
        environment.requestStart()
        await fixture.monitor.releaseStop()
        await stopping.value
        await spinMainActor(until: { environment.status == .ready })

        let metrics = await fixture.metrics()
        let receipt = try await fixture.receiptStore.load()
        XCTAssertEqual(metrics.monitorStarts, 2)
        XCTAssertEqual(metrics.monitorStops, 1)
        XCTAssertEqual(metrics.credentialSaves, 0)
        XCTAssertEqual(metrics.integrationInstalls, 0)
        XCTAssertEqual(receipt, fixture.seededReceipt)
    }

    func testRealQuitWaitsForCommittedApprovalThenRetainsSetup() async throws {
        let fixture = try PathLifecycleFixture(seededSetup: false)
        let environment = fixture.makeEnvironment(
            terminateApplication: { fixture.recorder.append(.terminate) }
        )
        await environment.start()
        await fixture.monitor.blockSnapshot()
        let approval = Task { await fixture.viewModel.approveIntegrations() }
        await fixture.monitor.waitForSnapshot()

        environment.requestQuit()
        await Task.yield()
        XCTAssertFalse(fixture.recorder.values.contains(.terminate))

        await fixture.monitor.releaseSnapshot()
        await spinMainActor(until: { fixture.recorder.values.contains(.terminate) })
        await approval.value

        let metrics = await fixture.metrics()
        let receipt = try await fixture.receiptStore.load()
        XCTAssertEqual(
            metrics,
            PathLifecycleMetrics(
                credentialSaves: 1,
                credentialDeletes: 0,
                integrationInstalls: 1,
                integrationUninstalls: 0,
                loginRegisters: 1,
                loginUnregisters: 0,
                monitorStarts: 1,
                monitorStops: 1
            )
        )
        XCTAssertNotNil(receipt)
    }

    func testRealStopFromUnapprovedIntegrationReviewPreventsSetupMutation() async throws {
        let fixture = try PathLifecycleFixture(seededSetup: false)
        let environment = fixture.makeEnvironment()
        await environment.start()
        XCTAssertEqual(fixture.viewModel.phase, .integrationReview)

        await environment.stop()

        let metrics = await fixture.metrics()
        let receipt = try await fixture.receiptStore.load()
        XCTAssertEqual(
            metrics,
            PathLifecycleMetrics(
                credentialSaves: 0,
                credentialDeletes: 0,
                integrationInstalls: 0,
                integrationUninstalls: 0,
                loginRegisters: 0,
                loginUnregisters: 0,
                monitorStarts: 0,
                monitorStops: 0
            )
        )
        XCTAssertNil(receipt)
    }
}

@MainActor
private func spinMainActor(
    until condition: (@MainActor () -> Bool)? = nil
) async {
    for _ in 0..<100 {
        if condition?() == true { return }
        await Task.yield()
    }
}

@MainActor
private func appButton(_ identifier: String, in view: NSView) throws -> NSButton {
    try XCTUnwrap(
        appDescendants(of: view)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == identifier }
    )
}

@MainActor
private func appDescendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + appDescendants(of: $0) }
}

private actor VerifierService: TuyaDeviceServicing {
    private var sends = 0
    func status() async throws -> [TuyaStatus] {
        [
            TuyaStatus(code: "switch_led", value: .bool(true)),
            TuyaStatus(code: "colour_data_v2", value: .string("{\"h\":0,\"s\":0,\"v\":500}"))
        ]
    }
    func specification() async throws -> TuyaSpecification {
        TuyaSpecification(
            category: "dj",
            functions: [
                TuyaDataPointSpecification(code: "switch_led", type: "Boolean", values: "{}"),
                TuyaDataPointSpecification(
                    code: "colour_data_v2",
                    type: "Json",
                    values: "{\"h\":{\"min\":0,\"max\":360,\"scale\":0,\"step\":1},\"s\":{\"min\":0,\"max\":1000,\"scale\":0,\"step\":1},\"v\":{\"min\":0,\"max\":1000,\"scale\":0,\"step\":1}}"
                )
            ],
            status: []
        )
    }
    func send(commands: [TuyaCommand]) async throws { sends += 1 }
    func sendCount() -> Int { sends }
}

private enum EnvironmentCall: Equatable, Sendable {
    case prepare, recover, loadCredentials, deleteCredentials, synchronize, connect, approve
    case relayStart, relayAccept, relayStop, shutdownMonitoring, disconnect, terminate
    case environmentStopComplete
}

private final class EnvironmentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EnvironmentCall] = []
    var values: [EnvironmentCall] { lock.withLock { storage } }
    func append(_ value: EnvironmentCall) { lock.withLock { storage.append(value) } }
    func removeAll() { lock.withLock { storage.removeAll() } }
}

private final class EnvironmentCredentials: CredentialStoring, @unchecked Sendable {
    private let recorder: EnvironmentRecorder
    private let lock = NSLock()
    private var stored: TuyaCredentials?
    private var malformed: Bool
    private var remainingDeleteFailures: Int
    init(
        recorder: EnvironmentRecorder,
        stored: TuyaCredentials?,
        malformed: Bool = false,
        deleteFailures: Int = 0
    ) {
        self.recorder = recorder
        self.stored = stored
        self.malformed = malformed
        remainingDeleteFailures = deleteFailures
    }
    func save(_ credentials: TuyaCredentials) throws {}
    func load() throws -> TuyaCredentials? {
        recorder.append(.loadCredentials)
        return try lock.withLock {
            if malformed { throw CredentialStoreError.malformedData }
            return stored
        }
    }
    func delete() throws {
        recorder.append(.deleteCredentials)
        try lock.withLock {
            if remainingDeleteFailures > 0 {
                remainingDeleteFailures -= 1
                throw CredentialStoreError.security(operation: .delete, status: -1)
            }
            malformed = false
            stored = nil
        }
    }
}

private actor EnvironmentMonitor: MonitoringOrchestrating {
    private let recorder: EnvironmentRecorder
    private var recoveryBlocked = false
    private var recoveryEntered = false
    private var recoveries = 0
    private var cancellationCount = 0
    private var recoveryRelease: CheckedContinuation<Void, Never>?
    private var recoveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    init(recorder: EnvironmentRecorder) { self.recorder = recorder }
    func blockRecovery() { recoveryBlocked = true }
    func waitForRecovery() async {
        if recoveryEntered { return }
        await withCheckedContinuation { recoveryWaiters.append($0) }
    }
    func releaseRecovery() { recoveryBlocked = false; recoveryRelease?.resume(); recoveryRelease = nil }
    func recoverIfNeeded() async throws {
        recorder.append(.recover)
        recoveries += 1
        recoveryEntered = true
        let waiters = recoveryWaiters
        recoveryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if recoveryBlocked {
            await withTaskCancellationHandler {
                await withCheckedContinuation { recoveryRelease = $0 }
            } onCancel: {
                Task { await self.recordRecoveryCancellation() }
            }
        }
        try Task.checkCancellation()
    }
    func recoveryCount() -> Int { recoveries }
    func waitForRecoveryCancellation() async {
        if cancellationCount > 0 { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
    private func recordRecoveryCancellation() {
        cancellationCount += 1
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    func start() async throws {}
    func accept(_ event: AgentEvent) async {}
    func pause() async {}
    func resume() async throws {}
    func stop() async {}
    func reconnect() async {}
    func updates() async -> AsyncStream<MonitoringSnapshot> { AsyncStream { $0.finish() } }
    func currentSnapshot() async -> MonitoringSnapshot {
        MonitoringSnapshot(state: .idle, sessions: [], connection: .connected)
    }
}

private actor EnvironmentRelay: RelayServing {
    private let recorder: EnvironmentRecorder
    private var handler: (@Sendable (Data) async -> Void)?
    private(set) var startCount = 0
    private(set) var relayStopCount = 0
    private var isActive = false
    private var remainingStartFailures = 0
    private let startGate = EnvironmentGate()
    private let stopGate = EnvironmentGate()
    init(recorder: EnvironmentRecorder) { self.recorder = recorder }
    func start(handler: @escaping @Sendable (Data) async -> Void) async throws {
        startCount += 1
        recorder.append(.relayStart)
        await startGate.enter()
        if remainingStartFailures > 0 {
            remainingStartFailures -= 1
            throw EnvironmentRelayError.startFailed
        }
        self.handler = handler
        isActive = true
    }
    func stop() async {
        relayStopCount += 1
        recorder.append(.relayStop)
        await stopGate.enter()
        handler = nil
        isActive = false
    }
    func deliver(_ data: Data) async { await handler?(data) }
    func count() -> Int { startCount }
    func stopCount() -> Int { relayStopCount }
    func active() -> Bool { isActive }
    func failStart() { remainingStartFailures = .max }
    func failNextStart() { remainingStartFailures += 1 }
    func blockStart() async { await startGate.block() }
    func waitForStart() async { await startGate.waitForEntry() }
    func releaseStart() async { await startGate.release() }
    func blockStop() async { await stopGate.block() }
    func waitForStop() async { await stopGate.waitForEntry() }
    func releaseStop() async { await stopGate.release() }
}

private enum EnvironmentRelayError: Error { case startFailed }

private actor EnvironmentCoordinator: RelayEventCoordinating {
    private let recorder: EnvironmentRecorder
    private(set) var acceptCount = 0
    init(recorder: EnvironmentRecorder) { self.recorder = recorder }
    func accept(_ data: Data) async {
        acceptCount += 1
        recorder.append(.relayAccept)
    }
    func count() -> Int { acceptCount }
}

@MainActor
private final class EnvironmentViewModel: AppViewModeling {
    private let recorder: EnvironmentRecorder
    private let disconnectGate = EnvironmentGate()
    private let shutdownGate = EnvironmentGate()
    private let approvalGate = EnvironmentGate()
    private var approvalInProgress = false
    private var approvalCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    var phase: AppPhase = .onboarding
    var connectionStatus: LightConnectionStatus = .disconnected
    var currentState: AgentState = .idle
    var sessions: [AgentEvent] = []
    var integrationPreviews: [IntegrationPreview] = []
    var presentedError: PresentationError?
    var outstandingObligations: Set<OutstandingObligation> = []
    let automaticSetupResumeAuthorized: Bool
    private(set) var lastDraft: ConnectionDraft?
    init(
        recorder: EnvironmentRecorder,
        automaticSetupResumeAuthorized: Bool = false
    ) {
        self.recorder = recorder
        self.automaticSetupResumeAuthorized = automaticSetupResumeAuthorized
    }
    func connect(using draft: ConnectionDraft) async {
        lastDraft = draft
        recorder.append(.connect)
        phase = .integrationReview
    }
    func approveIntegrations() async {
        recorder.append(.approve)
        phase = .approving
        approvalInProgress = true
        await approvalGate.enter()
        approvalInProgress = false
        let waiters = approvalCompletionWaiters
        approvalCompletionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        phase = .monitoring
    }
    func pause() async {}
    func resume() async {}
    func repairIntegrations() async {}
    func shutdownMonitoring() async {
        recorder.append(.shutdownMonitoring)
        if approvalInProgress {
            await withCheckedContinuation { approvalCompletionWaiters.append($0) }
        }
        await shutdownGate.enter()
    }
    func disconnect() async {
        recorder.append(.disconnect)
        await disconnectGate.enter()
    }
    func observeMonitoring() async {}
    func synchronizeOwnership() async { recorder.append(.synchronize) }
    func blockDisconnect() async { await disconnectGate.block() }
    func waitForDisconnect() async { await disconnectGate.waitForEntry() }
    func releaseDisconnect() async { await disconnectGate.release() }
    func blockShutdownMonitoring() async { await shutdownGate.block() }
    func waitForShutdownMonitoring() async { await shutdownGate.waitForEntry() }
    func releaseShutdownMonitoring() async { await shutdownGate.release() }
    func blockApproval() async { await approvalGate.block() }
    func waitForApproval() async { await approvalGate.waitForEntry() }
    func releaseApproval() async { await approvalGate.release() }
}

private actor EnvironmentGate {
    private var isBlocked = false
    private var entryCount = 0
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block() { isBlocked = true }

    func enter() async {
        entryCount += 1
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard isBlocked else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitForEntry() async {
        if entryCount > 0 { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        isBlocked = false
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct PathLifecycleMetrics: Equatable, Sendable {
    let credentialSaves: Int
    let credentialDeletes: Int
    let integrationInstalls: Int
    let integrationUninstalls: Int
    let loginRegisters: Int
    let loginUnregisters: Int
    let monitorStarts: Int
    let monitorStops: Int

    static let retainedAfterSingleRestore = PathLifecycleMetrics(
        credentialSaves: 0,
        credentialDeletes: 0,
        integrationInstalls: 0,
        integrationUninstalls: 0,
        loginRegisters: 0,
        loginUnregisters: 0,
        monitorStarts: 1,
        monitorStops: 1
    )

    static let removedAfterSingleRestore = PathLifecycleMetrics(
        credentialSaves: 0,
        credentialDeletes: 1,
        integrationInstalls: 0,
        integrationUninstalls: 1,
        loginRegisters: 0,
        loginUnregisters: 1,
        monitorStarts: 1,
        monitorStops: 1
    )

    static let compensatedAfterSingleRestore = PathLifecycleMetrics(
        credentialSaves: 2,
        credentialDeletes: 0,
        integrationInstalls: 1,
        integrationUninstalls: 1,
        loginRegisters: 1,
        loginUnregisters: 1,
        monitorStarts: 1,
        monitorStops: 1
    )
}

private final class PathCredentialStore: CredentialStoring, PreviousCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TuyaCredentials?
    private var previous: TuyaCredentials?
    private var saves = 0
    private var deletes = 0

    init(stored: TuyaCredentials?) {
        self.stored = stored
    }

    var saveCount: Int { lock.withLock { saves } }
    var deleteCount: Int { lock.withLock { deletes } }

    func save(_ credentials: TuyaCredentials) throws {
        lock.withLock {
            saves += 1
            stored = credentials
        }
    }

    func load() throws -> TuyaCredentials? { lock.withLock { stored } }

    func delete() throws {
        lock.withLock {
            deletes += 1
            stored = nil
        }
    }

    func savePrevious(_ credentials: TuyaCredentials) throws {
        lock.withLock { previous = credentials }
    }

    func loadPrevious() throws -> TuyaCredentials? { lock.withLock { previous } }

    func deletePrevious() throws {
        lock.withLock { previous = nil }
    }
}

private actor PathIntegrationInstaller: IntegrationInstalling {
    private let receipt: IntegrationInstallReceipt
    private var installs = 0
    private var uninstalls = 0

    init(receipt: IntegrationInstallReceipt) {
        self.receipt = receipt
    }

    func preview() async throws -> [IntegrationPreview] {
        AgentSource.allCases.map {
            IntegrationPreview(
                source: $0,
                path: "/CANARY/\($0.rawValue).json",
                before: "{}",
                after: "{}",
                hadOwnedEntries: false
            )
        }
    }

    func install() async throws { installs += 1 }

    func installWithReceipt() async throws -> IntegrationInstallReceipt {
        installs += 1
        return receipt
    }

    func repair() async throws {}
    func repair(using receipt: IntegrationInstallReceipt) async throws -> IntegrationInstallReceipt { receipt }
    func uninstall() async throws { uninstalls += 1 }
    func uninstall(using receipt: IntegrationInstallReceipt) async throws { uninstalls += 1 }
    func verifyArtifactCleanup() async throws -> Bool { false }
    func metrics() -> (install: Int, uninstall: Int) { (installs, uninstalls) }
}

@MainActor
private final class PathLoginItem: LoginItemControlling {
    private var current: LoginItemStatus
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(current: LoginItemStatus) {
        self.current = current
    }

    func status() -> LoginItemStatus { current }

    func setEnabled(_ enabled: Bool) throws -> LoginItemTransition {
        let previous = current
        if enabled {
            registerCount += 1
            current = .enabled
            return LoginItemTransition(
                previous: previous,
                current: current,
                didRegister: previous != .enabled,
                didUnregister: false
            )
        }
        unregisterCount += 1
        current = .notRegistered
        return LoginItemTransition(
            previous: previous,
            current: current,
            didRegister: false,
            didUnregister: previous == .enabled || previous == .requiresApproval
        )
    }
}

private actor PathMonitor: MonitoringOrchestrating {
    private let stopGate = EnvironmentGate()
    private let snapshotGate = EnvironmentGate()
    private var starts = 0
    private var stops = 0

    func start() async throws { starts += 1 }
    func accept(_ event: AgentEvent) async {}
    func pause() async {}
    func resume() async throws {}

    func stop() async {
        stops += 1
        await stopGate.enter()
    }

    func reconnect() async {}
    func recoverIfNeeded() async throws {}

    func updates() async -> AsyncStream<MonitoringSnapshot> {
        AsyncStream { _ in }
    }

    func currentSnapshot() async -> MonitoringSnapshot {
        await snapshotGate.enter()
        return MonitoringSnapshot(state: .idle, sessions: [], connection: .connected)
    }

    func blockStop() async { await stopGate.block() }
    func waitForStopCount(_ expected: Int) async {
        while stops < expected { await Task.yield() }
    }
    func releaseStop() async { await stopGate.release() }
    func blockSnapshot() async { await snapshotGate.block() }
    func waitForSnapshot() async { await snapshotGate.waitForEntry() }
    func releaseSnapshot() async { await snapshotGate.release() }
    func metrics() -> (start: Int, stop: Int) { (starts, stops) }
}

private actor PathVerifier: TuyaConnectionVerifying {
    func verify(_ credentials: TuyaCredentials) async throws -> ResolvedLightCapabilities {
        let specification = TuyaSpecification(
            category: "dj",
            functions: [
                TuyaDataPointSpecification(code: "switch_led", type: "Boolean", values: "{}"),
                TuyaDataPointSpecification(
                    code: "colour_data_v2",
                    type: "Json",
                    values: "{\"h\":{\"min\":0,\"max\":360,\"scale\":0,\"step\":1},\"s\":{\"min\":0,\"max\":1000,\"scale\":0,\"step\":1},\"v\":{\"min\":0,\"max\":1000,\"scale\":0,\"step\":1}}"
                )
            ],
            status: []
        )
        return try TuyaCapabilityResolver.resolve(specification: specification)
    }
}

@MainActor
private final class PathLifecycleFixture {
    let recorder = EnvironmentRecorder()
    let credentialStore: PathCredentialStore
    let integrations: PathIntegrationInstaller
    let loginItem: PathLoginItem
    let monitor = PathMonitor()
    let receiptStore: MemorySetupOwnershipStore
    let seededReceipt: SetupOwnershipReceipt
    let viewModel: AppViewModel

    init(seededSetup: Bool) throws {
        let credentials = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyain.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )
        let integrationReceipt = IntegrationInstallReceipt(
            sources: AgentSource.allCases.map {
                IntegrationSourceReceipt(
                    source: $0,
                    ownership: .fresh,
                    marker: AppIdentity.integrationIdentifier,
                    installedContentFingerprint: String(repeating: "d", count: 64)
                )
            }
        )
        seededReceipt = SetupOwnershipReceipt(
            integration: .uninstallable(integrationReceipt),
            credential: .created,
            login: .registered
        )
        credentialStore = PathCredentialStore(stored: credentials)
        integrations = PathIntegrationInstaller(receipt: integrationReceipt)
        loginItem = PathLoginItem(current: seededSetup ? .enabled : .notRegistered)
        receiptStore = MemorySetupOwnershipStore(receipt: seededSetup ? seededReceipt : nil)
        viewModel = AppViewModel(
            credentials: credentialStore,
            integrations: integrations,
            monitor: monitor,
            loginItem: loginItem,
            verifier: PathVerifier(),
            ownershipLedger: AppOwnershipLedger(store: receiptStore)
        )
    }

    func makeEnvironment(
        beforeApproval: @escaping @Sendable () async -> Void = {},
        terminateApplication: @escaping @MainActor @Sendable () -> Void = {}
    ) -> AppEnvironment {
        AppEnvironment(
            viewModel: viewModel,
            credentials: credentialStore,
            monitor: monitor,
            relay: EnvironmentRelay(recorder: recorder),
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {},
            beforeApproval: beforeApproval,
            terminateApplication: terminateApplication
        )
    }

    func metrics() async -> PathLifecycleMetrics {
        let integrationMetrics = await integrations.metrics()
        let monitorMetrics = await monitor.metrics()
        return PathLifecycleMetrics(
            credentialSaves: credentialStore.saveCount,
            credentialDeletes: credentialStore.deleteCount,
            integrationInstalls: integrationMetrics.install,
            integrationUninstalls: integrationMetrics.uninstall,
            loginRegisters: loginItem.registerCount,
            loginUnregisters: loginItem.unregisterCount,
            monitorStarts: monitorMetrics.start,
            monitorStops: monitorMetrics.stop
        )
    }
}
