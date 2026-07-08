import AgentLightCore
import AgentLightProtocol
import SwiftUI

public struct MenuBarContentView: View {
    private let viewModel: AppViewModel
    private let quit: () -> Void
    @State private var showsSettings = false

    public init(viewModel: AppViewModel, quit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.viewModel = viewModel
        self.quit = quit
    }

    func perform(_ action: MenuAction) {
        switch action {
        case .approve:
            Task { await viewModel.approveIntegrations() }
        case .pause:
            Task { await viewModel.pause() }
        case .resume:
            Task { await viewModel.resume() }
        case .quit:
            quit()
        }
    }

    public var body: some View {
        Group {
            if showsSettings {
                SettingsView(viewModel: viewModel) {
                    showsSettings = false
                }
            } else {
                phaseContent
            }
        }
        .frame(width: AmbientTheme.windowWidth, height: AmbientTheme.windowHeight)
        .background(AmbientTheme.background)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .onboarding:
            OnboardingView(viewModel: viewModel)
        case .verifying:
            progressView(title: "Verifying light", detail: "Checking credentials, device status, and color capabilities.", identifier: "status.verifying")
        case .integrationReview:
            integrationReview
        case .approving:
            progressView(title: "Installing integrations", detail: "Writing and verifying only Agent Light-owned hook entries.", identifier: "status.approving")
        case .monitoring, .paused, .repairRequired:
            monitor
        }
    }

    private func progressView(title: String, detail: String, identifier: String) -> some View {
        VStack(spacing: AmbientTheme.Spacing.section) {
            ProgressView()
                .controlSize(.large)
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AmbientTheme.Spacing.window)
        .frame(minHeight: 300)
        .accessibilityIdentifier(identifier)
    }

    private var integrationReview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AmbientTheme.Spacing.section) {
                VStack(alignment: .leading, spacing: AmbientTheme.Spacing.compact) {
                    Text("Review integrations")
                        .font(.title2.weight(.semibold))
                    Text("Confirm each exact configuration path and proposed Agent Light-owned change.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("integrationReview.header")

                ForEach(viewModel.integrationPreviews, id: \.source) { preview in
                    integrationCard(preview)
                }

                if let error = viewModel.presentedError {
                    Label(error.userMessage, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("integrationReview.status")
                }

                NativeActionButton(
                    title: "Approve & Start Monitoring",
                    accessibilityIdentifier: AmbientAccessibilityID.integrationApprove,
                    keyEquivalent: "\r",
                    isProminent: true
                ) { perform(.approve) }
                .frame(maxWidth: .infinity)
            }
            .padding(AmbientTheme.Spacing.window)
        }
    }

    private func integrationCard(_ preview: IntegrationPreview) -> some View {
        VStack(alignment: .leading, spacing: AmbientTheme.Spacing.compact) {
            HStack {
                Label(preview.source.displayName, systemImage: preview.source.symbolName)
                    .font(.headline)
                Spacer()
                Text(preview.hadOwnedEntries ? "Change / conflict" : "New entry")
                    .font(.caption.weight(.semibold))
            }
            NativeWrappingText(
                text: preview.path,
                accessibilityIdentifier: "integrationReview.\(preview.source.rawValue).path",
                isMonospaced: true
            )
            summaryRow("Before", value: preview.before, source: preview.source)
            summaryRow("After", value: preview.after, source: preview.source)
            Text(preview.before == preview.after ? "No content change" : "Agent Light hook entry will be merged; unrelated configuration is preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .ambientCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(preview.source.displayName) integration at \(preview.path)")
        .accessibilityValue("Before: \(preview.before). After: \(preview.after). \(preview.hadOwnedEntries ? "Existing Agent Light entry may change or conflict." : "Adds a new Agent Light entry.")")
        .accessibilityIdentifier("integrationReview.\(preview.source.rawValue)")
    }

    private func summaryRow(_ title: String, value: String, source: AgentSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            NativeWrappingText(
                text: value.isEmpty ? "Empty file" : value,
                accessibilityIdentifier: "integrationReview.\(source.rawValue).\(title.lowercased())",
                isMonospaced: true
            )
        }
    }

    private var monitor: some View {
        ScrollView {
            VStack(spacing: AmbientTheme.Spacing.section) {
                monitorHeader
                AmbientBulbView(state: viewModel.currentState)
                currentStateCard
                sessionList
                if let error = viewModel.presentedError {
                    Label(error.userMessage, systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("monitor.status")
                }
                actionControls
            }
            .padding(AmbientTheme.Spacing.window)
        }
    }

    private var monitorHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Light").font(.headline)
                Label(connectionTitle, systemImage: connectionSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("monitor.connectionStatus")
            }
            Spacer()
            Text(phaseTitle)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(AmbientTheme.strongSurface, in: Capsule())
                .accessibilityIdentifier("monitor.phaseStatus")
        }
    }

    private var currentStateCard: some View {
        VStack(spacing: AmbientTheme.Spacing.compact) {
            Label(viewModel.currentState.displayName, systemImage: stateSymbol)
                .font(.title3.weight(.semibold))
            Text(activeSession?.source.displayName ?? "No active agent")
                .font(.callout.weight(.medium))
                .accessibilityIdentifier("monitor.currentAgent")
            Text(activeSession?.workspace ?? "Waiting for a supported agent event")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .accessibilityIdentifier("monitor.currentWorkspace")
        }
        .frame(maxWidth: .infinity)
        .ambientCard()
        .accessibilityIdentifier("monitor.currentState")
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sessions")
                .font(.headline)
                .padding(.bottom, AmbientTheme.Spacing.compact)
            if viewModel.sessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, AmbientTheme.Spacing.standard)
            } else {
                ForEach(Array(viewModel.sessions.enumerated()), id: \.element.sessionID) { index, event in
                    if index > 0 { Divider() }
                    sessionRow(event)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ambientCard()
        .accessibilityIdentifier("monitor.sessionList")
    }

    private func sessionRow(_ event: AgentEvent) -> some View {
        HStack(alignment: .top, spacing: AmbientTheme.Spacing.standard) {
            Image(systemName: event.source.symbolName)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.source.displayName)
                    .font(.callout.weight(.medium))
                NativeWrappingText(
                    text: event.workspace ?? event.sessionID,
                    accessibilityIdentifier: "monitor.session.\(event.sessionID).workspace",
                    isSelectable: false
                )
            }
            Spacer(minLength: AmbientTheme.Spacing.compact)
            Label(event.state.displayName, systemImage: event.state.symbolName)
                .labelStyle(.titleOnly)
                .font(.caption.weight(.semibold))
        }
        .padding(.vertical, AmbientTheme.Spacing.compact)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("monitor.session.\(event.sessionID)")
    }

    private var actionControls: some View {
        VStack(spacing: AmbientTheme.Spacing.compact) {
            if viewModel.phase == .monitoring {
                NativeActionButton(
                    title: "Pause Monitoring",
                    accessibilityIdentifier: AmbientAccessibilityID.monitorPause
                ) { perform(.pause) }
                .frame(maxWidth: .infinity)
            } else if viewModel.phase == .paused {
                NativeActionButton(
                    title: "Resume Monitoring",
                    accessibilityIdentifier: AmbientAccessibilityID.monitorResume
                ) { perform(.resume) }
                .frame(maxWidth: .infinity)
            }
            if viewModel.phase == .repairRequired {
                NativeActionButton(
                    title: "Review Repair",
                    accessibilityIdentifier: AmbientAccessibilityID.monitorRepair
                ) { showsSettings = true }
                .frame(maxWidth: .infinity)
            }
            HStack {
                NativeActionButton(
                    title: "Settings",
                    accessibilityIdentifier: AmbientAccessibilityID.monitorSettings
                ) { showsSettings = true }
                Spacer()
                NativeActionButton(
                    title: "Quit",
                    accessibilityIdentifier: AmbientAccessibilityID.monitorQuit
                ) { perform(.quit) }
            }
        }
    }

    private var activeSession: AgentEvent? { viewModel.sessions.first }
    private var connectionTitle: String { viewModel.connectionStatus == .connected ? "Connected" : "Disconnected" }
    private var connectionSymbol: String { viewModel.connectionStatus == .connected ? "checkmark.circle.fill" : "wifi.exclamationmark" }
    private var phaseTitle: String {
        switch viewModel.phase {
        case .monitoring: "Monitoring"
        case .paused: "Paused"
        case .repairRequired: "Repair required"
        default: "Setup"
        }
    }
    private var stateSymbol: String { viewModel.currentState.symbolName }
}

enum MenuAction {
    case approve
    case pause
    case resume
    case quit
}

extension AgentSource {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        }
    }

    var symbolName: String {
        switch self {
        case .codex: "terminal"
        case .claudeCode: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        }
    }
}

extension AgentState {
    var symbolName: String {
        switch self {
        case .thinking: "brain.head.profile"
        case .working: "hammer.fill"
        case .reading: "book.closed.fill"
        case .editing: "pencil"
        case .testing: "checkmark.seal.fill"
        case .needsYou: "person.crop.circle.badge.exclamationmark"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.octagon.fill"
        case .error: "exclamationmark.triangle.fill"
        case .idle: "moon.zzz"
        }
    }
}
