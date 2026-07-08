import Foundation

public protocol TuyaHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum TuyaTransportError: Error, Equatable, Sendable {
    case invalidResponse
    case invalidResponseOrigin
}

@available(*, deprecated, renamed: "TuyaTransportError")
public typealias TuyaHTTPTransportError = TuyaTransportError

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

private final class TuyaSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias RedirectDecisionObserver = @Sendable (URLRequest, URLRequest?) -> Void
    typealias DataReceiptObserver = @Sendable (Int) -> Void
    typealias AcceptedBodyObserver = @Sendable (Int) -> Void
    typealias CompletionObserver = @Sendable () -> Void

    private struct TaskState {
        let originalURL: URL
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        var response: HTTPURLResponse?
        var body = Data()
        var rejection: TuyaTransportError?
        var responseAllowed = false
    }

    private let lock = NSLock()
    private let redirectDecisionObserver: RedirectDecisionObserver?
    private let dataReceiptObserver: DataReceiptObserver?
    private let acceptedBodyObserver: AcceptedBodyObserver?
    private let completionObserver: CompletionObserver?
    private var states: [Int: TaskState] = [:]

    init(
        redirectDecisionObserver: RedirectDecisionObserver? = nil,
        dataReceiptObserver: DataReceiptObserver? = nil,
        acceptedBodyObserver: AcceptedBodyObserver? = nil,
        completionObserver: CompletionObserver? = nil
    ) {
        self.redirectDecisionObserver = redirectDecisionObserver
        self.dataReceiptObserver = dataReceiptObserver
        self.acceptedBodyObserver = acceptedBodyObserver
        self.completionObserver = completionObserver
    }

    func data(
        for request: URLRequest,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        guard let originalURL = request.url else {
            throw TuyaTransportError.invalidResponse
        }
        let cancellation = TuyaTaskCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.withLock {
                    states[task.taskIdentifier] = TaskState(
                        originalURL: originalURL,
                        continuation: continuation
                    )
                }
                cancellation.install(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let redirectedRequest = TuyaRedirectPolicy.redirectedRequest(
            from: task.originalRequest ?? request,
            to: request
        )
        redirectDecisionObserver?(request, redirectedRequest)
        completionHandler(redirectedRequest)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let disposition: URLSession.ResponseDisposition = lock.withLock {
            guard var state = states[dataTask.taskIdentifier] else { return .cancel }
            guard let response = response as? HTTPURLResponse else {
                state.rejection = .invalidResponse
                states[dataTask.taskIdentifier] = state
                return .cancel
            }
            guard let responseURL = response.url,
                  TuyaRedirectPolicy.hasSameOrigin(state.originalURL, responseURL) else {
                state.rejection = .invalidResponseOrigin
                states[dataTask.taskIdentifier] = state
                return .cancel
            }
            state.response = response
            state.responseAllowed = true
            states[dataTask.taskIdentifier] = state
            return .allow
        }
        completionHandler(disposition)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        dataReceiptObserver?(data.count)
        let acceptedByteCount: Int? = lock.withLock {
            guard var state = states[dataTask.taskIdentifier],
                  state.responseAllowed,
                  state.rejection == nil else {
                return nil
            }
            state.body.append(data)
            states[dataTask.taskIdentifier] = state
            return data.count
        }
        if let acceptedByteCount {
            acceptedBodyObserver?(acceptedByteCount)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let state = lock.withLock({ states.removeValue(forKey: task.taskIdentifier) }) else {
            return
        }
        completionObserver?()
        if let rejection = state.rejection {
            state.continuation.resume(throwing: rejection)
        } else if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.response {
            state.continuation.resume(returning: (state.body, response))
        } else {
            state.continuation.resume(throwing: TuyaTransportError.invalidResponse)
        }
    }
}

private final class TuyaTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func install(_ task: URLSessionTask) {
        let shouldCancel = lock.withLock {
            self.task = task
            return isCancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}

public struct URLSessionTuyaHTTPTransport: TuyaHTTPTransport {
    private let session: URLSession
    private let delegate: TuyaSessionDelegate

    public init(session: URLSession = .shared) {
        let delegate = TuyaSessionDelegate()
        self.delegate = delegate
        self.session = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    init(
        configuration: URLSessionConfiguration,
        redirectDecisionObserver: @escaping @Sendable (URLRequest, URLRequest?) -> Void,
        dataReceiptObserver: (@Sendable (Int) -> Void)? = nil,
        acceptedBodyObserver: (@Sendable (Int) -> Void)? = nil,
        completionObserver: (@Sendable () -> Void)? = nil
    ) {
        let delegate = TuyaSessionDelegate(
            redirectDecisionObserver: redirectDecisionObserver,
            dataReceiptObserver: dataReceiptObserver,
            acceptedBodyObserver: acceptedBodyObserver,
            completionObserver: completionObserver
        )
        self.delegate = delegate
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await delegate.data(for: request, session: session)
    }
}
