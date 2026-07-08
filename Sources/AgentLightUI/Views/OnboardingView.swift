import AgentLightCore
import SwiftUI

public struct OnboardingView: View {
    private let viewModel: AppViewModel

    @State private var dataCenter: TuyaDataCenter = .india
    @State private var accessID = ""
    @State private var accessSecret = ""
    @State private var deviceID = ""
    @State private var attemptedSubmit = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case accessID
        case accessSecret
        case deviceID
    }

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AmbientTheme.Spacing.section) {
                header
                credentialFields
                securityNotice
                if let error = viewModel.presentedError {
                    statusMessage(for: error)
                }
                NativeActionButton(
                    title: "Verify & Connect",
                    accessibilityIdentifier: AmbientAccessibilityID.onboardingVerify,
                    keyEquivalent: "\r",
                    isProminent: true,
                    action: verifyAndConnect
                )
                .frame(maxWidth: .infinity)
            }
            .padding(AmbientTheme.Spacing.window)
        }
        .frame(width: AmbientTheme.windowWidth)
        .background(AmbientTheme.background)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AmbientTheme.Spacing.compact) {
            Label("Connect your light", systemImage: "lightbulb.led")
                .font(.title2.weight(.semibold))
            Text("Agent Light uses Tuya cloud credentials and local agent hooks. Your secret is stored only in Keychain after verification and approval.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("onboarding.header")
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: AmbientTheme.Spacing.standard) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tuya data center")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeDataCenterPicker(
                    selection: $dataCenter,
                    accessibilityIdentifier: AmbientAccessibilityID.onboardingEndpoint,
                    onSelection: { focusedField = .accessID }
                )
            }
            TextField("Access ID", text: $accessID)
                .accessibilityIdentifier(AmbientAccessibilityID.onboardingAccessID)
                .focused($focusedField, equals: .accessID)
                .submitLabel(.next)
                .onSubmit { focusedField = .accessSecret }
            SecureField("Access Secret", text: $accessSecret)
                .accessibilityIdentifier(AmbientAccessibilityID.onboardingAccessSecret)
                .focused($focusedField, equals: .accessSecret)
                .submitLabel(.next)
                .onSubmit { focusedField = .deviceID }
            TextField("Device ID", text: $deviceID)
                .accessibilityIdentifier(AmbientAccessibilityID.onboardingDeviceID)
                .focused($focusedField, equals: .deviceID)
                .submitLabel(.done)
                .onSubmit { verifyAndConnect() }
            if let validationMessage, attemptedSubmit {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.validation")
            }
        }
        .textFieldStyle(.roundedBorder)
        .ambientCard()
    }

    private var securityNotice: some View {
        Label {
            Text("Access Secret is entered securely. Verified credentials are saved to macOS Keychain, never project files or logs.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("onboarding.keychainNotice")
    }

    @ViewBuilder
    private func statusMessage(for error: PresentationError) -> some View {
        Label(error.userMessage, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("onboarding.status")
    }

    private var validationMessage: String? {
        guard !accessID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !accessSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return attemptedSubmit ? "Access ID, Access Secret, and Device ID are required." : nil
        }
        return nil
    }

    private func verifyAndConnect() {
        attemptedSubmit = true
        guard validationMessage == nil else { return }
        focusedField = nil
        let draft = ConnectionDraft(
            endpoint: dataCenter.endpoint.absoluteString,
            accessID: accessID,
            accessSecret: accessSecret,
            deviceID: deviceID
        )
        Task { await viewModel.connect(using: draft) }
    }
}

extension PresentationError {
    var userMessage: String {
        switch self {
        case .invalidCredential: "The credentials were rejected. Check the Access ID, Access Secret, and Device ID."
        case .invalidEndpoint: "Use the HTTPS origin for your Tuya data center."
        case .unsupportedBulb: "This device does not advertise supported color controls."
        case .integrationConflict: "An agent configuration conflicts with the required hook entries. Review it before retrying."
        case .bulbOffline: "The bulb or Tuya service is offline. No new light command was sent."
        case .rateLimited: "Tuya is rate limiting requests. Wait, then retry."
        case .loginApprovalRequired: "Open System Settings > General > Login Items, then allow Agent Light."
        case .operationFailed: "The operation could not be completed. Retry from this screen."
        }
    }
}
