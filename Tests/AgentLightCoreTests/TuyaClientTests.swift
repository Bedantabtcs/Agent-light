import Foundation
import XCTest
@testable import AgentLightCore

final class TuyaClientTests: XCTestCase {
    func testBusinessAuthenticationFailureRefreshesOnceAndSignsEveryRequest() async throws {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("old-token", expiresIn: 7_200)),
            .json(200, businessErrorJSON(code: 1010, message: "token expired")),
            .json(200, tokenJSON("new-token", expiresIn: 7_200)),
            .json(200, successJSON(result: "true"))
        ])
        let client = makeClient(transport: transport)

        try await client.send(commands: [TuyaCommand(code: "switch_led", value: .bool(true))])

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter(isTokenRequest).count, 2)
        XCTAssertEqual(requests.filter(isCommandRequest).count, 2)
        XCTAssertTrue(requests.allSatisfy(isSignedRequest))
        XCTAssertEqual(requests.compactMap { $0.value(forHTTPHeaderField: "nonce") }, [
            "nonce-1", "nonce-2", "nonce-3", "nonce-4"
        ])
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "access_token"), "old-token")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "access_token"), "new-token")
    }

    func testSecondBusinessAuthenticationFailureSurfacesWithoutThirdTokenRequest() async {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("old-token", expiresIn: 7_200)),
            .json(200, businessErrorJSON(code: 401, message: "token invalid")),
            .json(200, tokenJSON("new-token", expiresIn: 7_200)),
            .json(200, businessErrorJSON(code: 401, message: "token invalid"))
        ])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsTuyaError(.authenticationFailure) {
            try await client.send(commands: [TuyaCommand(code: "switch_led", value: .bool(true))])
        }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter(isTokenRequest).count, 2)
        XCTAssertEqual(requests.filter(isCommandRequest).count, 2)
    }

    func testReusesCachedTokenBeforeSafetyWindow() async throws {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("cached-token", expiresIn: 7_200)),
            .json(200, statusJSON()),
            .json(200, statusJSON())
        ])
        let client = makeClient(transport: transport)

        _ = try await client.status()
        _ = try await client.status()

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter(isTokenRequest).count, 1)
        XCTAssertEqual(requests.filter(isStatusRequest).count, 2)
    }

    func testRefreshesAtSixtySecondExpirySafetyBoundary() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestDateSource(start)
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("first-token", expiresIn: 120)),
            .json(200, statusJSON()),
            .json(200, statusJSON()),
            .json(200, tokenJSON("second-token", expiresIn: 120)),
            .json(200, statusJSON())
        ])
        let client = makeClient(transport: transport, now: { await clock.current() })

        _ = try await client.status()
        await clock.set(start.addingTimeInterval(59))
        _ = try await client.status()
        await clock.set(start.addingTimeInterval(60))
        _ = try await client.status()

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter(isTokenRequest).count, 2)
        XCTAssertEqual(requests.filter(isStatusRequest).count, 3)
    }

    func testVerifyFetchesStatusAndPreservesTypedValues() async throws {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("token", expiresIn: 7_200)),
            .json(200, statusJSON())
        ])
        let client = makeClient(transport: transport)

        try await client.verify()

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter(isStatusRequest).count, 1)
    }

    func testStatusReturnsTypedValues() async throws {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("token", expiresIn: 7_200)),
            .json(200, statusJSON())
        ])
        let client = makeClient(transport: transport)

        let status = try await client.status()

        XCTAssertEqual(status, [
            TuyaStatus(code: "switch_led", value: .bool(true)),
            TuyaStatus(code: "work_mode", value: .string("colour"))
        ])
    }

    func testCommandBodyUsesDeterministicJSON() async throws {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("token", expiresIn: 7_200)),
            .json(200, successJSON(result: "true"))
        ])
        let client = makeClient(transport: transport)

        try await client.send(commands: [TuyaCommand(code: "switch_led", value: .bool(true))])

        let requests = await transport.recordedRequests()
        let commandRequest = try XCTUnwrap(requests.first(where: isCommandRequest))
        XCTAssertEqual(commandRequest.httpBody, Data(#"{"commands":[{"code":"switch_led","value":true}]}"#.utf8))
        XCTAssertEqual(commandRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testTransportFailureIsSanitized() async {
        let transport = ScriptedTuyaTransport(steps: [.sensitiveFailure("agent-content access-id access-secret")])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsTuyaError(.transport) {
            _ = try await client.status()
        }
    }

    func testNonSuccessHTTPStatusIsRejected() async {
        let transport = ScriptedTuyaTransport(steps: [.json(503, "upstream body")])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsTuyaError(.httpStatus(503)) {
            _ = try await client.status()
        }
    }

    func testMalformedResponseIsRejected() async {
        let transport = ScriptedTuyaTransport(steps: [.json(200, "not-json agent-content")])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsTuyaError(.malformedResponse) {
            _ = try await client.status()
        }
    }

    func testBusinessErrorIsRejected() async {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, businessErrorJSON(code: 2001, message: "device offline"))
        ])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsTuyaError(.apiFailure) {
            _ = try await client.status()
        }
    }

    func testErrorDescriptionsNeverExposeCredentialsTokenDeviceBodyOrAgentContent() async {
        let secrets = ["access-id", "access-secret", "token-value", "device-id", "body-value", "agent-content"]
        let message = secrets.joined(separator: " ")
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("token-value", expiresIn: 7_200)),
            .json(200, businessErrorJSON(code: 2001, message: message))
        ])
        let client = makeClient(transport: transport)

        do {
            try await client.send(commands: [TuyaCommand(code: "body-value", value: .string("agent-content"))])
            XCTFail("Expected a sanitized Tuya error")
        } catch {
            let description = String(describing: error)
            let localized = error.localizedDescription
            for secret in secrets {
                XCTAssertFalse(description.contains(secret))
                XCTAssertFalse(localized.contains(secret))
            }
        }
    }

    func testDeviceIDIsPercentEncodedAsOnePathComponent() async throws {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("token", expiresIn: 7_200)),
            .json(200, statusJSON())
        ])
        let credentials = TuyaCredentials(
            endpoint: testEndpoint,
            accessID: "access-id",
            accessSecret: "access-secret",
            deviceID: "device/../?agent-content"
        )
        let client = TuyaClient(
            credentials: credentials,
            transport: transport,
            now: { testDate },
            nonce: { "nonce" }
        )

        _ = try await client.status()

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first(where: isStatusRequest))
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            components.percentEncodedPath,
            "/v1.0/iot-03/devices/device%2F..%2F%3Fagent-content/status"
        )
        XCTAssertNil(request.url?.query)
    }
}

private let testDate = Date(timeIntervalSince1970: 1_700_000_000)
private let testEndpoint = URL(string: "https://openapi.tuyaus.com") ?? URL(fileURLWithPath: "/")

private func makeClient(
    transport: ScriptedTuyaTransport,
    now: @escaping @Sendable () async -> Date = { testDate }
) -> TuyaClient {
    let nonceSequence = NonceSequence()
    return TuyaClient(
        credentials: TuyaCredentials(
            endpoint: testEndpoint,
            accessID: "access-id",
            accessSecret: "access-secret",
            deviceID: "device-id"
        ),
        transport: transport,
        now: now,
        nonce: { await nonceSequence.next() }
    )
}

private actor TestDateSource {
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func current() -> Date {
        date
    }

    func set(_ date: Date) {
        self.date = date
    }
}

private actor NonceSequence {
    private var value = 0

    func next() -> String {
        value += 1
        return "nonce-\(value)"
    }
}

private enum ScriptedStep: Sendable {
    case json(Int, String)
    case sensitiveFailure(String)
}

private struct SensitiveTransportError: Error, CustomStringConvertible, Sendable {
    let description: String
}

private actor ScriptedTuyaTransport: TuyaHTTPTransport {
    private var steps: [ScriptedStep]
    private var requests: [URLRequest] = []

    init(steps: [ScriptedStep]) {
        self.steps = steps
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !steps.isEmpty else { throw SensitiveTransportError(description: "unexpected request") }
        let step = steps.removeFirst()
        switch step {
        case let .json(statusCode, body):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                  ) else {
                throw SensitiveTransportError(description: "failed to create response")
            }
            return (Data(body.utf8), response)
        case let .sensitiveFailure(message):
            throw SensitiveTransportError(description: message)
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private func tokenJSON(_ token: String, expiresIn: Int) -> String {
    #"{"success":true,"result":{"access_token":"\#(token)","expire_time":\#(expiresIn)}}"#
}

private func statusJSON() -> String {
    #"{"success":true,"result":[{"code":"switch_led","value":true},{"code":"work_mode","value":"colour"}]}"#
}

private func successJSON(result: String) -> String {
    #"{"success":true,"result":\#(result)}"#
}

private func businessErrorJSON(code: Int, message: String) -> String {
    let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")
    return #"{"success":false,"code":\#(code),"msg":"\#(escapedMessage)"}"#
}

private func isTokenRequest(_ request: URLRequest) -> Bool {
    request.url?.path == "/v1.0/token"
}

private func isCommandRequest(_ request: URLRequest) -> Bool {
    request.url?.path.hasSuffix("/commands") == true
}

private func isStatusRequest(_ request: URLRequest) -> Bool {
    request.url?.path.hasSuffix("/status") == true
}

private func isSignedRequest(_ request: URLRequest) -> Bool {
    request.value(forHTTPHeaderField: "client_id") != nil
        && request.value(forHTTPHeaderField: "sign")?.count == 64
        && request.value(forHTTPHeaderField: "t") != nil
        && request.value(forHTTPHeaderField: "nonce") != nil
        && request.value(forHTTPHeaderField: "sign_method") == "HMAC-SHA256"
}

private func XCTAssertThrowsTuyaError<T: Sendable>(
    _ expected: TuyaClientError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected TuyaClientError", file: file, line: line)
    } catch let error as TuyaClientError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
    }
}
