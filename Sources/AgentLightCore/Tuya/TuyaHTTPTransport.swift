import Foundation

public protocol TuyaHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum TuyaHTTPTransportError: Error, Sendable {
    case invalidResponse
}

public struct URLSessionTuyaHTTPTransport: TuyaHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TuyaHTTPTransportError.invalidResponse
        }
        return (data, response)
    }
}
