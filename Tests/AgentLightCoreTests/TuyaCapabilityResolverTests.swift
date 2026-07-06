import Foundation
import XCTest
@testable import AgentLightCore

final class TuyaCapabilityResolverTests: XCTestCase {
    func testAcceptsDocumentedFixedV2SchemaFromSanitizedFixture() throws {
        let specification = try specificationFixture(named: "tuya-standard-specification")

        let capabilities = try TuyaCapabilityResolver.resolve(specification: specification)
        let payload = try colorPayload(from: LightColorMapper.commands(
            for: DesiredLightState(color: RGBColor(hex: 0x00FF00)),
            capabilities: capabilities
        ))

        XCTAssertEqual(capabilities.colorCode, "colour_data_v2")
        XCTAssertEqual(payload, hsv(h: 120, s: 1000, v: 800))
    }

    func testAcceptsDocumentedNestedLegacySchemaFromSanitizedFixture() throws {
        let specification = try specificationFixture(named: "tuya-nested-specification")

        let capabilities = try TuyaCapabilityResolver.resolve(specification: specification)
        let payload = try colorPayload(from: LightColorMapper.commands(
            for: DesiredLightState(color: RGBColor(hex: 0x00FF00)),
            capabilities: capabilities
        ))

        XCTAssertEqual(capabilities.colorCode, "colour_data")
        XCTAssertEqual(payload, hsv(h: 120, s: 255, v: 204))
    }

    func testV2CapabilitiesBuildApprovedThinkingCommandInDeterministicOrder() throws {
        let capabilities = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(
                functions: [power(), mode(), colorV2(), brightnessV2(), temperature()]
            )
        )

        let commands = try LightColorMapper.commands(
            for: DesiredLightState(color: RGBColor(hex: 0x8B5CF6)),
            capabilities: capabilities
        )

        XCTAssertEqual(commands, [
            TuyaCommand(code: "switch_led", value: .bool(true)),
            TuyaCommand(code: "work_mode", value: .string("colour")),
            TuyaCommand(code: "colour_data_v2", value: hsv(h: 258, s: 626, v: 800))
        ])
    }

    func testLegacyCapabilitiesUseFixedLegacyHSVEncoding() throws {
        let capabilities = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(functions: [power(), colorLegacy()])
        )

        let commands = try LightColorMapper.commands(
            for: DesiredLightState(color: RGBColor(hex: 0x3B82F6)),
            capabilities: capabilities
        )

        XCTAssertEqual(commands, [
            TuyaCommand(code: "switch_led", value: .bool(true)),
            TuyaCommand(code: "colour_data", value: hsv(h: 217, s: 194, v: 204))
        ])
    }

    func testV2TakesPrecedenceOverLegacyRegardlessOfSpecificationOrder() throws {
        let capabilities = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(functions: [colorLegacy(), power(), colorV2()])
        )

        XCTAssertEqual(capabilities.colorCode, "colour_data_v2")
        XCTAssertEqual(
            try LightColorMapper.commands(
                for: DesiredLightState(color: RGBColor(hex: 0x22C55E)),
                capabilities: capabilities
            ).map(\.code),
            ["switch_led", "colour_data_v2"]
        )
    }

    func testRejectsMissingRequiredPowerAndColorCapabilities() {
        XCTAssertThrowsCapabilityError(
            .missingPower,
            try TuyaCapabilityResolver.resolve(
                specification: fixtureSpecification(functions: [colorV2()])
            )
        )
        XCTAssertThrowsCapabilityError(
            .missingColor,
            try TuyaCapabilityResolver.resolve(
                specification: fixtureSpecification(functions: [power(), temperature()])
            )
        )
    }

    func testRejectsMalformedUnknownAndUnsafeSchemasWithSanitizedErrors() {
        let invalidFixtures: [(TuyaDataPointSpecification, String)] = [
            (colorV2(values: "not-json"), "colour_data_v2"),
            (colorV2(type: "String"), "colour_data_v2"),
            (colorV2(values: #"{"h":{"min":0,"max":360,"scale":0,"step":1}}"#), "colour_data_v2"),
            (colorV2(values: colorSchema(h: (360, 0, 0, 1))), "colour_data_v2"),
            (colorV2(values: colorSchema(s: (0, 1000, -1, 1))), "colour_data_v2"),
            (colorV2(values: colorSchema(v: (0, 1000, 0, 0))), "colour_data_v2"),
            (power(type: "Integer"), "switch_led"),
            (mode(values: #"{"range":["white","scene"]}"#), "work_mode"),
            (brightnessV2(values: #"{"min":0,"max":1000,"scale":0,"step":0}"#), "bright_value_v2")
        ]

        for (candidate, expectedCode) in invalidFixtures {
            var functions = [power(), colorV2()]
            functions.removeAll { $0.code == candidate.code }
            functions.append(candidate)
            do {
                _ = try TuyaCapabilityResolver.resolve(
                    specification: fixtureSpecification(functions: functions)
                )
                XCTFail("Expected invalid schema for \(expectedCode)")
            } catch let error as CapabilityError {
                XCTAssertEqual(error, .invalidSchema(expectedCode))
                XCTAssertFalse(error.localizedDescription.contains(candidate.values))
            } catch {
                XCTFail("Unexpected error type: \(type(of: error))")
            }
        }
    }

    func testRejectsDuplicateKnownFunctionAndMalformedPreferredColorInsteadOfFallingBack() {
        XCTAssertThrowsCapabilityError(
            .invalidSchema("switch_led"),
            try TuyaCapabilityResolver.resolve(
                specification: fixtureSpecification(functions: [power(), power(), colorV2()])
            )
        )
        XCTAssertThrowsCapabilityError(
            .invalidSchema("colour_data_v2"),
            try TuyaCapabilityResolver.resolve(
                specification: fixtureSpecification(
                    functions: [power(), colorLegacy(), colorV2(values: "{")]
                )
            )
        )
    }

    func testRejectsMalformedPreferredNumericSchemasInsteadOfFallingBack() {
        XCTAssertThrowsCapabilityError(
            .invalidSchema("bright_value_v2"),
            try TuyaCapabilityResolver.resolve(
                specification: fixtureSpecification(functions: [
                    power(), colorV2(), brightnessLegacy(),
                    brightnessV2(values: #"{"min":10,"max":1000,"scale":0,"step":0}"#)
                ])
            )
        )
        XCTAssertThrowsCapabilityError(
            .invalidSchema("temp_value_v2"),
            try TuyaCapabilityResolver.resolve(
                specification: fixtureSpecification(functions: [
                    power(), colorV2(), temperature(),
                    temperatureV2(values: "not-json")
                ])
            )
        )
    }

    func testRejectsStepConstraintThatDoesNotAlignMaximumFromNonzeroMinimum() {
        XCTAssertThrowsCapabilityError(
            .invalidSchema("colour_data_v2"),
            try TuyaCapabilityResolver.resolve(
                specification: fixtureSpecification(functions: [
                    power(),
                    colorV2(values: colorSchema(s: (10, 100, 0, 16)))
                ])
            )
        )
    }

    func testSchemaIntegerFieldsRejectFractionsBeyondFoundationDecimalPrecision() {
        let fraction = "1.0000000000000000000000000000000000000001"
        let nearZero = "0.0000000000000000000000000000000000000001"
        let schemas = [
            colorSchemaLexemes(hMin: fraction),
            colorSchemaLexemes(hMax: "360.0000000000000000000000000000000000000001"),
            colorSchemaLexemes(hScale: nearZero),
            colorSchemaLexemes(hStep: fraction)
        ]

        for schema in schemas {
            XCTAssertThrowsCapabilityError(
                .invalidSchema("colour_data_v2"),
                try TuyaCapabilityResolver.resolve(
                    specification: fixtureSpecification(functions: [power(), colorV2(values: schema)])
                )
            )
        }
    }

    func testSchemaAndLiveStatusesAcceptExactIntegralExponentFormsAndNegativeZero() throws {
        let capabilities = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(functions: [
                power(),
                colorV2(values: colorSchemaLexemes(
                    hMin: "-0", hMax: "36e1", hScale: "0.0", hStep: "10e-1"
                )),
                brightnessV2(values: #"{"min":10e-1,"max":1e3,"scale":-0,"step":1.0}"#),
                temperature()
            ])
        )
        let statuses = [
            TuyaStatus(code: "switch_led", value: .bool(false)),
            TuyaStatus(code: "colour_data_v2", value: .string(#"{"h":2.58e2,"s":6260e-1,"v":8e2}"#)),
            TuyaStatus(code: "bright_value_v2", value: .number(try JSONNumber(lexeme: "8.00e2"))),
            TuyaStatus(code: "temp_value", value: .number(try JSONNumber(lexeme: "42e1")))
        ]

        let baseline = try capabilities.baseline(from: statuses)
        let restore = try capabilities.restoreCommands(from: baseline)

        XCTAssertEqual(restore.map(\.code), [
            "colour_data_v2", "bright_value_v2", "temp_value", "switch_led"
        ])
    }

    func testLiveNumericStatusesRejectFractionsBeyondFoundationDecimalPrecision() throws {
        let capabilities = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(functions: [
                power(), colorV2(), brightnessV2(), temperature()
            ])
        )
        let fraction = "1.0000000000000000000000000000000000000001"
        let valid = [
            TuyaStatus(code: "switch_led", value: .bool(false)),
            TuyaStatus(code: "colour_data_v2", value: .string(#"{"h":1,"s":1,"v":1}"#)),
            TuyaStatus(code: "bright_value_v2", value: .number(10)),
            TuyaStatus(code: "temp_value", value: .number(10))
        ]
        let invalid: [(String, JSONValue)] = [
            ("bright_value_v2", .number(try JSONNumber(lexeme: fraction))),
            ("temp_value", .number(try JSONNumber(lexeme: fraction))),
            ("colour_data_v2", .string(#"{"h":#(fraction),"s":1,"v":1}"#)),
            ("colour_data_v2", .string(#"{"h":1,"s":#(fraction),"v":1}"#)),
            ("colour_data_v2", .string(#"{"h":1,"s":1,"v":#(fraction)}"#))
        ]

        for (code, value) in invalid {
            let statuses = valid.map { status in
                status.code == code ? TuyaStatus(code: code, value: value) : status
            }
            XCTAssertThrowsCapabilityError(
                .invalidStatus(code),
                try capabilities.baseline(from: statuses)
            )
        }
    }

    func testAdvertisedRangesWithNonzeroMinimumScaleAndStepClampAndRoundDeterministically() throws {
        let schema = colorSchema(
            h: (100, 3_700, 2, 25),
            s: (100, 900, 1, 25),
            v: (200, 1_200, 1, 50)
        )
        let capabilities = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(
                functions: [power(), colorV2(values: schema)]
            )
        )

        let green = try colorPayload(
            from: LightColorMapper.commands(
                for: DesiredLightState(color: RGBColor(hex: 0x00FF00), value: 1),
                capabilities: capabilities
            )
        )
        let black = try colorPayload(
            from: LightColorMapper.commands(
                for: DesiredLightState(color: RGBColor(hex: 0x000000), value: 0),
                capabilities: capabilities
            )
        )

        XCTAssertEqual(green, hsv(h: 1_300, s: 900, v: 1_200))
        XCTAssertEqual(black, hsv(h: 100, s: 100, v: 200))
    }

    func testApprovedPaletteMapsToExpectedV2HSVAtEightyPercentValue() throws {
        let capabilities = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(functions: [power(), colorV2()])
        )
        let expected: [(UInt32, JSONValue)] = [
            (0x8B5CF6, hsv(h: 258, s: 626, v: 800)),
            (0x3B82F6, hsv(h: 217, s: 760, v: 800)),
            (0xF59E0B, hsv(h: 38, s: 955, v: 800)),
            (0x22C55E, hsv(h: 142, s: 827, v: 800)),
            (0xEF4444, hsv(h: 0, s: 715, v: 800))
        ]

        for (hex, expectedPayload) in expected {
            XCTAssertEqual(
                try colorPayload(
                    from: LightColorMapper.commands(
                        for: DesiredLightState(color: RGBColor(hex: hex)),
                        capabilities: capabilities
                    )
                ),
                expectedPayload
            )
        }
    }

    func testAchromaticColorUsesMinimumHueAndSaturationAndNearRedWrapsHue() throws {
        let capabilities = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(functions: [power(), colorV2()])
        )

        let gray = try colorPayload(
            from: LightColorMapper.commands(
                for: DesiredLightState(color: RGBColor(hex: 0x808080)),
                capabilities: capabilities
            )
        )
        let wrappedRed = try colorPayload(
            from: LightColorMapper.commands(
                for: DesiredLightState(color: RGBColor(hex: 0xFF0001)),
                capabilities: capabilities
            )
        )

        XCTAssertEqual(gray, hsv(h: 0, s: 0, v: 800))
        XCTAssertEqual(wrappedRed, hsv(h: 0, s: 1000, v: 800))
    }

    func testOptionalModeBrightnessAndTemperatureAreResolvedButBrightnessIsNotDuplicatedForHSV() throws {
        let withoutOptionals = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(functions: [power(), colorV2()])
        )
        XCTAssertNil(withoutOptionals.modeCode)
        XCTAssertNil(withoutOptionals.brightnessCode)
        XCTAssertNil(withoutOptionals.temperatureCode)
        XCTAssertEqual(
            try LightColorMapper.commands(
                for: DesiredLightState(color: RGBColor(hex: 0xEF4444)),
                capabilities: withoutOptionals
            ).map(\.code),
            ["switch_led", "colour_data_v2"]
        )

        let withOptionals = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(
                functions: [power(), mode(), colorV2(), brightnessV2(), temperature()]
            )
        )
        XCTAssertEqual(withOptionals.modeCode, "work_mode")
        XCTAssertEqual(withOptionals.brightnessCode, "bright_value_v2")
        XCTAssertEqual(withOptionals.temperatureCode, "temp_value")
        XCTAssertEqual(
            try LightColorMapper.commands(
                for: DesiredLightState(color: RGBColor(hex: 0xEF4444)),
                capabilities: withOptionals
            ).map(\.code),
            ["switch_led", "work_mode", "colour_data_v2"]
        )
    }

    func testBaselineRejectsDuplicateOrMissingResolvedStatusValues() throws {
        let capabilities = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(functions: [power(), mode(), colorV2()])
        )

        XCTAssertThrowsCapabilityError(
            .missingStatus("work_mode"),
            try capabilities.baseline(from: [
                TuyaStatus(code: "switch_led", value: .bool(true)),
                TuyaStatus(code: "colour_data_v2", value: .string("color"))
            ])
        )
        XCTAssertThrowsCapabilityError(
            .duplicateStatus("switch_led"),
            try capabilities.baseline(from: [
                TuyaStatus(code: "switch_led", value: .bool(true)),
                TuyaStatus(code: "switch_led", value: .bool(false)),
                TuyaStatus(code: "work_mode", value: .string("colour")),
                TuyaStatus(code: "colour_data_v2", value: .string("color"))
            ])
        )
    }

    func testBaselineKeepsRawColorStringAndRestoreParsesObjectWithPowerLast() throws {
        let capabilities = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(
                functions: [temperature(), colorV2(), brightnessV2(), mode(), power()]
            )
        )
        let exactColorString = #"{"h":258,"s":626,"v":8.00e2}"#
        let exactBrightness = JSONValue.number(try JSONNumber(lexeme: "8.00e2"))
        let statuses = [
            TuyaStatus(code: "temp_value", value: .number(420)),
            TuyaStatus(code: "bright_value_v2", value: exactBrightness),
            TuyaStatus(code: "colour_data_v2", value: .string(exactColorString)),
            TuyaStatus(code: "work_mode", value: .string("scene")),
            TuyaStatus(code: "switch_led", value: .bool(false)),
            TuyaStatus(code: "unrelated", value: .array([.number(1)]))
        ]

        let baseline = try capabilities.baseline(from: statuses)
        let restored = try capabilities.restoreCommands(from: baseline)

        XCTAssertEqual(restored.map(\.code), [
            "work_mode", "colour_data_v2", "bright_value_v2", "temp_value", "switch_led"
        ])
        XCTAssertEqual(baseline.values["colour_data_v2"], .string(exactColorString))
        XCTAssertEqual(restored[0].value, .string("scene"))
        XCTAssertEqual(restored[1].value, try JSONValue.decode(Data(exactColorString.utf8)))
        XCTAssertEqual(restored[2].value, exactBrightness)
        XCTAssertEqual(restored[3].value, .number(420))
        XCTAssertEqual(restored[4].value, .bool(false))
        guard case let .number(restoredNumber) = restored[2].value else {
            return XCTFail("Expected exact number")
        }
        XCTAssertEqual(restoredNumber.lexeme, "8.00e2")
        XCTAssertNil(baseline.values["unrelated"])
    }

    func testBaselineValidatesEveryResolvedStatusAgainstItsSchema() throws {
        let steppedBrightness = brightnessV2(
            values: #"{"min":10,"max":1000,"scale":0,"step":10}"#
        )
        let capabilities = try TuyaCapabilityResolver.resolve(
            specification: fixtureSpecification(
                functions: [power(), mode(), colorV2(), steppedBrightness, temperature()]
            )
        )
        let valid = try statusFixture(named: "tuya-color-status")
        _ = try capabilities.baseline(from: valid)

        let invalidValues: [(String, JSONValue)] = [
            ("switch_led", .number(1)),
            ("work_mode", .string("unsupported")),
            ("bright_value_v2", .number(15)),
            ("bright_value_v2", .number(try JSONNumber(lexeme: "10.5"))),
            ("bright_value_v2", .number(1_010)),
            ("temp_value", .null),
            ("colour_data_v2", .object(["h": .number(1), "s": .number(1), "v": .number(1)])),
            ("colour_data_v2", .string("not-json")),
            ("colour_data_v2", .string("[]")),
            ("colour_data_v2", .string(#"{"h":258,"s":626}"#)),
            ("colour_data_v2", .string(#"{"h":258,"s":626,"v":800,"extra":1}"#)),
            ("colour_data_v2", .string(#"{"h":361,"s":626,"v":800}"#)),
            ("colour_data_v2", .string(#"{"h":258,"s":626.5,"v":800}"#))
        ]

        for (code, value) in invalidValues {
            let statuses = valid.map { status in
                status.code == code ? TuyaStatus(code: code, value: value) : status
            }
            XCTAssertThrowsCapabilityError(
                .invalidStatus(code),
                try capabilities.baseline(from: statuses)
            )
        }
    }

    func testResolveWithStatusValidatesAndCapturesTheSameRestorableSet() throws {
        let specification = fixtureSpecification(functions: [power(), colorV2()])
        let statuses = [
            TuyaStatus(code: "switch_led", value: .bool(true)),
            TuyaStatus(code: "colour_data_v2", value: .string(#"{"h":0,"s":0,"v":0}"#))
        ]

        let capabilities = try TuyaCapabilityResolver.resolve(
            specification: specification,
            status: statuses
        )

        XCTAssertEqual(try capabilities.baseline(from: statuses).values, [
            "switch_led": .bool(true),
            "colour_data_v2": .string(#"{"h":0,"s":0,"v":0}"#)
        ])
    }

    func testResolveWithExplicitEmptyStatusRejectsMissingRestorableValues() {
        XCTAssertThrowsCapabilityError(
            .missingStatus("switch_led"),
            try TuyaCapabilityResolver.resolve(
                specification: fixtureSpecification(functions: [power(), colorV2()]),
                status: []
            )
        )
    }
}

private func fixtureSpecification(
    functions: [TuyaDataPointSpecification]
) -> TuyaSpecification {
    TuyaSpecification(category: "dj", functions: functions, status: functions)
}

private func power(type: String = "Boolean") -> TuyaDataPointSpecification {
    TuyaDataPointSpecification(code: "switch_led", type: type, values: "{}")
}

private func mode(
    values: String = #"{"range":["white","colour","scene","music"]}"#
) -> TuyaDataPointSpecification {
    TuyaDataPointSpecification(code: "work_mode", type: "Enum", values: values)
}

private func colorV2(
    type: String = "Json",
    values: String = colorSchema()
) -> TuyaDataPointSpecification {
    TuyaDataPointSpecification(code: "colour_data_v2", type: type, values: values)
}

private func colorLegacy() -> TuyaDataPointSpecification {
    TuyaDataPointSpecification(code: "colour_data", type: "Json", values: "{}")
}

private func brightnessLegacy() -> TuyaDataPointSpecification {
    TuyaDataPointSpecification(
        code: "bright_value",
        type: "Integer",
        values: #"{"min":10,"max":255,"scale":0,"step":1}"#
    )
}

private func brightnessV2(
    values: String = #"{"min":10,"max":1000,"scale":0,"step":1}"#
) -> TuyaDataPointSpecification {
    TuyaDataPointSpecification(code: "bright_value_v2", type: "Integer", values: values)
}

private func temperature() -> TuyaDataPointSpecification {
    TuyaDataPointSpecification(
        code: "temp_value",
        type: "Integer",
        values: #"{"min":0,"max":1000,"scale":0,"step":1}"#
    )
}

private func temperatureV2(values: String) -> TuyaDataPointSpecification {
    TuyaDataPointSpecification(code: "temp_value_v2", type: "Integer", values: values)
}

private func specificationFixture(named name: String) throws -> TuyaSpecification {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
    return try JSONDecoder().decode(TuyaSpecification.self, from: Data(contentsOf: url))
}

private func statusFixture(named name: String) throws -> [TuyaStatus] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
    let value = try JSONValue.decode(Data(contentsOf: url))
    guard case let .array(items) = value else { throw TestError.invalidFixture }
    return try items.map { item in
        guard case let .object(object) = item,
              case let .string(code)? = object["code"],
              let statusValue = object["value"] else {
            throw TestError.invalidFixture
        }
        return TuyaStatus(code: code, value: statusValue)
    }
}

private func colorSchema(
    h: (Int, Int, Int, Int) = (0, 360, 0, 1),
    s: (Int, Int, Int, Int) = (0, 1000, 0, 1),
    v: (Int, Int, Int, Int) = (0, 1000, 0, 1)
) -> String {
    """
    {"h":{"min":\(h.0),"max":\(h.1),"scale":\(h.2),"step":\(h.3)},\
    "s":{"min":\(s.0),"max":\(s.1),"scale":\(s.2),"step":\(s.3)},\
    "v":{"min":\(v.0),"max":\(v.1),"scale":\(v.2),"step":\(v.3)}}
    """
}

private func colorSchemaLexemes(
    hMin: String = "0",
    hMax: String = "360",
    hScale: String = "0",
    hStep: String = "1"
) -> String {
    """
    {"h":{"min":\(hMin),"max":\(hMax),"scale":\(hScale),"step":\(hStep)},\
    "s":{"min":0,"max":1000,"scale":0,"step":1},\
    "v":{"min":0,"max":1000,"scale":0,"step":1}}
    """
}

private func hsv(h: Int, s: Int, v: Int) -> JSONValue {
    .object([
        "h": .number(JSONNumber(integerLiteral: Int64(h))),
        "s": .number(JSONNumber(integerLiteral: Int64(s))),
        "v": .number(JSONNumber(integerLiteral: Int64(v)))
    ])
}

private func colorPayload(from commands: [TuyaCommand]) throws -> JSONValue {
    guard let payload = commands.first(where: { $0.code.hasPrefix("colour_data") })?.value else {
        throw TestError.missingColorCommand
    }
    return payload
}

private enum TestError: Error {
    case missingColorCommand
    case invalidFixture
}

private func XCTAssertThrowsCapabilityError<T>(
    _ expected: CapabilityError,
    _ expression: @autoclosure () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        _ = try expression()
        XCTFail("Expected CapabilityError", file: file, line: line)
    } catch let error as CapabilityError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
    }
}
