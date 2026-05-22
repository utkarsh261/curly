import AppKit
import SwiftUI

struct URLInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding
    let onPaste: (String) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onPaste: onPaste)
    }

    func makeNSView(context: Context) -> PasteAwareTextField {
        let textField = PasteAwareTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.identifier = NSUserInterfaceItemIdentifier("url-input-field")
        textField.setAccessibilityIdentifier("url-input-field")
        return textField
    }

    func updateNSView(_ textField: PasteAwareTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onPaste = onPaste
        textField.placeholderString = placeholder

        if textField.stringValue != text {
            textField.stringValue = text
        }

        if isFocused.wrappedValue,
           textField.window?.firstResponder !== textField.currentEditor() {
            textField.window?.makeFirstResponder(textField)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onPaste: (String) -> Bool

        init(text: Binding<String>, onPaste: @escaping (String) -> Bool) {
            self.text = text
            self.onPaste = onPaste
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }

            let newText = textField.stringValue
            if Self.looksLikeCurlCommand(newText), handlePaste(newText) {
                return
            }

            text.wrappedValue = newText
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSText.paste(_:)) else {
                return false
            }

            guard let pastedText = NSPasteboard.general.string(forType: .string) else {
                return false
            }

            return handlePaste(pastedText)
        }

        func handlePaste(_ pastedText: String) -> Bool {
            onPaste(pastedText)
        }

        private static func looksLikeCurlCommand(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "curl" || trimmed.hasPrefix("curl ") || trimmed.hasPrefix("curl\t") || trimmed.hasPrefix("curl\n")
        }
    }
}

final class PasteAwareTextField: NSTextField {}
