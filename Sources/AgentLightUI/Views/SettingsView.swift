import SwiftUI

public struct SettingsView: View {
    static let sectionTitles = ["Light", "Integrations", "General"]

    private let viewModel: AppViewModel
    private let dismiss: (() -> Void)?

    public init(viewModel: AppViewModel, dismiss: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let dismiss {
                HStack {
                    Button(action: dismiss) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AmbientAccessibilityID.settingsBack)
                    Spacer()
                    Text("Settings").font(.headline)
                    Spacer()
                }
                .padding()
            }
            Form {
                Section("Light") {
                    LabeledContent("Connection", value: viewModel.connectionStatus == .connected ? "Connected" : "Disconnected")
                        .accessibilityIdentifier("settings.light.connection")
                    Text("Tuya identifiers are stored in Keychain and are never shown in full.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Disconnect and restore light") {
                        Task { await viewModel.disconnect() }
                    }
                    .accessibilityIdentifier(AmbientAccessibilityID.settingsDisconnect)
                }

                Section("Integrations") {
                    LabeledContent("Codex", value: integrationStatus)
                    LabeledContent("Claude Code", value: integrationStatus)
                    LabeledContent("Cursor", value: integrationStatus)
                    Button("Repair Integrations") {
                        Task { await viewModel.repairIntegrations() }
                    }
                    .accessibilityIdentifier(AmbientAccessibilityID.settingsRepair)
                }

                Section("General") {
                    LabeledContent("Launch at login", value: loginStatusTitle)
                        .accessibilityIdentifier("settings.general.loginStatus")
                    if viewModel.loginItemStatus != .enabled {
                        Button("Enable Launch at Login") {
                            Task { await viewModel.requestLaunchAtLogin() }
                        }
                        .accessibilityIdentifier(AmbientAccessibilityID.settingsEnableLogin)
                    }
                    Text(viewModel.phase == .paused ? "Monitoring is paused" : "Monitoring is enabled")
                        .accessibilityIdentifier("settings.general.monitoringStatus")
                }
            }
            .formStyle(.grouped)
        }
        .frame(
            minWidth: AmbientTheme.windowWidth,
            maxWidth: AmbientTheme.windowWidth,
            minHeight: 500
        )
        .background(AmbientTheme.background)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("settings.root")
    }

    private var integrationStatus: String {
        viewModel.phase == .repairRequired ? "Needs repair" : "Installed"
    }

    private var loginStatusTitle: String {
        switch viewModel.loginItemStatus {
        case .enabled: "Enabled"
        case .requiresApproval: "Approval required"
        case .notRegistered, .notFound: "Not enabled"
        case .unknown: "Status unavailable"
        }
    }
}
