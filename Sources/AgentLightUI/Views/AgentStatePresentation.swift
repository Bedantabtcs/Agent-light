import AgentLightCore

extension AgentState {
    var displayName: String {
        switch self {
        case .thinking: "Thinking"
        case .reading: "Reading"
        case .editing: "Editing"
        case .testing: "Testing"
        case .working: "Working"
        case .needsYou: "Needs You"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .error: "Error"
        case .idle: "Idle"
        }
    }

    var symbolName: String {
        switch self {
        case .thinking: "brain.head.profile"
        case .reading: "book.closed.fill"
        case .editing: "pencil"
        case .testing: "checkmark.seal.fill"
        case .working: "hammer.fill"
        case .needsYou: "person.crop.circle.badge.exclamationmark"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.octagon.fill"
        case .error: "exclamationmark.triangle.fill"
        case .idle: "moon.zzz"
        }
    }

    static let ambientBulbSymbolName = "lightbulb.led.fill"
}
