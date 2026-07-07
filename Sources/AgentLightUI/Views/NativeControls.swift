import AppKit
import AgentLightCore
import SwiftUI

struct NativeDataCenterPicker: NSViewRepresentable {
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
        picker.setAccessibilityIdentifier(accessibilityIdentifier)
        picker.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        picker.focusWhenAttached = true
        return picker
    }

    func updateNSView(_ picker: FocusedPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.onSelection = onSelection
        picker.selectItem(at: TuyaDataCenter.allCases.firstIndex(of: selection) ?? 0)
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
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
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
    let isOn: Bool
    let accessibilityIdentifier: String
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSSwitch {
        let monitoringSwitch = NSSwitch(frame: .zero)
        monitoringSwitch.target = context.coordinator
        monitoringSwitch.action = #selector(Coordinator.invoke(_:))
        monitoringSwitch.setAccessibilityLabel("Monitoring")
        monitoringSwitch.setAccessibilityIdentifier(accessibilityIdentifier)
        monitoringSwitch.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        monitoringSwitch.state = isOn ? .on : .off
        return monitoringSwitch
    }

    func updateNSView(_ monitoringSwitch: NSSwitch, context: Context) {
        context.coordinator.onChange = onChange
        monitoringSwitch.state = isOn ? .on : .off
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
    let text: String
    let accessibilityIdentifier: String
    var isMonospaced = false
    var isSelectable = true

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.isSelectable = isSelectable
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        if isMonospaced {
            field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = text
        field.isSelectable = isSelectable
    }
}
