import AgentLightProtocol
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
                    NativeActionButton(
                        title: "Back",
                        accessibilityIdentifier: AmbientAccessibilityID.settingsBack,
                        keyEquivalent: "\u{1b}",
                        action: dismiss
                    )
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
                    LabeledContent("Access ID", value: viewModel.maskedAccessID ?? "Unavailable")
                        .accessibilityIdentifier("settings.light.maskedAccessID")
                    LabeledContent("Device ID", value: viewModel.maskedDeviceID ?? "Unavailable")
                        .accessibilityIdentifier("settings.light.maskedDeviceID")
                    NativeActionButton(
                        title: "Reconnect Light",
                        accessibilityIdentifier: AmbientAccessibilityID.settingsReconnect
                    ) {
                        Task { await viewModel.reconnect() }
                    }
                    NativeActionButton(
                        title: "Replace Device",
                        accessibilityIdentifier: AmbientAccessibilityID.settingsReplaceDevice
                    ) {
                        Task { await viewModel.replaceDevice() }
                    }
                    NativeActionButton(
                        title: "Disconnect and restore light",
                        accessibilityIdentifier: AmbientAccessibilityID.settingsDisconnect
                    ) {
                        Task { await viewModel.disconnect() }
                    }
                }

                Section("Integrations") {
                    LabeledContent("Codex", value: codexStatusTitle)
                    LabeledContent("Claude Code", value: viewModel.integrationStatus.displayName)
                    LabeledContent("Cursor", value: viewModel.integrationStatus.displayName)
                    if viewModel.codexTrustStatus == .required {
                        NativeWrappingText(
                            text: "Trust required. Open Codex, run /hooks, review the Agent Light command with integration ID \(AppIdentity.integrationIdentifier), trust it in Codex, then return here.",
                            accessibilityIdentifier: "settings.integrations.codexTrustGuidance",
                            isSelectable: true
                        )
                        NativeActionButton(
                            title: "I Confirmed in Codex",
                            accessibilityIdentifier: AmbientAccessibilityID.settingsConfirmCodexTrust
                        ) {
                            viewModel.confirmCodexTrust()
                        }
                    } else if viewModel.codexTrustStatus == .userConfirmed {
                        NativeWrappingText(
                            text: "User confirmed in Codex. Agent Light cannot independently verify Codex trust.",
                            accessibilityIdentifier: "settings.integrations.codexTrustGuidance",
                            isSelectable: false
                        )
                    }
                    NativeActionButton(
                        title: "Preview Repair",
                        accessibilityIdentifier: AmbientAccessibilityID.settingsRepair
                    ) {
                        Task { await viewModel.previewIntegrationRepair() }
                    }
                    if !viewModel.repairPreviews.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(viewModel.repairPreviews, id: \.source) { preview in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(preview.source.displayName)
                                            .font(.headline)
                                        NativeWrappingText(
                                            text: preview.path,
                                            accessibilityIdentifier: "settings.integrations.preview.\(preview.source.rawValue).path",
                                            isMonospaced: true
                                        )
                                        Text("Before")
                                            .font(.caption.weight(.semibold))
                                        NativeWrappingText(
                                            text: preview.before.isEmpty ? "Empty file" : preview.before,
                                            accessibilityIdentifier: "settings.integrations.preview.\(preview.source.rawValue).before",
                                            isMonospaced: true
                                        )
                                        Text("After")
                                            .font(.caption.weight(.semibold))
                                        NativeWrappingText(
                                            text: preview.after.isEmpty ? "Empty file" : preview.after,
                                            accessibilityIdentifier: "settings.integrations.preview.\(preview.source.rawValue).after",
                                            isMonospaced: true
                                        )
                                    }
                                    .accessibilityIdentifier("settings.integrations.preview.\(preview.source.rawValue)")
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                        NativeActionButton(
                            title: "Confirm Repair",
                            accessibilityIdentifier: AmbientAccessibilityID.settingsConfirmRepair
                        ) {
                            Task { await viewModel.repairIntegrations() }
                        }
                    }
                    NativeActionButton(
                        title: "Uninstall Integrations",
                        accessibilityIdentifier: AmbientAccessibilityID.settingsUninstall
                    ) {
                        Task { await viewModel.uninstallIntegrations() }
                    }
                    if viewModel.outstandingObligations.contains(.ownershipReceiptRepair) {
                        NativeWrappingText(
                            text: viewModel.canResetOwnershipReceipt
                                ? "The saved ownership receipt cannot be used safely."
                                : "Ownership state could not be read or saved. Retry, then inspect Application Support permissions if the problem continues.",
                            accessibilityIdentifier: "settings.integrations.ownershipReceiptWarning",
                            isSelectable: false
                        )
                        if viewModel.canResetOwnershipReceipt {
                            NativeActionButton(
                                title: "Reset Ownership Receipt",
                                accessibilityIdentifier: AmbientAccessibilityID.settingsResetOwnershipReceipt
                            ) {
                                Task { await viewModel.resetOwnershipReceipt() }
                            }
                        }
                    }
                }

                Section("General") {
                    LabeledContent("Launch at login") {
                        NativeMonitoringToggle(
                            isOn: launchAtLoginBinding.wrappedValue,
                            accessibilityIdentifier: AmbientAccessibilityID.settingsLaunchAtLogin,
                            accessibilityLabel: "Launch at login",
                            onChange: { launchAtLoginBinding.wrappedValue = $0 }
                        )
                    }
                    NativeWrappingText(
                        text: loginStatusTitle,
                        accessibilityIdentifier: "settings.general.loginStatus",
                        isSelectable: false
                    )
                    if viewModel.loginItemStatus == .requiresApproval {
                        NativeWrappingText(
                            text: "Open System Settings > General > Login Items, then allow Agent Light.",
                            accessibilityIdentifier: "settings.general.loginApprovalGuidance",
                            isSelectable: false
                        )
                        NativeActionButton(
                            title: "Retry Status",
                            accessibilityIdentifier: AmbientAccessibilityID.settingsRetryLoginStatus
                        ) {
                            Task { await viewModel.requestLaunchAtLogin() }
                        }
                    }
                    NativeWrappingText(
                        text: viewModel.monitoringActive
                            ? "Monitoring is enabled"
                            : "Monitoring is disabled",
                        accessibilityIdentifier: "settings.general.monitoringStatus",
                        isSelectable: false
                    )
                    LabeledContent("Monitoring") {
                        NativeMonitoringToggle(
                            isOn: monitoringBinding.wrappedValue,
                            accessibilityIdentifier: AmbientAccessibilityID.settingsMonitoring,
                            onChange: { monitoringBinding.wrappedValue = $0 }
                        )
                    }
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

    private var loginStatusTitle: String {
        switch viewModel.loginItemStatus {
        case .enabled: "Enabled"
        case .requiresApproval: "Approval required"
        case .notRegistered, .notFound: "Not enabled"
        case .unknown: "Status unavailable"
        }
    }

    private var codexStatusTitle: String {
        guard viewModel.integrationStatus == .installed else {
            return viewModel.integrationStatus.displayName
        }
        return switch viewModel.codexTrustStatus {
        case .notRequired: "Installed"
        case .required: "Trust required"
        case .userConfirmed: "User confirmed"
        }
    }

    private var monitoringBinding: Binding<Bool> {
        Binding(
            get: { viewModel.monitoringActive },
            set: { enabled in
                Task { await viewModel.setMonitoringEnabled(enabled) }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: {
                viewModel.loginItemStatus == .enabled
                    || viewModel.loginItemStatus == .requiresApproval
            },
            set: { enabled in
                Task { await viewModel.setLaunchAtLoginEnabled(enabled) }
            }
        )
    }
}
