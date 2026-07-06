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

        try UnixDatagramSender.send(Data("event".utf8), to: path)
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

        XCTAssertThrowsError(try UnixDatagramSender.send(Data(), to: path))
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
        try UnixDatagramSender.send(Data("replacement".utf8), to: path)
        await fulfillment(of: [received], timeout: 1)
        await replacement.stop()
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
        try UnixDatagramSender.send(payload, to: path)
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
        do {
            try UnixDatagramSender.send(payload, to: path)
        } catch let error as UnixDatagramError {
            guard case let .systemCall(name, code) = error else {
                XCTFail("Unexpected transport error: \(error)")
                await server.stop()
                return
            }
            XCTAssertEqual(name, "sendto")
            XCTAssertEqual(code, EMSGSIZE)
        } catch {
            XCTFail("Unexpected transport error: \(error)")
        }
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
        try UnixDatagramSender.send(Data("replacement".utf8), to: path)
        await fulfillment(of: [replacementReceived], timeout: 1)
        await replacement.stop()
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
