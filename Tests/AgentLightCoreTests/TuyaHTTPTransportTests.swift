import Foundation
import XCTest
@testable import AgentLightCore

final class TuyaHTTPTransportTests: XCTestCase {
    func testRedirectPolicyRejectsSameAndCrossOriginRedirects() throws {
        let original = URLRequest(url: try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/v1.0/token")))
        let sameOrigin = URLRequest(url: try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/v1.0/other")))
        let crossOrigin = URLRequest(url: try XCTUnwrap(URL(string: "https://attacker.example/collect")))

        XCTAssertNil(TuyaRedirectPolicy.redirectedRequest(from: original, to: sameOrigin))
        XCTAssertNil(TuyaRedirectPolicy.redirectedRequest(from: original, to: crossOrigin))
    }

    func testOriginValidationNormalizesDefaultPortAndRejectsSchemeHostAndPortChanges() throws {
        let origin = try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/path"))
        let explicitDefaultPort = try XCTUnwrap(URL(string: "https://openapi.tuyaus.com:443/other"))
        let changedScheme = try XCTUnwrap(URL(string: "http://openapi.tuyaus.com/path"))
        let changedHost = try XCTUnwrap(URL(string: "https://attacker.example/path"))
        let changedPort = try XCTUnwrap(URL(string: "https://openapi.tuyaus.com:8443/path"))

        XCTAssertTrue(TuyaRedirectPolicy.hasSameOrigin(origin, explicitDefaultPort))
        XCTAssertFalse(TuyaRedirectPolicy.hasSameOrigin(origin, changedScheme))
        XCTAssertFalse(TuyaRedirectPolicy.hasSameOrigin(origin, changedHost))
        XCTAssertFalse(TuyaRedirectPolicy.hasSameOrigin(origin, changedPort))
    }
}
