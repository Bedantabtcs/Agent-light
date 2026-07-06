import Foundation

public struct ResolvedLightCapabilities: Equatable, Sendable {
    public enum ColorEncoding: Equatable, Sendable {
        case hsvV2(
            code: String,
            hue: ClosedRange<Int>,
            saturation: ClosedRange<Int>,
            value: ClosedRange<Int>
        )
        case hsvLegacy(code: String)
    }

    public let powerCode: String
    public let modeCode: String?
    public let brightnessCode: String?
    public let temperatureCode: String?
    public let color: ColorEncoding

    let colorConstraints: HSVConstraints
    let modeValues: Set<String>?
    let brightnessConstraint: NumericConstraint?
    let temperatureConstraint: NumericConstraint?

    public var colorCode: String {
        switch color {
        case let .hsvV2(code, _, _, _), let .hsvLegacy(code):
            code
        }
    }

    init(
        powerCode: String,
        mode: ResolvedEnumCapability?,
        brightness: ResolvedNumericCapability?,
        temperature: ResolvedNumericCapability?,
        color: ColorEncoding,
        colorConstraints: HSVConstraints
    ) {
        self.powerCode = powerCode
        modeCode = mode?.code
        brightnessCode = brightness?.code
        temperatureCode = temperature?.code
        self.color = color
        self.colorConstraints = colorConstraints
        modeValues = mode?.values
        brightnessConstraint = brightness?.constraint
        temperatureConstraint = temperature?.constraint
    }

    public func baseline(from status: [TuyaStatus]) throws -> BulbBaseline {
        var valuesByCode: [String: JSONValue] = [:]
        let restorable = restorableCodes
        let restorableSet = Set(restorable)

        for item in status where restorableSet.contains(item.code) {
            guard valuesByCode[item.code] == nil else {
                throw CapabilityError.duplicateStatus(item.code)
            }
            valuesByCode[item.code] = item.value
        }

        for code in restorable where valuesByCode[code] == nil {
            throw CapabilityError.missingStatus(code)
        }
        for code in restorable {
            guard let value = valuesByCode[code] else {
                throw CapabilityError.missingStatus(code)
            }
            try validateStatus(value, code: code)
        }
        return BulbBaseline(values: valuesByCode)
    }

    public func restoreCommands(from baseline: BulbBaseline) throws -> [TuyaCommand] {
        try restoreCodes.map { code in
            guard let value = baseline.values[code] else {
                throw CapabilityError.missingStatus(code)
            }
            try validateStatus(value, code: code)
            let commandValue = code == colorCode ? try colorCommandValue(from: value) : value
            return TuyaCommand(code: code, value: commandValue)
        }
    }

    private var restorableCodes: [String] {
        [powerCode, modeCode, colorCode, brightnessCode, temperatureCode].compactMap { $0 }
    }

    private var restoreCodes: [String] {
        [modeCode, colorCode, brightnessCode, temperatureCode, powerCode].compactMap { $0 }
    }

    private func validateStatus(_ value: JSONValue, code: String) throws {
        if code == powerCode {
            guard case .bool = value else { throw CapabilityError.invalidStatus(code) }
            return
        }
        if code == modeCode {
            guard case let .string(mode) = value,
                  modeValues?.contains(mode) == true else {
                throw CapabilityError.invalidStatus(code)
            }
            return
        }
        if code == colorCode {
            _ = try colorCommandValue(from: value)
            return
        }
        if code == brightnessCode {
            try validateIntegerStatus(value, constraint: brightnessConstraint, code: code)
            return
        }
        if code == temperatureCode {
            try validateIntegerStatus(value, constraint: temperatureConstraint, code: code)
            return
        }
        throw CapabilityError.invalidStatus(code)
    }

    private func validateIntegerStatus(
        _ value: JSONValue,
        constraint: NumericConstraint?,
        code: String
    ) throws {
        guard let constraint,
              let integer = exactInteger(value),
              constraint.contains(integer) else {
            throw CapabilityError.invalidStatus(code)
        }
    }

    private func colorCommandValue(from value: JSONValue) throws -> JSONValue {
        guard case let .string(encodedColor) = value,
              let data = encodedColor.data(using: .utf8),
              let decoded = try? JSONValue.decode(data),
              case let .object(object) = decoded,
              Set(object.keys) == Set(["h", "s", "v"]),
              let hue = exactInteger(object["h"]),
              let saturation = exactInteger(object["s"]),
              let brightness = exactInteger(object["v"]),
              colorConstraints.hue.contains(hue),
              colorConstraints.saturation.contains(saturation),
              colorConstraints.value.contains(brightness) else {
            throw CapabilityError.invalidStatus(colorCode)
        }
        return decoded
    }
}

public enum CapabilityError: Error, Equatable, Sendable {
    case missingPower
    case missingColor
    case invalidSchema(String)
    case invalidStatus(String)
    case missingStatus(String)
    case duplicateStatus(String)
}

extension CapabilityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingPower:
            "The device does not advertise a supported power control."
        case .missingColor:
            "The device does not advertise a supported color control."
        case let .invalidSchema(code):
            "The device advertises an invalid schema for \(code)."
        case let .invalidStatus(code):
            "The device returned an invalid status for \(code)."
        case let .missingStatus(code):
            "The device status is missing \(code)."
        case let .duplicateStatus(code):
            "The device status contains duplicate values for \(code)."
        }
    }
}

public enum TuyaCapabilityResolver {
    private static let recognizedCodes: Set<String> = [
        "switch_led",
        "work_mode",
        "colour_data_v2",
        "colour_data",
        "bright_value_v2",
        "bright_value",
        "temp_value_v2",
        "temp_value"
    ]

    public static func resolve(
        specification: TuyaSpecification
    ) throws -> ResolvedLightCapabilities {
        try resolveCapabilities(specification: specification)
    }

    public static func resolve(
        specification: TuyaSpecification,
        status: [TuyaStatus]
    ) throws -> ResolvedLightCapabilities {
        let capabilities = try resolveCapabilities(specification: specification)
        _ = try capabilities.baseline(from: status)
        return capabilities
    }

    private static func resolveCapabilities(
        specification: TuyaSpecification
    ) throws -> ResolvedLightCapabilities {
        let functions = try indexedFunctions(specification.functions)

        guard let power = functions["switch_led"] else {
            throw CapabilityError.missingPower
        }
        try validatePower(power)

        let colorResolution: (ResolvedLightCapabilities.ColorEncoding, HSVConstraints)
        if let v2 = functions["colour_data_v2"] {
            let constraints = try colorConstraints(v2, fixed: .v2)
            colorResolution = (
                .hsvV2(
                    code: v2.code,
                    hue: constraints.hue.range,
                    saturation: constraints.saturation.range,
                    value: constraints.value.range
                ),
                constraints
            )
        } else if let legacy = functions["colour_data"] {
            let constraints = try colorConstraints(legacy, fixed: .legacy)
            colorResolution = (.hsvLegacy(code: legacy.code), constraints)
        } else {
            throw CapabilityError.missingColor
        }

        let modeCapability: ResolvedEnumCapability?
        if let mode = functions["work_mode"] {
            let values = try modeValues(mode)
            modeCapability = ResolvedEnumCapability(code: mode.code, values: values)
        } else {
            modeCapability = nil
        }

        let brightness = try resolveNumeric(
            functions: functions,
            preferredCodes: ["bright_value_v2", "bright_value"]
        )
        let temperature = try resolveNumeric(
            functions: functions,
            preferredCodes: ["temp_value_v2", "temp_value"]
        )
        return ResolvedLightCapabilities(
            powerCode: power.code,
            mode: modeCapability,
            brightness: brightness,
            temperature: temperature,
            color: colorResolution.0,
            colorConstraints: colorResolution.1
        )
    }

    private static func indexedFunctions(
        _ functions: [TuyaDataPointSpecification]
    ) throws -> [String: TuyaDataPointSpecification] {
        var indexed: [String: TuyaDataPointSpecification] = [:]
        for function in functions where recognizedCodes.contains(function.code) {
            guard indexed[function.code] == nil else {
                throw CapabilityError.invalidSchema(function.code)
            }
            indexed[function.code] = function
        }
        return indexed
    }

    private static func validatePower(_ specification: TuyaDataPointSpecification) throws {
        guard specification.type == "Boolean" else {
            throw CapabilityError.invalidSchema(specification.code)
        }
        _ = try objectValues(specification)
    }

    private static func modeValues(_ specification: TuyaDataPointSpecification) throws -> Set<String> {
        guard specification.type == "Enum" else {
            throw CapabilityError.invalidSchema(specification.code)
        }
        let object = try objectValues(specification)
        guard case let .array(range)? = object["range"],
              !range.isEmpty,
              range.allSatisfy({ $0.stringValue != nil }),
              range.contains(.string("colour")) else {
            throw CapabilityError.invalidSchema(specification.code)
        }
        return Set(range.compactMap(\.stringValue))
    }

    private static func colorConstraints(
        _ specification: TuyaDataPointSpecification,
        fixed: HSVConstraints
    ) throws -> HSVConstraints {
        guard specification.type == "Json" else {
            throw CapabilityError.invalidSchema(specification.code)
        }
        let object = try objectValues(specification)
        if object.isEmpty { return fixed }
        guard Set(object.keys) == Set(["h", "s", "v"]) else {
            throw CapabilityError.invalidSchema(specification.code)
        }
        return HSVConstraints(
            hue: try numericConstraint(object["h"], code: specification.code),
            saturation: try numericConstraint(object["s"], code: specification.code),
            value: try numericConstraint(object["v"], code: specification.code)
        )
    }

    private static func resolveNumeric(
        functions: [String: TuyaDataPointSpecification],
        preferredCodes: [String]
    ) throws -> ResolvedNumericCapability? {
        for code in preferredCodes where functions[code] != nil {
            guard let specification = functions[code], specification.type == "Integer" else {
                throw CapabilityError.invalidSchema(code)
            }
            return ResolvedNumericCapability(
                code: code,
                constraint: try numericConstraint(
                    .object(try objectValues(specification)),
                    code: code
                )
            )
        }
        return nil
    }

    private static func objectValues(
        _ specification: TuyaDataPointSpecification
    ) throws -> [String: JSONValue] {
        guard let data = specification.values.data(using: .utf8),
              let decoded = try? JSONValue.decode(data),
              case let .object(object) = decoded else {
            throw CapabilityError.invalidSchema(specification.code)
        }
        return object
    }

    private static func numericConstraint(
        _ value: JSONValue?,
        code: String
    ) throws -> NumericConstraint {
        guard case let .object(object)? = value,
              let minimum = integer(object["min"]),
              let maximum = integer(object["max"]),
              let scale = integer(object["scale"]),
              let step = integer(object["step"]),
              minimum >= 0,
              maximum > minimum,
              maximum <= 1_000_000,
              scale >= 0,
              scale <= 9,
              step > 0 else {
            throw CapabilityError.invalidSchema(code)
        }
        let (width, overflow) = maximum.subtractingReportingOverflow(minimum)
        guard !overflow, step <= width, width % step == 0 else {
            throw CapabilityError.invalidSchema(code)
        }
        return NumericConstraint(
            range: minimum ... maximum,
            scale: scale,
            step: step
        )
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        exactInteger(value)
    }
}

private func exactInteger(_ value: JSONValue?) -> Int? {
    guard case let .number(number)? = value,
          let decimal = Decimal(string: number.lexeme, locale: Locale(identifier: "en_US_POSIX")) else {
        return nil
    }
    var source = decimal
    var rounded = Decimal()
    NSDecimalRound(&rounded, &source, 0, .plain)
    guard rounded == decimal,
          rounded >= Decimal(Int64.min),
          rounded <= Decimal(Int64.max) else {
        return nil
    }
    return Int(NSDecimalNumber(decimal: rounded).int64Value)
}

struct NumericConstraint: Equatable, Sendable {
    let range: ClosedRange<Int>
    let scale: Int
    let step: Int

    func contains(_ value: Int) -> Bool {
        range.contains(value) && (value - range.lowerBound) % step == 0
    }
}

struct HSVConstraints: Equatable, Sendable {
    let hue: NumericConstraint
    let saturation: NumericConstraint
    let value: NumericConstraint

    static let legacy = HSVConstraints(
        hue: NumericConstraint(range: 0 ... 360, scale: 0, step: 1),
        saturation: NumericConstraint(range: 0 ... 255, scale: 0, step: 1),
        value: NumericConstraint(range: 0 ... 255, scale: 0, step: 1)
    )

    static let v2 = HSVConstraints(
        hue: NumericConstraint(range: 0 ... 360, scale: 0, step: 1),
        saturation: NumericConstraint(range: 0 ... 1_000, scale: 0, step: 1),
        value: NumericConstraint(range: 0 ... 1_000, scale: 0, step: 1)
    )
}

struct ResolvedEnumCapability: Equatable, Sendable {
    let code: String
    let values: Set<String>
}

struct ResolvedNumericCapability: Equatable, Sendable {
    let code: String
    let constraint: NumericConstraint
}
