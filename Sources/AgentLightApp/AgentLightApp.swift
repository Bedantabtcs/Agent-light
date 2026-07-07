import SwiftUI
import AgentLightUI

@main
struct AgentLightApp: App {
    @State private var environment: AppEnvironment
    @State private var viewModel: AppViewModel

    init() {
        let composition = ProductionAppComposition.make()
        _environment = State(initialValue: composition.environment)
        _viewModel = State(initialValue: composition.viewModel)
    }

    var body: some Scene {
        MenuBarExtra("Agent Light", systemImage: "lightbulb.led.fill") {
            switch environment.status {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Preparing Agent Light")
                        .font(.headline)
                    Text("Checking recovery state before accepting agent events.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(minWidth: 380, maxWidth: 380, minHeight: 240)
                .accessibilityIdentifier("app.startup.loading")
            case .ready:
                MenuBarContentView(viewModel: viewModel) {
                    environment.requestQuit()
                }
            case .failed:
                VStack(spacing: 12) {
                    Label("Agent Light could not start", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text("Recovery or local relay setup failed. No agent events are being accepted.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry Startup") {
                        Task { await environment.start() }
                    }
                    .accessibilityIdentifier("app.startup.retry")
                    Button("Quit") {
                        environment.requestQuit()
                    }
                    .accessibilityIdentifier("app.startup.quit")
                }
                .padding(24)
                .frame(minWidth: 380, maxWidth: 380, minHeight: 240)
                .accessibilityIdentifier("app.startup.failed")
            }
        }
        .menuBarExtraStyle(.window)
        .onChange(of: environment.status, initial: true) { _, _ in
            environment.launch()
        }
    }
}
