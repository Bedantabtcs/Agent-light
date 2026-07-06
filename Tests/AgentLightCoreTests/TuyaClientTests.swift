import CryptoKit
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

    func testFirstHTTP401RefreshesTokenOnce() async throws {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("old-token", expiresIn: 7_200)),
            .json(401, "unauthorized"),
            .json(200, tokenJSON("new-token", expiresIn: 7_200)),
            .json(200, statusJSON())
        ])
        let client = makeClient(transport: transport)

        _ = try await client.status()

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter(isTokenRequest).count, 2)
        XCTAssertEqual(requests.filter(isStatusRequest).count, 2)
    }

    func testSecondHTTP401SurfacesWithoutThirdTokenRequest() async {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("old-token", expiresIn: 7_200)),
            .json(401, "unauthorized"),
            .json(200, tokenJSON("new-token", expiresIn: 7_200)),
            .json(401, "still unauthorized")
        ])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsTuyaError(.authenticationFailure) {
            _ = try await client.status()
        }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter(isTokenRequest).count, 2)
        XCTAssertEqual(requests.filter(isStatusRequest).count, 2)
    }

    func testConcurrentCacheMissesShareOneTokenRequest() async throws {
        let callerCount = 6
        let clock = CoordinatingDateSource(date: testDate, arrivalsBeforeRelease: callerCount)
        let transport = ConcurrentTokenTransport()
        let client = makeClient(transport: transport, now: { await clock.current() })

        let results = try await concurrentStatuses(client: client, count: callerCount)
        let tokenRequests = await transport.tokenRequestCount()
        let statusRequests = await transport.statusRequestCount()

        XCTAssertEqual(results.count, callerCount)
        XCTAssertEqual(tokenRequests, 1)
        XCTAssertEqual(statusRequests, callerCount)
    }

    func testConcurrentStaleCacheCallersShareOneTokenRequest() async throws {
        let callerCount = 6
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = CoordinatingDateSource(date: start, arrivalsBeforeRelease: 0)
        let transport = ConcurrentTokenTransport(expiresIn: 120)
        let client = makeClient(transport: transport, now: { await clock.current() })
        _ = try await client.status()
        await clock.coordinateNextArrivals(
            callerCount,
            at: start.addingTimeInterval(60)
        )

        let results = try await concurrentStatuses(client: client, count: callerCount)
        let tokenRequests = await transport.tokenRequestCount()
        let statusRequests = await transport.statusRequestCount()

        XCTAssertEqual(results.count, callerCount)
        XCTAssertEqual(tokenRequests, 2)
        XCTAssertEqual(statusRequests, callerCount + 1)
    }

    func testConcurrentAuthenticationFailuresShareOneRefreshGeneration() async throws {
        let callerCount = 6
        let transport = ConcurrentRefreshTransport()
        let client = makeClient(transport: transport)
        _ = try await client.status()
        await transport.enableAuthenticationFailures(expectedRequests: callerCount)

        let results = try await concurrentStatuses(client: client, count: callerCount)
        let tokenRequests = await transport.tokenRequestCount()
        let refreshedStatusRequests = await transport.refreshedStatusRequestCount()

        XCTAssertEqual(results.count, callerCount)
        XCTAssertEqual(tokenRequests, 2)
        XCTAssertEqual(refreshedStatusRequests, callerCount)
    }

    func testFailedSharedTokenAcquisitionClearsFlightAndAllowsRetry() async throws {
        let callerCount = 5
        let clock = CoordinatingDateSource(date: testDate, arrivalsBeforeRelease: callerCount)
        let transport = FailingTokenFlightTransport()
        let client = makeClient(transport: transport, now: { await clock.current() })

        let failures = await concurrentTransportFailures(client: client, count: callerCount)
        let failedFlightTokenRequests = await transport.tokenRequestCount()
        XCTAssertEqual(failures, callerCount)
        XCTAssertEqual(failedFlightTokenRequests, 1)

        _ = try await client.status()
        let retriedTokenRequests = await transport.tokenRequestCount()
        XCTAssertEqual(retriedTokenRequests, 2)
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

    func testPOSTSignatureAuthenticatesExactTransmittedMethodURLAndBody() async throws {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("token", expiresIn: 7_200)),
            .json(200, successJSON(result: "true"))
        ])
        let client = makeClient(transport: transport)

        try await client.send(commands: [TuyaCommand(code: "switch_led", value: .bool(true))])

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first(where: isCommandRequest))
        let method = try XCTUnwrap(request.httpMethod)
        let url = try XCTUnwrap(request.url)
        let body = try XCTUnwrap(request.httpBody)
        let timestamp = try XCTUnwrap(request.value(forHTTPHeaderField: "t"))
        let nonce = try XCTUnwrap(request.value(forHTTPHeaderField: "nonce"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let pathAndQuery = components.percentEncodedQuery.map {
            components.percentEncodedPath + "?" + $0
        } ?? components.percentEncodedPath
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonical = [method, bodyHash, "", pathAndQuery].joined(separator: "\n")
        let payload = "access-id" + "token" + timestamp + nonce + canonical
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8),
            using: SymmetricKey(data: Data("access-secret".utf8))
        )
        let expectedSignature = authentication.map { String(format: "%02X", $0) }.joined()

        XCTAssertEqual(request.value(forHTTPHeaderField: "sign"), expectedSignature)
    }

    func testTransportFailureIsSanitized() async {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("token", expiresIn: 7_200)),
            .sensitiveFailure("agent-content access-id access-secret")
        ])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsTuyaError(.transport) {
            _ = try await client.status()
        }
    }

    func testNonSuccessHTTPStatusIsRejected() async {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("token", expiresIn: 7_200)),
            .json(503, "upstream body")
        ])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsTuyaError(.httpStatus(503)) {
            _ = try await client.status()
        }
    }

    func testMalformedResponseIsRejected() async {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("token", expiresIn: 7_200)),
            .json(200, "not-json agent-content")
        ])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsTuyaError(.malformedResponse) {
            _ = try await client.status()
        }
    }

    func testBusinessErrorIsRejected() async {
        let transport = ScriptedTuyaTransport(steps: [
            .json(200, tokenJSON("token", expiresIn: 7_200)),
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

private func makeClient<Transport: TuyaHTTPTransport>(
    transport: Transport,
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

private func concurrentStatuses(client: TuyaClient, count: Int) async throws -> [[TuyaStatus]] {
    try await withThrowingTaskGroup(of: [TuyaStatus].self) { group in
        for _ in 0..<count {
            group.addTask { try await client.status() }
        }
        var results: [[TuyaStatus]] = []
        for try await status in group {
            results.append(status)
        }
        return results
    }
}

private func concurrentTransportFailures(client: TuyaClient, count: Int) async -> Int {
    await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<count {
            group.addTask {
                do {
                    _ = try await client.status()
                    return false
                } catch TuyaClientError.transport {
                    return true
                } catch {
                    return false
                }
            }
        }
        var failures = 0
        for await failedAsExpected in group where failedAsExpected {
            failures += 1
        }
        return failures
    }
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

private actor CoordinatingDateSource {
    private var date: Date
    private var arrivalsBeforeRelease: Int
    private var arrivals = 0
    private var isReleased: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(date: Date, arrivalsBeforeRelease: Int) {
        self.date = date
        self.arrivalsBeforeRelease = arrivalsBeforeRelease
        isReleased = arrivalsBeforeRelease == 0
    }

    func current() async -> Date {
        guard !isReleased else { return date }
        arrivals += 1
        if arrivals == arrivalsBeforeRelease {
            isReleased = true
            let waiting = waiters
            waiters.removeAll()
            for waiter in waiting {
                waiter.resume()
            }
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        return date
    }

    func coordinateNextArrivals(_ count: Int, at date: Date) {
        self.date = date
        arrivalsBeforeRelease = count
        arrivals = 0
        isReleased = count == 0
        waiters.removeAll()
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

private actor ConcurrentTokenTransport: TuyaHTTPTransport {
    private let expiresIn: Int
    private var tokenRequests = 0
    private var statusRequests = 0

    init(expiresIn: Int = 7_200) {
        self.expiresIn = expiresIn
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if isTokenRequest(request) {
            tokenRequests += 1
            return try testResponse(
                request: request,
                statusCode: 200,
                body: tokenJSON("shared-token", expiresIn: expiresIn)
            )
        }
        statusRequests += 1
        return try testResponse(request: request, statusCode: 200, body: statusJSON())
    }

    func tokenRequestCount() -> Int {
        tokenRequests
    }

    func statusRequestCount() -> Int {
        statusRequests
    }
}

private actor ConcurrentRefreshTransport: TuyaHTTPTransport {
    private var tokenRequests = 0
    private var refreshedStatusRequests = 0
    private var authenticationFailuresEnabled = false
    private var expectedAuthenticationRequests = 0
    private var authenticationRequestCount = 0
    private var authenticationWaiters: [CheckedContinuation<Void, Never>] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if isTokenRequest(request) {
            tokenRequests += 1
            let token = tokenRequests == 1 ? "old-token" : "new-token"
            return try testResponse(request: request, statusCode: 200, body: tokenJSON(token, expiresIn: 7_200))
        }

        let token = request.value(forHTTPHeaderField: "access_token")
        if authenticationFailuresEnabled, token == "old-token" {
            await waitForConcurrentAuthenticationRequests()
            return try testResponse(
                request: request,
                statusCode: 200,
                body: businessErrorJSON(code: 1010, message: "expired")
            )
        }
        if token == "new-token" {
            refreshedStatusRequests += 1
        }
        return try testResponse(request: request, statusCode: 200, body: statusJSON())
    }

    func enableAuthenticationFailures(expectedRequests: Int) {
        expectedAuthenticationRequests = expectedRequests
        authenticationFailuresEnabled = true
    }

    func tokenRequestCount() -> Int {
        tokenRequests
    }

    func refreshedStatusRequestCount() -> Int {
        refreshedStatusRequests
    }

    private func waitForConcurrentAuthenticationRequests() async {
        authenticationRequestCount += 1
        if authenticationRequestCount == expectedAuthenticationRequests {
            let waiting = authenticationWaiters
            authenticationWaiters.removeAll()
            for waiter in waiting {
                waiter.resume()
            }
        } else {
            await withCheckedContinuation { continuation in
                authenticationWaiters.append(continuation)
            }
        }
    }
}

private actor FailingTokenFlightTransport: TuyaHTTPTransport {
    private var tokenRequests = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if isTokenRequest(request) {
            tokenRequests += 1
            if tokenRequests == 1 {
                throw SensitiveTransportError(description: "injected token transport failure")
            }
            return try testResponse(request: request, statusCode: 200, body: tokenJSON("retry-token", expiresIn: 7_200))
        }
        return try testResponse(request: request, statusCode: 200, body: statusJSON())
    }

    func tokenRequestCount() -> Int {
        tokenRequests
    }
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

private func testResponse(
    request: URLRequest,
    statusCode: Int,
    body: String
) throws -> (Data, HTTPURLResponse) {
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
