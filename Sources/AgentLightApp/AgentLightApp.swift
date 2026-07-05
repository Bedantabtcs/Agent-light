import SwiftUI

@main
struct AgentLightApp: App {
    var body: some Scene {
        MenuBarExtra("Agent Light", systemImage: "lightbulb.led.fill") {
            Text("Agent Light")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
