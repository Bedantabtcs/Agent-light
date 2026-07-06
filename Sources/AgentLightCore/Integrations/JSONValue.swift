import Foundation

public struct JSONNumber: Codable, Equatable, Sendable, ExpressibleByIntegerLiteral {
    public typealias IntegerLiteralType = Int64

    public let lexeme: String

    public init(integerLiteral value: Int64) {
        lexeme = String(value)
    }

    public init(lexeme: String) throws {
        guard LosslessJSONParser.isValidNumber(lexeme) else {
            throw JSONValueError.invalidNumber(lexeme)
        }
        self.lexeme = lexeme
    }

    fileprivate init(validatedLexeme: String) {
        lexeme = validatedLexeme
    }

    public static func == (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        guard let left = lhs.canonicalValue, let right = rhs.canonicalValue else {
            return lhs.lexeme == rhs.lexeme
        }
        return left == right
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            lexeme = String(value)
        } else if let value = try? container.decode(UInt64.self) {
            lexeme = String(value)
        } else if let value = try? container.decode(Decimal.self) {
            lexeme = String(describing: value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON number is outside the generic Decoder's lossless range"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value = Int64(lexeme) {
            try container.encode(value)
        } else if let value = UInt64(lexeme) {
            try container.encode(value)
        } else if let value = Decimal(string: lexeme, locale: Locale(identifier: "en_US_POSIX")),
                  let encoded = try? JSONNumber(lexeme: String(describing: value)),
                  encoded == self {
            try container.encode(value)
        } else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "JSON number is outside the generic Encoder's range; use JSONValue.encodedData()"
                )
            )
        }
    }

    private var canonicalValue: CanonicalJSONNumber? {
        var body = lexeme[...]
        let isNegative = body.first == "-"
        if isNegative { body = body.dropFirst() }

        let exponentIndex = body.firstIndex { $0 == "e" || $0 == "E" }
        let mantissa = exponentIndex.map { body[..<$0] } ?? body
        let exponentText = exponentIndex.map { body[body.index(after: $0)...] }
        let exponent: Int
        if let exponentText {
            guard let parsed = Int(exponentText) else { return nil }
            exponent = parsed
        } else {
            exponent = 0
        }

        let decimalIndex = mantissa.firstIndex(of: ".")
        let integerPart = decimalIndex.map { mantissa[..<$0] } ?? mantissa
        let fractionPart = decimalIndex.map { mantissa[mantissa.index(after: $0)...] } ?? Substring()
        var digits = String(integerPart) + String(fractionPart)
        while digits.first == "0" { digits.removeFirst() }
        if digits.isEmpty {
            return CanonicalJSONNumber(isNegative: false, digits: "0", powerOfTen: 0)
        }

        let (initialPower, initialOverflow) = exponent.subtractingReportingOverflow(fractionPart.count)
        guard !initialOverflow else { return nil }
        var power = initialPower
        while digits.last == "0" {
            let (nextPower, overflow) = power.addingReportingOverflow(1)
            guard !overflow else { return nil }
            digits.removeLast()
            power = nextPower
        }
        return CanonicalJSONNumber(isNegative: isNegative, digits: digits, powerOfTen: power)
    }

    var exactInteger: Int? {
        var body = lexeme[...]
        let isNegative = body.first == "-"
        if isNegative { body = body.dropFirst() }

        let exponentIndex = body.firstIndex { $0 == "e" || $0 == "E" }
        let mantissa = exponentIndex.map { body[..<$0] } ?? body
        let exponentText = exponentIndex.map { body[body.index(after: $0)...] }

        var totalDigits = 0
        var fractionDigits = 0
        var trailingZeros = 0
        var isFraction = false
        var hasNonzeroDigit = false
        for character in mantissa {
            if character == "." {
                isFraction = true
                continue
            }
            totalDigits += 1
            if isFraction { fractionDigits += 1 }
            if character == "0" {
                trailingZeros += 1
            } else {
                trailingZeros = 0
                hasNonzeroDigit = true
            }
        }

        if !hasNonzeroDigit { return 0 }
        guard let exponent = Self.parseExponent(exponentText) else { return nil }
        let (power, powerOverflow) = exponent.subtractingReportingOverflow(fractionDigits)
        guard !powerOverflow else { return nil }

        let digitsToConsume: Int
        let zerosToAppend: Int
        if power < 0 {
            guard power != Int.min else { return nil }
            let removedDigits = -power
            guard removedDigits <= trailingZeros else { return nil }
            digitsToConsume = totalDigits - removedDigits
            zerosToAppend = 0
        } else {
            digitsToConsume = totalDigits
            zerosToAppend = power
        }

        let negativeLimit = UInt(Int.max) + 1
        let limit = isNegative ? negativeLimit : UInt(Int.max)
        var magnitude: UInt = 0
        var consumedDigits = 0
        for character in mantissa where character != "." && consumedDigits < digitsToConsume {
            guard let digitValue = character.wholeNumberValue else { return nil }
            let digit = UInt(digitValue)
            guard magnitude <= (limit - digit) / 10 else { return nil }
            magnitude = (magnitude * 10) + digit
            consumedDigits += 1
        }

        guard zerosToAppend <= 19 else { return nil }
        for _ in 0..<zerosToAppend {
            guard magnitude <= limit / 10 else { return nil }
            magnitude *= 10
        }

        if isNegative {
            if magnitude == negativeLimit { return Int.min }
            guard let positive = Int(exactly: magnitude) else { return nil }
            return -positive
        }
        return Int(exactly: magnitude)
    }

    private static func parseExponent(_ text: Substring?) -> Int? {
        guard var text else { return 0 }
        let isNegative = text.first == "-"
        if text.first == "+" || isNegative { text = text.dropFirst() }

        let negativeLimit = UInt(Int.max) + 1
        let limit = isNegative ? negativeLimit : UInt(Int.max)
        var magnitude: UInt = 0
        for character in text {
            guard let digitValue = character.wholeNumberValue else { return nil }
            let digit = UInt(digitValue)
            guard magnitude <= (limit - digit) / 10 else { return nil }
            magnitude = (magnitude * 10) + digit
        }

        if isNegative {
            if magnitude == negativeLimit { return Int.min }
            guard let positive = Int(exactly: magnitude) else { return nil }
            return -positive
        }
        return Int(exactly: magnitude)
    }
}

private struct CanonicalJSONNumber: Equatable {
    let isNegative: Bool
    let digits: String
    let powerOfTen: Int
}

public enum JSONValueError: Error, Equatable {
    case invalidJSON
    case invalidNumber(String)
}

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(JSONNumber)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(JSONNumber.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        guard !data.allSatisfy({ $0.isJSONWhitespace }) else {
            return .object([:])
        }
        var parser = LosslessJSONParser(data: data)
        return try parser.parseRoot()
    }

    public func encodedData() throws -> Data {
        Data(try LosslessJSONWriter().encode(self).utf8)
    }

    public func encodedString() throws -> String {
        try LosslessJSONWriter().encode(self)
    }

    public var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}

private struct LosslessJSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parseRoot() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw JSONValueError.invalidJSON }
        return value
    }

    static func isValidNumber(_ value: String) -> Bool {
        var parser = LosslessJSONParser(data: Data(value.utf8))
        guard (try? parser.parseNumber()) != nil else { return false }
        return parser.index == parser.bytes.count
    }

    private mutating func parseValue() throws -> JSONValue {
        guard let byte = currentByte else { throw JSONValueError.invalidJSON }
        switch byte {
        case UInt8(ascii: "{"):
            return try parseObject()
        case UInt8(ascii: "["):
            return try parseArray()
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try consumeLiteral("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try consumeLiteral("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try consumeLiteral("null")
            return .null
        default:
            return .number(try parseNumber())
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try consume(UInt8(ascii: "{"))
        skipWhitespace()
        var object: [String: JSONValue] = [:]
        if consumeIfPresent(UInt8(ascii: "}")) {
            return .object(object)
        }

        while true {
            guard currentByte == UInt8(ascii: "\"") else { throw JSONValueError.invalidJSON }
            let key = try parseString()
            skipWhitespace()
            try consume(UInt8(ascii: ":"))
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            if consumeIfPresent(UInt8(ascii: "}")) {
                return .object(object)
            }
            try consume(UInt8(ascii: ","))
            skipWhitespace()
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try consume(UInt8(ascii: "["))
        skipWhitespace()
        var array: [JSONValue] = []
        if consumeIfPresent(UInt8(ascii: "]")) {
            return .array(array)
        }

        while true {
            array.append(try parseValue())
            skipWhitespace()
            if consumeIfPresent(UInt8(ascii: "]")) {
                return .array(array)
            }
            try consume(UInt8(ascii: ","))
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        try consume(UInt8(ascii: "\""))
        var escaped = false
        while let byte = currentByte {
            index += 1
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                let encoded = Data(bytes[start..<index])
                guard let value = try? JSONDecoder().decode(String.self, from: encoded) else {
                    throw JSONValueError.invalidJSON
                }
                return value
            } else if byte < 0x20 {
                throw JSONValueError.invalidJSON
            }
        }
        throw JSONValueError.invalidJSON
    }

    private mutating func parseNumber() throws -> JSONNumber {
        let start = index
        _ = consumeIfPresent(UInt8(ascii: "-"))

        if consumeIfPresent(UInt8(ascii: "0")) {
            if currentByte?.isASCIIDigit == true { throw JSONValueError.invalidJSON }
        } else {
            guard currentByte?.isASCIINonzeroDigit == true else { throw JSONValueError.invalidJSON }
            consumeDigits()
        }

        if consumeIfPresent(UInt8(ascii: ".")) {
            guard currentByte?.isASCIIDigit == true else { throw JSONValueError.invalidJSON }
            consumeDigits()
        }

        if currentByte == UInt8(ascii: "e") || currentByte == UInt8(ascii: "E") {
            index += 1
            if currentByte == UInt8(ascii: "+") || currentByte == UInt8(ascii: "-") {
                index += 1
            }
            guard currentByte?.isASCIIDigit == true else { throw JSONValueError.invalidJSON }
            consumeDigits()
        }

        guard let lexeme = String(bytes: bytes[start..<index], encoding: .utf8) else {
            throw JSONValueError.invalidJSON
        }
        return JSONNumber(validatedLexeme: lexeme)
    }

    private mutating func consumeDigits() {
        while currentByte?.isASCIIDigit == true {
            index += 1
        }
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        for byte in literal.utf8 {
            try consume(byte)
        }
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard currentByte == expected else { throw JSONValueError.invalidJSON }
        index += 1
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard currentByte == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while currentByte?.isJSONWhitespace == true {
            index += 1
        }
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }
}

private struct LosslessJSONWriter {
    func encode(_ value: JSONValue) throws -> String {
        try encode(value, indentation: 0)
    }

    private func encode(_ value: JSONValue, indentation: Int) throws -> String {
        switch value {
        case let .object(object):
            guard !object.isEmpty else { return "{}" }
            let contents = try object.keys.sorted().map { key in
                guard let field = object[key] else { throw JSONValueError.invalidJSON }
                let encodedKey = try encodeString(key)
                let encodedValue = try encode(field, indentation: indentation + 2)
                return String(repeating: " ", count: indentation + 2)
                    + "\(encodedKey) : \(encodedValue)"
            }.joined(separator: ",\n")
            return "{\n\(contents)\n\(String(repeating: " ", count: indentation))}"
        case let .array(array):
            guard !array.isEmpty else { return "[]" }
            let contents = try array.map { item in
                String(repeating: " ", count: indentation + 2)
                    + (try encode(item, indentation: indentation + 2))
            }.joined(separator: ",\n")
            return "[\n\(contents)\n\(String(repeating: " ", count: indentation))]"
        case let .string(string):
            return try encodeString(string)
        case let .number(number):
            return number.lexeme
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private func encodeString(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private extension UInt8 {
    var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }

    var isASCIIDigit: Bool {
        self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9")
    }

    var isASCIINonzeroDigit: Bool {
        self >= UInt8(ascii: "1") && self <= UInt8(ascii: "9")
    }
}
