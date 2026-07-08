import AgentLightCore
import SwiftUI

enum AmbientBulbMotion {
    static let glowScale: CGFloat = 1
    static let restingGlowOpacity = 0.62
    static let activeGlowOpacity = 1.0
    static let duration = 2.4
    static let iconFrameSide: CGFloat = 48

    static func glowOpacity(isPulsing: Bool, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return activeGlowOpacity }
        return isPulsing ? activeGlowOpacity : restingGlowOpacity
    }
}

public struct AmbientBulbView: View {
    public let state: AgentState
    private let reduceMotionOverride: Bool?
    private let highContrastOverride: Bool?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.ambientReduceMotionOverride) private var environmentReduceMotionOverride
    @Environment(\.ambientHighContrastOverride) private var environmentHighContrastOverride
    @State private var isPulsing = false

    public init(state: AgentState) {
        self.state = state
        reduceMotionOverride = nil
        highContrastOverride = nil
    }

    init(state: AgentState, reduceMotionOverride: Bool, highContrastOverride: Bool) {
        self.state = state
        self.reduceMotionOverride = reduceMotionOverride
        self.highContrastOverride = highContrastOverride
    }

    public var body: some View {
        let isHighContrast = highContrastOverride
            ?? environmentHighContrastOverride
            ?? (contrast == .increased)
        let shouldReduceMotion = reduceMotionOverride
            ?? environmentReduceMotionOverride
            ?? reduceMotion
        let color = AmbientTheme.stateColor(state, highContrast: isHighContrast)
        ZStack {
            Circle()
                .fill(color.opacity(isHighContrast ? 0.42 : 0.28))
                .frame(width: 122, height: 122)
                .scaleEffect(AmbientBulbMotion.glowScale)
                .opacity(AmbientBulbMotion.glowOpacity(
                    isPulsing: isPulsing,
                    reduceMotion: shouldReduceMotion
                ))
                .blur(radius: isHighContrast ? 7 : 14)
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 90, height: 90)
                .overlay {
                    Circle().stroke(color.opacity(isHighContrast ? 1 : 0.65), lineWidth: 2)
                }
            Image(systemName: state.bulbSymbolName)
                .resizable()
                .scaledToFit()
                .frame(
                    width: AmbientBulbMotion.iconFrameSide,
                    height: AmbientBulbMotion.iconFrameSide
                )
                .foregroundStyle(.white)
                .shadow(color: color.opacity(0.9), radius: isHighContrast ? 8 : 18)
        }
        .frame(width: 142, height: 142)
        .onAppear {
            guard !shouldReduceMotion else { return }
            withAnimation(
                .easeInOut(duration: AmbientBulbMotion.duration)
                    .repeatForever(autoreverses: true)
            ) {
                isPulsing = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("ambientBulb.status")
        .accessibilityLabel("Light state")
        .accessibilityValue(state.displayName)
    }
}
