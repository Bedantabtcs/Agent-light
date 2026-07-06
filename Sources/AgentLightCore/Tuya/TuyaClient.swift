import Foundation

public actor TuyaClient {
    private struct CachedToken: Sendable {
        let value: String
        let expiresAt: Date
        let generation: UInt64
    }

    private struct TokenAcquisition: Sendable {
        let generation: UInt64
        let task: Task<CachedToken, Error>
    }

    private struct Envelope: Sendable {
        let success: Bool
        let result: JSONValue?
        let code: String?
    }

    private struct CommandBody: Encodable {
        let commands: [TuyaCommand]
    }

    private let credentials: TuyaCredentials
    private let transport: any TuyaHTTPTransport
    private let now: @Sendable () async -> Date
    private let nonce: @Sendable () async -> String
    private var cachedToken: CachedToken?
    private var tokenAcquisition: TokenAcquisition?
    private var nextTokenGeneration: UInt64 = 0

    public init(
        credentials: TuyaCredentials,
        transport: any TuyaHTTPTransport = URLSessionTuyaHTTPTransport(),
        now: @escaping @Sendable () async -> Date = { Date() },
        nonce: @escaping @Sendable () async -> String = { UUID().uuidString }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
        self.nonce = nonce
    }

    public func verify() async throws {
        _ = try await status()
    }

    public func status() async throws -> [TuyaStatus] {
        let result = try await performAuthorizedRequest(
            method: "GET",
            pathComponents: ["v1.0", "iot-03", "devices", credentials.deviceID, "status"],
            body: Data()
        )
        guard case let .array(values) = result else {
            throw TuyaClientError.malformedResponse
        }
        return try values.map { value in
            guard case let .object(object) = value,
                  case let .string(code)? = object["code"],
                  let statusValue = object["value"] else {
                throw TuyaClientError.malformedResponse
            }
            return TuyaStatus(code: code, value: statusValue)
        }
    }

    public func specification() async throws -> TuyaSpecification {
        let result = try await performAuthorizedRequest(
            method: "GET",
            pathComponents: ["v1.0", "devices", credentials.deviceID, "specifications"],
            body: Data()
        )
        do {
            return try JSONDecoder().decode(
                TuyaSpecification.self,
                from: result.encodedData()
            )
        } catch {
            throw TuyaClientError.malformedResponse
        }
    }

    public func send(commands: [TuyaCommand]) async throws {
        let body: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            body = try encoder.encode(CommandBody(commands: commands))
        } catch {
            throw TuyaClientError.malformedResponse
        }
        let result = try await performAuthorizedRequest(
            method: "POST",
            pathComponents: ["v1.0", "iot-03", "devices", credentials.deviceID, "commands"],
            body: body
        )
        guard case .bool(true) = result else {
            throw TuyaClientError.apiFailure
        }
    }

    private func performAuthorizedRequest(
        method: String,
        pathComponents: [String],
        body: Data
    ) async throws -> JSONValue {
        let token = try await accessToken()
        do {
            return try await performRequest(
                method: method,
                pathComponents: pathComponents,
                queryItems: [],
                body: body,
                token: token.value
            )
        } catch TuyaClientError.authenticationFailure {
            let refreshedToken = try await refreshedToken(afterRejecting: token)
            return try await performRequest(
                method: method,
                pathComponents: pathComponents,
                queryItems: [],
                body: body,
                token: refreshedToken.value
            )
        }
    }

    private func accessToken() async throws -> CachedToken {
        let currentDate = await now()
        if let cachedToken,
           currentDate < cachedToken.expiresAt.addingTimeInterval(-60) {
            return cachedToken
        }

        if let tokenAcquisition {
            return try await resolve(tokenAcquisition)
        }

        nextTokenGeneration += 1
        let generation = nextTokenGeneration
        let task = Task<CachedToken, Error> {
            try await self.fetchToken(generation: generation)
        }
        let acquisition = TokenAcquisition(generation: generation, task: task)
        tokenAcquisition = acquisition
        return try await resolve(acquisition)
    }

    private func refreshedToken(afterRejecting rejectedToken: CachedToken) async throws -> CachedToken {
        let currentDate = await now()
        if let cachedToken,
           cachedToken.generation != rejectedToken.generation,
           currentDate < cachedToken.expiresAt.addingTimeInterval(-60) {
            return cachedToken
        }
        if cachedToken?.generation == rejectedToken.generation {
            cachedToken = nil
        }
        return try await accessToken()
    }

    private func fetchToken(generation: UInt64) async throws -> CachedToken {
        let result = try await performRequest(
            method: "GET",
            pathComponents: ["v1.0", "token"],
            queryItems: [URLQueryItem(name: "grant_type", value: "1")],
            body: Data(),
            token: nil
        )
        guard case let .object(object) = result,
              case let .string(accessToken)? = object["access_token"],
              !accessToken.isEmpty,
              let expiresIn = positiveInteger(object["expire_time"]) else {
            throw TuyaClientError.malformedResponse
        }
        let expirationBase = await now()
        return CachedToken(
            value: accessToken,
            expiresAt: expirationBase.addingTimeInterval(TimeInterval(expiresIn)),
            generation: generation
        )
    }

    private func resolve(_ acquisition: TokenAcquisition) async throws -> CachedToken {
        do {
            let token = try await acquisition.task.value
            if tokenAcquisition?.generation == acquisition.generation {
                cachedToken = token
                tokenAcquisition = nil
            }
            return token
        } catch let error as TuyaClientError {
            if tokenAcquisition?.generation == acquisition.generation {
                tokenAcquisition = nil
            }
            throw error
        } catch {
            if tokenAcquisition?.generation == acquisition.generation {
                tokenAcquisition = nil
            }
            throw TuyaClientError.transport
        }
    }

    private func performRequest(
        method: String,
        pathComponents: [String],
        queryItems: [URLQueryItem],
        body: Data,
        token: String?
    ) async throws -> JSONValue {
        let builtRequest = try await makeRequest(
            method: method,
            pathComponents: pathComponents,
            queryItems: queryItems,
            body: body,
            token: token
        )
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: builtRequest)
        } catch {
            throw TuyaClientError.transport
        }

        if response.statusCode == 401, token != nil {
            throw TuyaClientError.authenticationFailure
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TuyaClientError.httpStatus(response.statusCode)
        }

        let envelope = try decodeEnvelope(data)
        guard envelope.success else {
            if token != nil, isAuthenticationCode(envelope.code) {
                throw TuyaClientError.authenticationFailure
            }
            throw TuyaClientError.apiFailure
        }
        guard let result = envelope.result else {
            throw TuyaClientError.malformedResponse
        }
        return result
    }

    private func makeRequest(
        method: String,
        pathComponents: [String],
        queryItems: [URLQueryItem],
        body: Data,
        token: String?
    ) async throws -> URLRequest {
        guard var components = URLComponents(url: credentials.endpoint, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw TuyaClientError.invalidEndpoint
        }

        components.percentEncodedPath = try "/" + pathComponents
            .map(percentEncodedPathComponent)
            .joined(separator: "/")
        components.queryItems = queryItems.isEmpty
            ? nil
            : queryItems.sorted { $0.name < $1.name }
        guard let url = components.url else {
            throw TuyaClientError.invalidEndpoint
        }

        let pathAndQuery = components.percentEncodedQuery.map {
            components.percentEncodedPath + "?" + $0
        } ?? components.percentEncodedPath
        let signedRequest = TuyaSignedRequest(
            method: method,
            pathAndQuery: pathAndQuery,
            body: body
        )
        let timestampDate = await now()
        let timestamp = String(Int64((timestampDate.timeIntervalSince1970 * 1_000).rounded(.down)))
        let requestNonce = await nonce()
        let headers = TuyaSigner.headers(
            for: signedRequest,
            credentials: credentials,
            token: token,
            timestamp: timestamp,
            nonce: requestNonce
        )

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !body.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func decodeEnvelope(_ data: Data) throws -> Envelope {
        let root: JSONValue
        do {
            root = try JSONValue.decode(data)
        } catch {
            throw TuyaClientError.malformedResponse
        }
        guard case let .object(object) = root,
              case let .bool(success)? = object["success"] else {
            throw TuyaClientError.malformedResponse
        }
        return Envelope(
            success: success,
            result: object["result"],
            code: responseCode(object["code"])
        )
    }

    private func responseCode(_ value: JSONValue?) -> String? {
        switch value {
        case let .number(number):
            number.lexeme
        case let .string(string):
            string
        default:
            nil
        }
    }

    private func positiveInteger(_ value: JSONValue?) -> Int? {
        guard let text = responseCode(value),
              let integer = Int(text),
              integer > 0 else {
            return nil
        }
        return integer
    }

    private func isAuthenticationCode(_ code: String?) -> Bool {
        guard let code else { return false }
        return ["401", "1002", "1010", "1011", "1012"].contains(code)
    }

    private func percentEncodedPathComponent(_ component: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard !component.isEmpty,
              let encoded = component.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw TuyaClientError.invalidEndpoint
        }
        return encoded
    }
}
