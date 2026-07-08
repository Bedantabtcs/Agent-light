import AppKit
import AgentLightCore
import SwiftUI

struct NativeDataCenterPicker: NSViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: TuyaDataCenter
    let accessibilityIdentifier: String
    let onSelection: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, onSelection: onSelection)
    }

    func makeNSView(context: Context) -> FocusedPopUpButton {
        let picker = FocusedPopUpButton(frame: .zero, pullsDown: false)
        picker.addItems(withTitles: TuyaDataCenter.allCases.map(\.displayName))
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        configureAccessibility(
            picker,
            identifier: accessibilityIdentifier,
            label: "Tuya data center",
            role: .popUpButton
        )
        picker.font = NativeDynamicType.font(for: dynamicTypeSize, baseSize: NSFont.systemFontSize)
        picker.focusWhenAttached = true
        return picker
    }

    func updateNSView(_ picker: FocusedPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.onSelection = onSelection
        picker.selectItem(at: TuyaDataCenter.allCases.firstIndex(of: selection) ?? 0)
        picker.font = NativeDynamicType.font(for: dynamicTypeSize, baseSize: NSFont.systemFontSize)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<TuyaDataCenter>
        var onSelection: () -> Void

        init(selection: Binding<TuyaDataCenter>, onSelection: @escaping () -> Void) {
            self.selection = selection
            self.onSelection = onSelection
        }

        @objc func changed(_ sender: NSPopUpButton) {
            guard TuyaDataCenter.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
            selection.wrappedValue = TuyaDataCenter.allCases[sender.indexOfSelectedItem]
            onSelection()
        }
    }
}

final class FocusedPopUpButton: NSPopUpButton {
    var focusWhenAttached = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenAttached else { return }
        focusWhenAttached = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }
}

public struct NativeActionButton: NSViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let accessibilityIdentifier: String
    var keyEquivalent = ""
    var isProminent = false
    let action: () -> Void

    public init(
        title: String,
        accessibilityIdentifier: String,
        keyEquivalent: String = "",
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.keyEquivalent = keyEquivalent
        self.isProminent = isProminent
        self.action = action
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    public func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.invoke))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = keyEquivalent
        configureAccessibility(
            button,
            identifier: accessibilityIdentifier,
            label: title,
            role: .button
        )
        button.font = NativeDynamicType.font(for: dynamicTypeSize, baseSize: NSFont.systemFontSize)
        if isProminent {
            button.bezelColor = .controlAccentColor
        }
        return button
    }

    public func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.keyEquivalent = keyEquivalent
        button.bezelColor = isProminent ? .controlAccentColor : nil
        button.font = NativeDynamicType.font(for: dynamicTypeSize, baseSize: NSFont.systemFontSize)
        button.setAccessibilityLabel(title)
    }

    @MainActor
    public final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func invoke() {
            action()
        }
    }
}

struct NativeMonitoringToggle: NSViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let isOn: Bool
    let accessibilityIdentifier: String
    var accessibilityLabel = "Monitoring"
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSSwitch {
        let monitoringSwitch = NSSwitch(frame: .zero)
        monitoringSwitch.target = context.coordinator
        monitoringSwitch.action = #selector(Coordinator.invoke(_:))
        configureAccessibility(
            monitoringSwitch,
            identifier: accessibilityIdentifier,
            label: accessibilityLabel,
            role: .checkBox
        )
        monitoringSwitch.font = NativeDynamicType.font(
            for: dynamicTypeSize,
            baseSize: NSFont.systemFontSize
        )
        monitoringSwitch.setAccessibilityLabel(accessibilityLabel)
        monitoringSwitch.state = isOn ? .on : .off
        return monitoringSwitch
    }

    func updateNSView(_ monitoringSwitch: NSSwitch, context: Context) {
        context.coordinator.onChange = onChange
        monitoringSwitch.state = isOn ? .on : .off
        monitoringSwitch.font = NativeDynamicType.font(
            for: dynamicTypeSize,
            baseSize: NSFont.systemFontSize
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        @objc func invoke(_ sender: NSSwitch) {
            onChange(sender.state == .on)
        }
    }
}

struct NativeWrappingText: NSViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let text: String
    let accessibilityIdentifier: String
    var isMonospaced = false
    var isSelectable = true

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.isSelectable = isSelectable
        configureAccessibility(
            field,
            identifier: accessibilityIdentifier,
            label: text,
            role: .staticText
        )
        field.font = renderedFont
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = text
        field.isSelectable = isSelectable
        field.font = renderedFont
        field.setAccessibilityLabel(text)
    }

    private var renderedFont: NSFont {
        if isMonospaced {
            return NativeDynamicType.monospacedFont(
                for: dynamicTypeSize,
                baseSize: NSFont.smallSystemFontSize
            )
        }
        return NativeDynamicType.font(for: dynamicTypeSize, baseSize: NSFont.systemFontSize)
    }
}

@MainActor
private func configureAccessibility(
    _ view: NSView,
    identifier: String,
    label: String,
    role: NSAccessibility.Role
) {
    view.setAccessibilityElement(true)
    view.setAccessibilityIdentifier(identifier)
    view.setAccessibilityLabel(label)
    view.setAccessibilityRole(role)
    view.identifier = NSUserInterfaceItemIdentifier(identifier)
}

private enum NativeDynamicType {
    static func font(
        for size: DynamicTypeSize,
        baseSize: CGFloat
    ) -> NSFont {
        .systemFont(ofSize: baseSize * scale(for: size))
    }

    static func monospacedFont(
        for size: DynamicTypeSize,
        baseSize: CGFloat
    ) -> NSFont {
        .monospacedSystemFont(ofSize: baseSize * scale(for: size), weight: .regular)
    }

    private static func scale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.82
        case .small: 0.9
        case .medium: 0.96
        case .large: 1
        case .xLarge: 1.08
        case .xxLarge: 1.16
        case .xxxLarge: 1.24
        case .accessibility1: 1.32
        case .accessibility2: 1.4
        case .accessibility3: 1.48
        case .accessibility4: 1.56
        case .accessibility5: 1.64
        @unknown default: 1
        }
    }
}
