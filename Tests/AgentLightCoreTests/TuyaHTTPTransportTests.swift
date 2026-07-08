import Foundation
import XCTest
@testable import AgentLightCore

final class TuyaHTTPTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RecordingTuyaURLProtocol.reset()
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
        let probe = RedirectDecisionProbe()
        let transport = makeTransport(probe: probe)

        let requestTask = Task { try await transport.data(for: URLRequest(url: requestURL)) }
        let decision = await probe.wait()

        XCTAssertEqual(decision.proposedURL, expectedTarget)
        XCTAssertNil(decision.acceptedURL)
        XCTAssertEqual(RecordingTuyaURLProtocol.requestedURLs(), [requestURL])
        requestTask.cancel()
        _ = try? await requestTask.value
    }

    func testProductionSessionDelegateRejectsCrossOriginRedirectBeforeFollowing() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/redirect-cross"))
        let expectedTarget = try XCTUnwrap(URL(string: "https://attacker.example/collect"))
        let probe = RedirectDecisionProbe()
        let transport = makeTransport(probe: probe)

        let requestTask = Task { try await transport.data(for: URLRequest(url: requestURL)) }
        let decision = await probe.wait()

        XCTAssertEqual(decision.proposedURL, expectedTarget)
        XCTAssertNil(decision.acceptedURL)
        XCTAssertEqual(RecordingTuyaURLProtocol.requestedURLs(), [requestURL])
        requestTask.cancel()
        _ = try? await requestTask.value
    }

    func testProductionTransportRejectsMismatchedFinalResponseOriginWithTypedError() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://openapi.tuyaus.com/final-origin-mismatch"))

        do {
            _ = try await makeTransport().data(for: URLRequest(url: requestURL))
            XCTFail("Expected a mismatched final origin to be rejected")
        } catch {
            XCTAssertEqual(error as? TuyaTransportError, .invalidResponseOrigin)
        }
        XCTAssertEqual(RecordingTuyaURLProtocol.requestedURLs(), [requestURL])
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

    private func makeTransport(probe: RedirectDecisionProbe) -> URLSessionTuyaHTTPTransport {
        URLSessionTuyaHTTPTransport(
            configuration: makeConfiguration(),
            redirectDecisionObserver: { proposed, accepted in
                Task {
                    await probe.record(
                        RedirectDecision(
                            proposedURL: proposed.url,
                            acceptedURL: accepted?.url
                        )
                    )
                }
            }
        )
    }

    private func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingTuyaURLProtocol.self]
        return configuration
    }
}

private struct RedirectDecision: Sendable {
    let proposedURL: URL?
    let acceptedURL: URL?
}

private actor RedirectDecisionProbe {
    private var decision: RedirectDecision?
    private var continuation: CheckedContinuation<RedirectDecision, Never>?

    func record(_ decision: RedirectDecision) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: decision)
        } else {
            self.decision = decision
        }
    }

    func wait() async -> RedirectDecision {
        if let decision {
            self.decision = nil
            return decision
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private final class RecordingTuyaURLProtocol: URLProtocol, @unchecked Sendable {
    private static let requestLock = NSLock()
    nonisolated(unsafe) private static var requests: [URL] = []

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
            client?.urlProtocol(self, didLoad: Data(#"{"CANARY":"body-must-not-bypass-origin"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
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
        }
    }

    static func requestedURLs() -> [URL] {
        requestLock.withLock { requests }
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
