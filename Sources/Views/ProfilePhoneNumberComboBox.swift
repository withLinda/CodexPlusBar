import AppKit
import SwiftUI

struct ProfilePhoneNumberComboBox: NSViewRepresentable {
    @Binding var text: String
    let savedNumbers: [String]
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.delegate = context.coordinator
        comboBox.isEditable = true
        comboBox.completes = false
        comboBox.hasVerticalScroller = true
        comboBox.numberOfVisibleItems = 6
        comboBox.placeholderString = "Type or choose a saved number"
        comboBox.stringValue = text
        comboBox.font = NSFont(name: "Inter-Regular", size: 15)
            ?? NSFont.systemFont(ofSize: 15)
        comboBox.isBordered = false
        comboBox.isButtonBordered = false
        comboBox.drawsBackground = false
        comboBox.focusRingType = .default
        comboBox.setAccessibilityLabel("Phone number")
        comboBox.setAccessibilityHelp("Type a phone number or choose a saved phone number from the list.")
        comboBox.toolTip = "Type or choose a saved phone number"
        context.coordinator.updateSavedNumbers(savedNumbers, in: comboBox)
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateSavedNumbers(savedNumbers, in: comboBox)

        if comboBox.stringValue != text {
            comboBox.stringValue = text
            context.coordinator.resetSearch(in: comboBox)
        }

        comboBox.textColor = NSColor(CodexTheme.dataValueText)
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ProfilePhoneNumberComboBox
        private var savedNumbers: [String] = []
        private var isActivelySearching = false

        init(parent: ProfilePhoneNumberComboBox) {
            self.parent = parent
        }

        func updateSavedNumbers(_ newNumbers: [String], in comboBox: NSComboBox) {
            guard savedNumbers != newNumbers else {
                return
            }

            savedNumbers = newNumbers
            updateVisibleNumbers(in: comboBox)
        }

        func resetSearch(in comboBox: NSComboBox) {
            isActivelySearching = false
            replaceVisibleNumbers(with: savedNumbers, in: comboBox)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else {
                return
            }

            isActivelySearching = true
            parent.text = comboBox.stringValue
            updateVisibleNumbers(in: comboBox)
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox,
                  let selectedNumber = comboBox.objectValueOfSelectedItem as? String else {
                return
            }

            comboBox.stringValue = selectedNumber
            parent.text = selectedNumber
            isActivelySearching = false
        }

        func comboBoxWillPopUp(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else {
                return
            }

            updateVisibleNumbers(in: comboBox)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }

            parent.text = control.stringValue
            parent.onSubmit()
            return true
        }

        private func updateVisibleNumbers(in comboBox: NSComboBox) {
            let visibleNumbers = isActivelySearching
                ? ProfilePhoneNumberCatalog.matches(savedNumbers, query: comboBox.stringValue)
                : savedNumbers
            replaceVisibleNumbers(with: visibleNumbers, in: comboBox)
        }

        private func replaceVisibleNumbers(with numbers: [String], in comboBox: NSComboBox) {
            let currentNumbers = comboBox.objectValues.compactMap { $0 as? String }
            guard currentNumbers != numbers else {
                return
            }

            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: numbers)
        }
    }
}
