import Foundation

public struct TuyaCredentials: Codable, Equatable, Sendable {
    public let endpoint: URL
    public let accessID: String
    public let accessSecret: String
    public let deviceID: String

    public init(endpoint: URL, accessID: String, accessSecret: String, deviceID: String) {
        self.endpoint = endpoint
        self.accessID = accessID
        self.accessSecret = accessSecret
        self.deviceID = deviceID
    }
}

public struct TuyaSignedRequest: Sendable {
    public let method: String
    public let pathAndQuery: String
    public let body: Data

    public init(method: String, pathAndQuery: String, body: Data) {
        self.method = method
        self.pathAndQuery = pathAndQuery
        self.body = body
    }
}

public struct TuyaCommand: Codable, Equatable, Sendable {
    public let code: String
    public let value: JSONValue

    public init(code: String, value: JSONValue) {
        self.code = code
        self.value = value
    }
}

public struct TuyaStatus: Codable, Equatable, Sendable {
    public let code: String
    public let value: JSONValue

    public init(code: String, value: JSONValue) {
        self.code = code
        self.value = value
    }
}

public struct TuyaDataPointSpecification: Codable, Equatable, Sendable {
    public let code: String
    public let type: String
    public let values: String

    public init(code: String, type: String, values: String) {
        self.code = code
        self.type = type
        self.values = values
    }
}

public struct TuyaSpecification: Codable, Equatable, Sendable {
    public let category: String
    public let functions: [TuyaDataPointSpecification]
    public let status: [TuyaDataPointSpecification]

    public init(
        category: String,
        functions: [TuyaDataPointSpecification],
        status: [TuyaDataPointSpecification]
    ) {
        self.category = category
        self.functions = functions
        self.status = status
    }
}

public typealias TuyaDeviceSpecification = TuyaSpecification
public typealias TuyaFunctionSpecification = TuyaDataPointSpecification

public enum TuyaClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case transport
    case httpStatus(Int)
    case malformedResponse
    case apiFailure
    case authenticationFailure
}

extension TuyaClientError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidEndpoint:
            "The Tuya endpoint is invalid."
        case .transport:
            "The Tuya service could not be reached."
        case let .httpStatus(status):
            "The Tuya service returned HTTP status \(status)."
        case .malformedResponse:
            "The Tuya service returned an invalid response."
        case .apiFailure:
            "The Tuya operation failed."
        case .authenticationFailure:
            "Tuya authentication failed."
        }
    }

    public var errorDescription: String? {
        description
    }
}
