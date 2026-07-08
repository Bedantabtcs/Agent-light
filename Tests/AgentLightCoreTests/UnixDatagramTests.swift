import Darwin
import AgentLightProtocol
import Foundation
import XCTest
@testable import AgentLightCore

final class UnixDatagramTests: XCTestCase {
    func testRoundTripReceivesOneDatagram() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + ".sock").path
        let server = UnixDatagramServer(path: path)
        let received = expectation(description: "received")

        try await server.start { data in
            XCTAssertEqual(data, Data("event".utf8))
            received.fulfill()
        }

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        XCTAssertTrue(UnixDatagramSender(path: path).sendFailOpen(Data("event".utf8)))
        await fulfillment(of: [received], timeout: 1)
        await server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testRejectsSocketPathThatDoesNotFitUnixAddress() async {
        let path = "/tmp/" + String(repeating: "x", count: 200)
        let server = UnixDatagramServer(path: path)

        do {
            try await server.start { _ in }
            XCTFail("Expected an oversized socket path to be rejected")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }

        XCTAssertFalse(UnixDatagramSender(path: path).sendFailOpen(Data()))
    }

    func testStoppedServerDeinitializationDoesNotUnlinkReplacementSocket() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + ".sock").path
        let replacement = UnixDatagramServer(path: path)
        let received = expectation(description: "replacement received")
        weak var stoppedServer: UnixDatagramServer?

        do {
            let server = UnixDatagramServer(path: path)
            stoppedServer = server
            try await server.start { _ in }
            await server.stop()
            try await replacement.start { _ in
                received.fulfill()
            }
        }

        XCTAssertNil(stoppedServer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(UnixDatagramSender(path: path).sendFailOpen(Data("replacement".utf8)))
        await fulfillment(of: [received], timeout: 1)
        await replacement.stop()
    }

    func testRunningServerDeinitializationCancelsCallbackOwnershipAndUnlinksSocket() async throws {
        let path = temporarySocketPath()
        let tokenBox = WeakHandlerTokenBox()
        weak var releasedServer: UnixDatagramServer?

        do {
            let token = HandlerLifetimeToken()
            tokenBox.store(token)
            let server = UnixDatagramServer(path: path)
            releasedServer = server
            try await server.start { [token] _ in
                withExtendedLifetime(token) {}
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }

        XCTAssertNil(releasedServer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let releasedCallback = await eventually(attempts: 1_000) {
            tokenBox.value() == nil
        }
        XCTAssertTrue(releasedCallback)
    }

    func testStopWhileReceiveIsBlockedReleasesHandlerTask() async throws {
        let path = temporarySocketPath()
        let server = UnixDatagramServer(path: path)
        weak var retainedToken: HandlerLifetimeToken?

        do {
            let token = HandlerLifetimeToken()
            retainedToken = token
            try await server.start { [token] _ in
                withExtendedLifetime(token) {}
            }
        }

        XCTAssertNotNil(retainedToken)
        await server.stop()
        XCTAssertNil(retainedToken)
    }

    func testRepeatedStartStopDoesNotLeakDescriptors() async throws {
        let initialDescriptorCount = try openDescriptorCount()
        let server = UnixDatagramServer(path: temporarySocketPath())

        for _ in 0..<8 {
            weak var retainedToken: HandlerLifetimeToken?
            do {
                let token = HandlerLifetimeToken()
                retainedToken = token
                try await server.start { [token] _ in
                    withExtendedLifetime(token) {}
                }
            }
            await server.stop()
            XCTAssertNil(retainedToken)
        }

        XCTAssertEqual(try openDescriptorCount(), initialDescriptorCount)
    }

    func testPlatformBoundaryDeliversMaximumRelayDatagram() async throws {
        let path = temporarySocketPath()
        let server = UnixDatagramServer(path: path)
        let received = expectation(description: "maximum datagram received")
        let payload = Data(repeating: 0x41, count: RelayEnvelope.maximumEncodedBytes)

        try await server.start { data in
            XCTAssertEqual(data, payload)
            received.fulfill()
        }

        XCTAssertEqual(RelayEnvelope.maximumEncodedBytes, 2_048)
        XCTAssertTrue(UnixDatagramSender(path: path).sendFailOpen(payload))
        await fulfillment(of: [received], timeout: 1)
        await server.stop()
    }

    func testPayloadAbovePlatformBoundaryIsNotDelivered() async throws {
        let path = temporarySocketPath()
        let server = UnixDatagramServer(path: path)
        let oversizedReceived = expectation(description: "oversized datagram not received")
        oversizedReceived.isInverted = true

        try await server.start { _ in
            oversizedReceived.fulfill()
        }

        let payload = Data(repeating: 0x41, count: RelayEnvelope.maximumEncodedBytes + 1)
        XCTAssertFalse(UnixDatagramSender(path: path).sendFailOpen(payload))
        await fulfillment(of: [oversizedReceived], timeout: 1)
        await server.stop()
    }

    func testStopDoesNotUnlinkSocketThatReplacedOwnedPath() async throws {
        let path = temporarySocketPath()
        let original = UnixDatagramServer(path: path)
        let replacement = UnixDatagramServer(path: path)
        let replacementReceived = expectation(description: "replacement received")

        try await original.start { _ in }
        XCTAssertEqual(Darwin.unlink(path), 0)
        try await replacement.start { _ in
            replacementReceived.fulfill()
        }

        await original.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(UnixDatagramSender(path: path).sendFailOpen(Data("replacement".utf8)))
        await fulfillment(of: [replacementReceived], timeout: 1)
        await replacement.stop()
    }

    func testBlockedFirstHandlerDoesNotPreventOwningSecondDatagramInReceiveOrder() async throws {
        let path = temporarySocketPath()
        let server = UnixDatagramServer(path: path)
        let probe = HandlerProbe()
        let releaseGate = HandlerReleaseGate()
        let firstStarted = expectation(description: "first handler started")

        try await server.start { data in
            await probe.recordStarted()
            if data == Data("first".utf8) {
                firstStarted.fulfill()
                await releaseGate.wait()
            }
            await probe.recordCompleted()
        }

        XCTAssertTrue(UnixDatagramSender(path: path).sendFailOpen(Data("first".utf8)))
        await fulfillment(of: [firstStarted], timeout: 1)
        XCTAssertTrue(UnixDatagramSender(path: path).sendFailOpen(Data("second".utf8)))
        let ownsBothDatagrams = await eventually {
            await server.outstandingHandlerTaskCount() == 2
        }
        XCTAssertTrue(ownsBothDatagrams)
        await Task.yield()
        let blockedSnapshot = await probe.snapshot()
        XCTAssertEqual(blockedSnapshot.started, 1)

        await releaseGate.release()
        let handledInOrder = await eventually {
            await probe.snapshot().completed == 2
        }
        XCTAssertTrue(handledInOrder)
        await server.stop()
    }

    func testStopCancelsAndAwaitsEveryOwnedHandlerBeforeReturning() async throws {
        let path = temporarySocketPath()
        let server = UnixDatagramServer(path: path)
        let probe = HandlerProbe()
        let started = expectation(description: "handler started")
        let cancelled = expectation(description: "handler cancelled")

        try await server.start { _ in
            await probe.recordStarted()
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("Unexpected handler error: \(error)")
            }
            await probe.recordCompleted()
        }

        XCTAssertTrue(UnixDatagramSender(path: path).sendFailOpen(Data("blocked".utf8)))
        await fulfillment(of: [started], timeout: 1)
        await server.stop()
        await fulfillment(of: [cancelled], timeout: 0.1)
        let snapshotAfterStop = await probe.snapshot()
        await Task.yield()

        XCTAssertEqual(snapshotAfterStop.started, 1)
        XCTAssertEqual(snapshotAfterStop.completed, 1)
        let snapshotAfterYield = await probe.snapshot()
        XCTAssertEqual(snapshotAfterYield, snapshotAfterStop)
    }

    func testHandlerTaskRegistryBoundsOutstandingBurstWork() async throws {
        let path = temporarySocketPath()
        let server = UnixDatagramServer(path: path, maximumHandlerTasks: 4)
        let probe = HandlerProbe()

        try await server.start { _ in
            await probe.recordStarted()
            try? await Task.sleep(for: .seconds(30))
            await probe.recordCompleted()
        }

        let sender = UnixDatagramSender(path: path)
        for byte in UInt8(0)..<UInt8(40) {
            _ = sender.sendFailOpen(Data([byte]))
        }
        let reachedBound = await eventually(attempts: 1_000) {
            await server.outstandingHandlerTaskCount() == 4
        }
        XCTAssertTrue(reachedBound)
        try? await Task.sleep(for: .milliseconds(50))
        let snapshotBeforeStop = await probe.snapshot()
        XCTAssertEqual(snapshotBeforeStop.started, 1)
        await server.stop()
        let snapshotAfterBoundedStop = await probe.snapshot()
        XCTAssertEqual(snapshotAfterBoundedStop.completed, 1)
    }

    private func temporarySocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + ".sock").path
    }

    private func openDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }
}

private final class HandlerLifetimeToken: @unchecked Sendable {}

private final class WeakHandlerTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var token: HandlerLifetimeToken?

    func store(_ token: HandlerLifetimeToken) {
        lock.withLock {
            self.token = token
        }
    }

    func value() -> HandlerLifetimeToken? {
        lock.withLock { token }
    }
}

private actor HandlerProbe {
    struct Snapshot: Equatable {
        let started: Int
        let completed: Int
    }

    private var started = 0
    private var completed = 0

    func recordStarted() {
        started += 1
    }

    func recordCompleted() {
        completed += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(started: started, completed: completed)
    }
}

private actor HandlerReleaseGate {
    private var isReleased = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}
