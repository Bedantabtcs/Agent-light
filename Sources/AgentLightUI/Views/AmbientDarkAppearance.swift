import AppKit
import SwiftUI

public struct AmbientDarkAppearance<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .environment(\.colorScheme, .dark)
            .background(AmbientWindowAppearance())
    }
}

private struct AmbientWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> AppearanceProbeView {
        AppearanceProbeView()
    }

    func updateNSView(_ view: AppearanceProbeView, context: Context) {
        view.enforceDarkAppearance()
    }
}

private final class AppearanceProbeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enforceDarkAppearance()
    }

    func enforceDarkAppearance() {
        let darkAppearance = NSAppearance(named: .darkAqua)
        appearance = darkAppearance
        window?.appearance = darkAppearance
    }
}
