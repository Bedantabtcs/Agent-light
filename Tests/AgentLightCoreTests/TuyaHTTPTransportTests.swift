import Foundation
import XCTest
@testable import AgentLightCore

final class TuyaHTTPTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RecordingTuyaURLProtocol.reset()
    }

    @available(*, deprecated, message: "Compatibility coverage")
    func testLegacyTransportErrorNameRemainsSourceCompatible() {
        let error: TuyaHTTPTransportError = .invalidResponseOrigin

        XCTAssertEqual(error, TuyaTransportError.invalidResponseOrigin)
    }

    func testRedirectPolicyRejectsSameAndCrossOriginRedirects() throws {
        let original = URLRequest(url: try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/v1.0/token")))
        let sameOrigin = URLRequest(url: try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/v1.0/other")))
        let crossOrigin = URLRequest(url: try XCTUnwrap(URL(string: "https://attacker.example/collect")))

        XCTAssertNil(TuyaRedirectPolicy.redirectedRequest(from: original, to: sameOrigin))
        XCTAssertNil(TuyaRedirectPolicy.redirectedRequest(from: original, to: crossOrigin))
    }

    func testProductionSessionDelegateRejectsSameOriginRedirectBeforeFollowing() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/redirect-same"))
        let expectedTarget = requestURL.appending(path: "target")
        let redirectObserved = expectation(description: "redirect decision observed")
        let completionObserved = expectation(description: "request cancellation completed")
        let redirectProbe = RedirectDecisionProbe(expectation: redirectObserved)
        let completionProbe = CompletionProbe(expectation: completionObserved)
        let transport = makeTransport(
            redirectProbe: redirectProbe,
            completionProbe: completionProbe
        )

        let requestTask = Task { try await transport.data(for: URLRequest(url: requestURL)) }
        await fulfillment(of: [redirectObserved], timeout: 1)
        let decision = try XCTUnwrap(redirectProbe.decision())

        XCTAssertEqual(decision.proposedURL, expectedTarget)
        XCTAssertNil(decision.acceptedURL)
        XCTAssertEqual(RecordingTuyaURLProtocol.requestedURLs(), [requestURL])
        requestTask.cancel()
        await fulfillment(of: [completionObserved], timeout: 1)
        _ = try? await requestTask.value
        XCTAssertEqual(completionProbe.count(), 1)
    }

    func testProductionSessionDelegateRejectsCrossOriginRedirectBeforeFollowing() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/redirect-cross"))
        let expectedTarget = try XCTUnwrap(URL(string: "https://attacker.example/collect"))
        let redirectObserved = expectation(description: "redirect decision observed")
        let completionObserved = expectation(description: "request cancellation completed")
        let redirectProbe = RedirectDecisionProbe(expectation: redirectObserved)
        let completionProbe = CompletionProbe(expectation: completionObserved)
        let transport = makeTransport(
            redirectProbe: redirectProbe,
            completionProbe: completionProbe
        )

        let requestTask = Task { try await transport.data(for: URLRequest(url: requestURL)) }
        await fulfillment(of: [redirectObserved], timeout: 1)
        let decision = try XCTUnwrap(redirectProbe.decision())

        XCTAssertEqual(decision.proposedURL, expectedTarget)
        XCTAssertNil(decision.acceptedURL)
        XCTAssertEqual(RecordingTuyaURLProtocol.requestedURLs(), [requestURL])
        requestTask.cancel()
        await fulfillment(of: [completionObserved], timeout: 1)
        _ = try? await requestTask.value
        XCTAssertEqual(completionProbe.count(), 1)
    }

    func testProductionTransportRejectsMismatchedFinalResponseOriginWithTypedError() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/final-origin-mismatch"))
        let completion = expectation(description: "transport completed")
        let result = TransportResultProbe()
        let bodyProbe = AcceptedBodyProbe()
        let delegateCompletion = expectation(description: "delegate completed once")
        let completionProbe = CompletionProbe(expectation: delegateCompletion)
        let transport = makeTransport(bodyProbe: bodyProbe, completionProbe: completionProbe)

        let requestTask = Task {
            do {
                _ = try await transport.data(for: URLRequest(url: requestURL))
                result.record(error: nil)
            } catch {
                result.record(error: error)
            }
            completion.fulfill()
        }
        defer { requestTask.cancel() }
        await fulfillment(of: [completion, delegateCompletion], timeout: 1)

        XCTAssertEqual(result.error() as? TuyaTransportError, .invalidResponseOrigin)
        XCTAssertEqual(RecordingTuyaURLProtocol.requestedURLs(), [requestURL])
        XCTAssertEqual(RecordingTuyaURLProtocol.bodyLoadAttemptCount(), 1)
        XCTAssertEqual(bodyProbe.snapshot().receivedCallbacks, 0)
        XCTAssertEqual(bodyProbe.snapshot().receivedBytes, 0)
        XCTAssertEqual(bodyProbe.snapshot().acceptedCallbacks, 0)
        XCTAssertEqual(bodyProbe.snapshot().acceptedBytes, 0)
        XCTAssertEqual(completionProbe.count(), 1)
    }

    func testProductionTransportRejectsNonHTTPResponseBeforeAcceptingBody() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/non-http-response"))
        let completion = expectation(description: "transport completed")
        let delegateCompletion = expectation(description: "delegate completed once")
        let result = TransportResultProbe()
        let bodyProbe = AcceptedBodyProbe()
        let completionProbe = CompletionProbe(expectation: delegateCompletion)
        let transport = makeTransport(bodyProbe: bodyProbe, completionProbe: completionProbe)

        let requestTask = Task {
            do {
                _ = try await transport.data(for: URLRequest(url: requestURL))
                result.record(error: nil)
            } catch {
                result.record(error: error)
            }
            completion.fulfill()
        }
        defer { requestTask.cancel() }
        await fulfillment(of: [completion, delegateCompletion], timeout: 1)

        XCTAssertEqual(result.error() as? TuyaTransportError, .invalidResponse)
        XCTAssertEqual(RecordingTuyaURLProtocol.bodyLoadAttemptCount(), 1)
        XCTAssertEqual(bodyProbe.snapshot().receivedCallbacks, 0)
        XCTAssertEqual(bodyProbe.snapshot().receivedBytes, 0)
        XCTAssertEqual(bodyProbe.snapshot().acceptedCallbacks, 0)
        XCTAssertEqual(bodyProbe.snapshot().acceptedBytes, 0)
        XCTAssertEqual(completionProbe.count(), 1)
    }

    func testProductionTransportBuffersOnlyAllowedResponseDataAndCompletesOnce() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/success-body"))
        let bodyProbe = AcceptedBodyProbe()
        let delegateCompletion = expectation(description: "delegate completed once")
        let completionProbe = CompletionProbe(expectation: delegateCompletion)
        let transport = makeTransport(bodyProbe: bodyProbe, completionProbe: completionProbe)

        let (data, response) = try await transport.data(for: URLRequest(url: requestURL))
        await fulfillment(of: [delegateCompletion], timeout: 1)

        XCTAssertEqual(response.url, requestURL)
        XCTAssertEqual(data, Data("allowed-body".utf8))
        XCTAssertGreaterThan(bodyProbe.snapshot().receivedCallbacks, 0)
        XCTAssertEqual(bodyProbe.snapshot().receivedBytes, data.count)
        XCTAssertGreaterThan(bodyProbe.snapshot().acceptedCallbacks, 0)
        XCTAssertEqual(bodyProbe.snapshot().acceptedBytes, data.count)
        XCTAssertEqual(completionProbe.count(), 1)
    }

    func testProductionTransportCancellationCompletesContinuationExactlyOnce() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/cancel-after-response"))
        let requestCompletion = expectation(description: "request continuation completed")
        let delegateCompletion = expectation(description: "delegate completed once")
        let result = TransportResultProbe()
        let completionProbe = CompletionProbe(expectation: delegateCompletion)
        let transport = makeTransport(completionProbe: completionProbe)

        let requestTask = Task {
            do {
                _ = try await transport.data(for: URLRequest(url: requestURL))
                result.record(error: nil)
            } catch {
                result.record(error: error)
            }
            requestCompletion.fulfill()
        }
        let started = await waitUntil {
            RecordingTuyaURLProtocol.requestedURLs() == [requestURL]
        }
        XCTAssertTrue(started)
        requestTask.cancel()
        await fulfillment(of: [requestCompletion, delegateCompletion], timeout: 1)

        let error = result.error()
        XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        XCTAssertEqual(completionProbe.count(), 1)
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

    private func makeTransport() -> URLSessionTuyaHTTPTransport {
        URLSessionTuyaHTTPTransport(session: URLSession(configuration: makeConfiguration()))
    }

    private func makeTransport(
        redirectProbe: RedirectDecisionProbe,
        completionProbe: CompletionProbe
    ) -> URLSessionTuyaHTTPTransport {
        URLSessionTuyaHTTPTransport(
            configuration: makeConfiguration(),
            redirectDecisionObserver: { proposed, accepted in
                redirectProbe.record(
                    RedirectDecision(
                        proposedURL: proposed.url,
                        acceptedURL: accepted?.url
                    )
                )
            },
            completionObserver: { completionProbe.record() }
        )
    }

    private func makeTransport(
        bodyProbe: AcceptedBodyProbe? = nil,
        completionProbe: CompletionProbe? = nil
    ) -> URLSessionTuyaHTTPTransport {
        URLSessionTuyaHTTPTransport(
            configuration: makeConfiguration(),
            redirectDecisionObserver: { _, _ in },
            dataReceiptObserver: { byteCount in
                bodyProbe?.recordReceipt(byteCount: byteCount)
            },
            acceptedBodyObserver: { byteCount in
                bodyProbe?.recordAcceptance(byteCount: byteCount)
            },
            completionObserver: { completionProbe?.record() }
        )
    }

    private func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingTuyaURLProtocol.self]
        return configuration
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while ContinuousClock().now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private final class TransportResultProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: (any Error)?

    func record(error: (any Error)?) {
        lock.withLock {
            storedError = error
        }
    }

    func error() -> (any Error)? {
        lock.withLock { storedError }
    }
}

private final class AcceptedBodyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedCallbacks = 0
    private var receivedBytes = 0
    private var acceptedCallbacks = 0
    private var acceptedBytes = 0

    func recordReceipt(byteCount: Int) {
        lock.withLock {
            receivedCallbacks += 1
            receivedBytes += byteCount
        }
    }

    func recordAcceptance(byteCount: Int) {
        lock.withLock {
            acceptedCallbacks += 1
            acceptedBytes += byteCount
        }
    }

    func snapshot() -> (
        receivedCallbacks: Int,
        receivedBytes: Int,
        acceptedCallbacks: Int,
        acceptedBytes: Int
    ) {
        lock.withLock {
            (receivedCallbacks, receivedBytes, acceptedCallbacks, acceptedBytes)
        }
    }
}

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var completions = 0

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
        expectation.assertForOverFulfill = true
    }

    func record() {
        lock.withLock {
            completions += 1
        }
        expectation.fulfill()
    }

    func count() -> Int {
        lock.withLock { completions }
    }
}

private struct RedirectDecision: Sendable {
    let proposedURL: URL?
    let acceptedURL: URL?
}

private final class RedirectDecisionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var storedDecision: RedirectDecision?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func record(_ decision: RedirectDecision) {
        lock.withLock {
            storedDecision = decision
        }
        expectation.fulfill()
    }

    func decision() -> RedirectDecision? {
        lock.withLock { storedDecision }
    }
}

private final class RecordingTuyaURLProtocol: URLProtocol, @unchecked Sendable {
    private static let requestLock = NSLock()
    nonisolated(unsafe) private static var requests: [URL] = []
    nonisolated(unsafe) private static var bodyLoadAttempts = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "openapi.tuyaus.com" || request.url?.host == "attacker.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.requestLock.withLock {
            Self.requests.append(url)
        }

        switch url.path {
        case "/redirect-same":
            redirect(to: url.appending(path: "target"))
        case "/redirect-cross":
            guard let target = URL(string: "https://attacker.example/collect") else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            redirect(to: target)
        case "/final-origin-mismatch":
            guard let finalURL = URL(string: "https://attacker.example/final"),
                  let response = HTTPURLResponse(
                    url: finalURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Self.requestLock.withLock {
                Self.bodyLoadAttempts += 1
            }
            client?.urlProtocol(self, didLoad: Data(#"{"CANARY":"body-must-not-bypass-origin"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case "/non-http-response":
            let response = URLResponse(
                url: url,
                mimeType: "application/json",
                expectedContentLength: 16,
                textEncodingName: "utf-8"
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Self.recordBodyLoadAttempt()
            client?.urlProtocol(self, didLoad: Data("rejected-body".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case "/success-body":
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("allowed-".utf8))
            client?.urlProtocol(self, didLoad: Data("body".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case "/cancel-after-response":
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        default:
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    static func reset() {
        requestLock.withLock {
            requests.removeAll()
            bodyLoadAttempts = 0
        }
    }

    static func requestedURLs() -> [URL] {
        requestLock.withLock { requests }
    }

    static func bodyLoadAttemptCount() -> Int {
        requestLock.withLock { bodyLoadAttempts }
    }

    private static func recordBodyLoadAttempt() {
        requestLock.withLock {
            bodyLoadAttempts += 1
        }
    }

    private func redirect(to target: URL) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": target.absoluteString]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(
            self,
            wasRedirectedTo: URLRequest(url: target),
            redirectResponse: response
        )
    }
}
