import Foundation
import XCTest
@testable import AgentLightCore

final class TuyaSignerTests: XCTestCase {
    func testCanonicalStringAndUppercaseHMAC() {
        let request = TuyaSignedRequest(
            method: "GET",
            pathAndQuery: "/v1.0/token?grant_type=1",
            body: Data()
        )

        let canonical = TuyaSigner.canonicalString(for: request)
        let signature = TuyaSigner.signature(
            clientID: "client",
            secret: "secret",
            token: nil,
            timestamp: "1700000000000",
            nonce: "nonce",
            canonicalString: canonical
        )

        XCTAssertEqual(
            canonical,
            "GET\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n\n/v1.0/token?grant_type=1"
        )
        XCTAssertEqual(signature, "58D0DB4B823F633F795059A6B64182CBC82F718056B5D90365747186BD664085")
    }

    func testHeadersContainRequiredAuthenticationFields() {
        let credentials = TuyaCredentials(
            endpoint: URL(string: "https://openapi.tuyaus.com") ?? URL(fileURLWithPath: "/"),
            accessID: "client",
            accessSecret: "secret",
            deviceID: "device"
        )
        let request = TuyaSignedRequest(method: "GET", pathAndQuery: "/v1.0/devices", body: Data())

        let headers = TuyaSigner.headers(
            for: request,
            credentials: credentials,
            token: "token",
            timestamp: "1700000000000",
            nonce: "nonce"
        )

        XCTAssertEqual(headers["client_id"], "client")
        XCTAssertEqual(headers["access_token"], "token")
        XCTAssertEqual(headers["t"], "1700000000000")
        XCTAssertEqual(headers["nonce"], "nonce")
        XCTAssertEqual(headers["sign_method"], "HMAC-SHA256")
        XCTAssertEqual(headers["sign"]?.count, 64)
    }
}
