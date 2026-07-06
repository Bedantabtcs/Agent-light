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
        modeCode: String?,
        brightness: ResolvedNumericCapability?,
        temperature: ResolvedNumericCapability?,
        color: ColorEncoding,
        colorConstraints: HSVConstraints
    ) {
        self.powerCode = powerCode
        self.modeCode = modeCode
        brightnessCode = brightness?.code
        temperatureCode = temperature?.code
        self.color = color
        self.colorConstraints = colorConstraints
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
        return BulbBaseline(values: valuesByCode)
    }

    public func restoreCommands(from baseline: BulbBaseline) throws -> [TuyaCommand] {
        try restorableCodes.map { code in
            guard let value = baseline.values[code] else {
                throw CapabilityError.missingStatus(code)
            }
            return TuyaCommand(code: code, value: value)
        }
    }

    private var restorableCodes: [String] {
        [powerCode, modeCode, colorCode, brightnessCode, temperatureCode].compactMap { $0 }
    }
}

public enum CapabilityError: Error, Equatable, Sendable {
    case missingPower
    case missingColor
    case invalidSchema(String)
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
            let constraints = try colorV2Constraints(v2)
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
            try validateLegacyColor(legacy)
            colorResolution = (.hsvLegacy(code: legacy.code), .legacy)
        } else {
            throw CapabilityError.missingColor
        }

        let modeCode: String?
        if let mode = functions["work_mode"] {
            try validateMode(mode)
            modeCode = mode.code
        } else {
            modeCode = nil
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
            modeCode: modeCode,
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

    private static func validateMode(_ specification: TuyaDataPointSpecification) throws {
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
    }

    private static func colorV2Constraints(
        _ specification: TuyaDataPointSpecification
    ) throws -> HSVConstraints {
        guard specification.type == "Json" else {
            throw CapabilityError.invalidSchema(specification.code)
        }
        let object = try objectValues(specification)
        return HSVConstraints(
            hue: try numericConstraint(object["h"], code: specification.code),
            saturation: try numericConstraint(object["s"], code: specification.code),
            value: try numericConstraint(object["v"], code: specification.code)
        )
    }

    private static func validateLegacyColor(
        _ specification: TuyaDataPointSpecification
    ) throws {
        guard specification.type == "Json",
              try objectValues(specification).isEmpty else {
            throw CapabilityError.invalidSchema(specification.code)
        }
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
        guard !overflow, step <= width else {
            throw CapabilityError.invalidSchema(code)
        }
        return NumericConstraint(
            range: minimum ... maximum,
            scale: scale,
            step: step
        )
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value else { return nil }
        return Int(number.lexeme)
    }
}

struct NumericConstraint: Equatable, Sendable {
    let range: ClosedRange<Int>
    let scale: Int
    let step: Int
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
}

struct ResolvedNumericCapability: Equatable, Sendable {
    let code: String
    let constraint: NumericConstraint
}
