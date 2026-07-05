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
}
