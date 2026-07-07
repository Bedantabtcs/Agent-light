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
            Group {
                switch environment.status {
                case .ready:
                    MenuBarContentView(viewModel: viewModel) {
                        environment.requestQuit()
                    }
                case .loading, .failed, .credentialResetFailed:
                    StartupStatusView(
                        status: environment.status,
                        retry: environment.requestStart,
                        quit: environment.requestQuit
                    )
                }
            }
            .onAppear { environment.requestStart() }
        }
        .menuBarExtraStyle(.window)
    }
}

struct StartupStatusView: View {
    let status: AppEnvironmentStatus
    let retry: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if status == .loading {
                ProgressView()
                Text("Preparing Agent Light")
                    .font(.headline)
                Text("Checking recovery state before accepting agent events.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Label("Agent Light could not start", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(failureMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                NativeActionButton(
                    title: retryTitle,
                    accessibilityIdentifier: "app.startup.retry",
                    action: retry
                )
                NativeActionButton(
                    title: "Quit",
                    accessibilityIdentifier: "app.startup.quit",
                    action: quit
                )
            }
        }
        .padding(24)
        .frame(minWidth: 380, maxWidth: 380, minHeight: 240)
        .accessibilityIdentifier(status == .loading ? "app.startup.loading" : "app.startup.failed")
    }

    private var failureMessage: String {
        if status == .credentialResetFailed {
            return "Stored Tuya credentials could not be reset. No agent events are being accepted."
        }
        return "Recovery or local relay setup failed. No agent events are being accepted."
    }

    private var retryTitle: String {
        status == .credentialResetFailed ? "Reset Stored Credentials & Retry" : "Retry Startup"
    }
}
