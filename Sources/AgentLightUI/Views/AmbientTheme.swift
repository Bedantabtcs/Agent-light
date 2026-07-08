import AgentLightCore
import SwiftUI

private struct AmbientReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct AmbientHighContrastOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var ambientReduceMotionOverride: Bool? {
        get { self[AmbientReduceMotionOverrideKey.self] }
        set { self[AmbientReduceMotionOverrideKey.self] = newValue }
    }

    var ambientHighContrastOverride: Bool? {
        get { self[AmbientHighContrastOverrideKey.self] }
        set { self[AmbientHighContrastOverrideKey.self] = newValue }
    }
}

extension View {
    func ambientAccessibilityOverrides(reduceMotion: Bool, highContrast: Bool) -> some View {
        environment(\.ambientReduceMotionOverride, reduceMotion)
            .environment(\.ambientHighContrastOverride, highContrast)
    }
}

enum AmbientTheme {
    enum Spacing {
        static let compact: CGFloat = 6
        static let standard: CGFloat = 12
        static let section: CGFloat = 18
        static let window: CGFloat = 20
    }

    enum Radius {
        static let control: CGFloat = 10
        static let card: CGFloat = 16
        static let window: CGFloat = 20
    }

    static let windowWidth: CGFloat = 380
    static let windowHeight: CGFloat = 540
    static let background = Color(red: 0.025, green: 0.035, blue: 0.075)
    static let surface = Color.white.opacity(0.075)
    static let strongSurface = Color.white.opacity(0.12)
    static let separator = Color.white.opacity(0.12)

    static func stateColor(_ state: AgentState, highContrast: Bool = false) -> Color {
        guard let rgb = state.color else {
            return highContrast ? .white : Color(red: 0.58, green: 0.63, blue: 0.72)
        }
        return Color(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }
}

struct AmbientCardModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.ambientHighContrastOverride) private var highContrastOverride

    func body(content: Content) -> some View {
        content
            .padding(AmbientTheme.Spacing.standard)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AmbientTheme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: AmbientTheme.Radius.card)
                    .stroke(
                        isHighContrast ? Color.white.opacity(0.55) : AmbientTheme.separator,
                        lineWidth: isHighContrast ? 1.5 : 1
                    )
            }
    }

    private var isHighContrast: Bool {
        highContrastOverride ?? (contrast == .increased)
    }
}

extension View {
    func ambientCard() -> some View {
        modifier(AmbientCardModifier())
    }
}
