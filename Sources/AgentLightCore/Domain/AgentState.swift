public struct RGBColor: Codable, Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }
}

public enum AgentState: String, Codable, Sendable {
    case thinking
    case working
    case needsYou
    case completed
    case error
    case idle

    public var color: RGBColor? {
        switch self {
        case .thinking: RGBColor(hex: 0x8B5CF6)
        case .working: RGBColor(hex: 0x3B82F6)
        case .needsYou: RGBColor(hex: 0xF59E0B)
        case .completed: RGBColor(hex: 0x22C55E)
        case .error: RGBColor(hex: 0xEF4444)
        case .idle: nil
        }
    }
}
