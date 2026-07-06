import Foundation

public enum LightColorMapper {
    public static func commands(
        for state: DesiredLightState,
        capabilities: ResolvedLightCapabilities
    ) throws -> [TuyaCommand] {
        let hsv = normalizedHSV(for: state.color)
        let constraints = capabilities.colorConstraints
        let roundedHue = hsv.hue.rounded(.toNearestOrAwayFromZero)
        let wrappedHue = roundedHue >= 360 ? 0 : hsv.hue
        let payload = JSONValue.object([
            "h": integerValue(scale(wrappedHue / 360, to: constraints.hue)),
            "s": integerValue(scale(hsv.saturation, to: constraints.saturation)),
            "v": integerValue(scale(state.value, to: constraints.value))
        ])

        var commands = [TuyaCommand(code: capabilities.powerCode, value: .bool(true))]
        if let modeCode = capabilities.modeCode {
            commands.append(TuyaCommand(code: modeCode, value: .string("colour")))
        }
        commands.append(TuyaCommand(code: capabilities.colorCode, value: payload))
        return commands
    }

    private static func normalizedHSV(for color: RGBColor) -> (
        hue: Double,
        saturation: Double
    ) {
        let red = Double(color.red) / 255
        let green = Double(color.green) / 255
        let blue = Double(color.blue) / 255
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum

        guard delta > 0, maximum > 0 else {
            return (0, 0)
        }

        let segment: Double
        if maximum == red {
            segment = (green - blue) / delta
        } else if maximum == green {
            segment = ((blue - red) / delta) + 2
        } else {
            segment = ((red - green) / delta) + 4
        }
        let degrees = segment * 60
        let hue = degrees < 0 ? degrees + 360 : degrees
        return (hue, delta / maximum)
    }

    private static func scale(
        _ normalizedValue: Double,
        to constraint: NumericConstraint
    ) -> Int {
        let clamped = min(max(normalizedValue, 0), 1)
        let minimum = constraint.range.lowerBound
        let width = constraint.range.upperBound - minimum
        let raw = Double(minimum) + (clamped * Double(width))
        let steps = ((raw - Double(minimum)) / Double(constraint.step))
            .rounded(.toNearestOrAwayFromZero)
        let stepped = Double(minimum) + (steps * Double(constraint.step))
        return min(max(Int(stepped), minimum), constraint.range.upperBound)
    }

    private static func integerValue(_ value: Int) -> JSONValue {
        .number(JSONNumber(integerLiteral: Int64(value)))
    }
}
