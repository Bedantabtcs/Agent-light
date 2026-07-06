public struct DesiredLightState: Codable, Equatable, Sendable {
    public let color: RGBColor
    public let value: Double

    public init(color: RGBColor, value: Double = 0.8) {
        self.color = color
        self.value = min(max(value, 0), 1)
    }
}

public struct BulbBaseline: Codable, Equatable, Sendable {
    public let values: [String: JSONValue]

    public init(values: [String: JSONValue]) {
        self.values = values
    }
}
