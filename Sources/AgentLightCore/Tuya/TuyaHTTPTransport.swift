import Foundation

public protocol TuyaHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum TuyaHTTPTransportError: Error, Sendable {
    case invalidResponse
}

enum TuyaRedirectPolicy {
    static func redirectedRequest(from original: URLRequest, to proposed: URLRequest) -> URLRequest? {
        nil
    }

    static func hasSameOrigin(_ first: URL, _ second: URL) -> Bool {
        guard let firstScheme = first.scheme?.lowercased(),
              let secondScheme = second.scheme?.lowercased(),
              let firstHost = first.host?.lowercased(),
              let secondHost = second.host?.lowercased(),
              let firstPort = effectivePort(for: firstScheme, explicitPort: first.port),
              let secondPort = effectivePort(for: secondScheme, explicitPort: second.port) else {
            return false
        }
        return firstScheme == secondScheme
            && firstHost == secondHost
            && firstPort == secondPort
    }

    private static func effectivePort(for scheme: String, explicitPort: Int?) -> Int? {
        if let explicitPort { return explicitPort }
        return switch scheme {
        case "https": 443
        case "http": 80
        default: nil
        }
    }
}

private final class TuyaRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(TuyaRedirectPolicy.redirectedRequest(from: task.originalRequest ?? request, to: request))
    }
}

public struct URLSessionTuyaHTTPTransport: TuyaHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = URLSession(
            configuration: session.configuration,
            delegate: TuyaRedirectRejectingDelegate(),
            delegateQueue: nil
        )
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              let requestURL = request.url,
              let responseURL = response.url,
              TuyaRedirectPolicy.hasSameOrigin(requestURL, responseURL) else {
            throw TuyaHTTPTransportError.invalidResponse
        }
        return (data, response)
    }
}
