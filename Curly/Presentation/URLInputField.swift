import AppKit
import SwiftUI

enum VariableTokenPalette {
    static func nsColor(for status: VariableTokenStatus) -> NSColor {
        switch status {
        case .resolved:
            return .controlAccentColor
        case .missing, .invalid:
            return .systemRed
        }
    }

    static func color(for status: VariableTokenStatus) -> Color {
        Color(nsColor: nsColor(for: status))
    }
}

enum VariableTemplateFieldAccessibility {
    static func description(text: String, variables: [Variable]) -> String? {
        let tokens = VariableTemplateParser.parse(text, variables: variables).compactMap { segment -> VariableToken? in
            guard case .token(let token) = segment else { return nil }
            return token
        }
        guard !tokens.isEmpty else { return nil }

        return tokens.map { token in
            switch token.status {
            case .resolved:
                let name = token.name ?? token.rawText
                return "Recognized variable \(name). Resolves to \(token.resolvedValue ?? "")."
            case .missing:
                if let diagnostic = token.diagnostic {
                    return "Unresolved variable \(token.name ?? token.rawText). \(diagnostic)."
                }
                return "Missing variable \(token.name ?? token.rawText)."
            case .invalid:
                if let diagnostic = token.diagnostic {
                    return "Invalid variable \(token.rawText). \(diagnostic)."
                }
                return "Invalid variable \(token.rawText)."
            }
        }
        .joined(separator: " ")
    }
}

enum VariableTemplateTokenToolTipContent: Equatable {
    case resolved(name: String, value: String)
    case diagnostic(String)

    var text: String {
        switch self {
        case .resolved(let name, let value):
            return "\(name) resolves to:\n\(value)"
        case .diagnostic(let message):
            return message
        }
    }
}

struct VariableTemplateTokenToolTip: Equatable {
    let range: NSRange
    let status: VariableTokenStatus
    let content: VariableTemplateTokenToolTipContent

    var text: String {
        content.text
    }
}

enum VariableTemplateTokenToolTips {
    static func items(text: String, variables: [Variable]) -> [VariableTemplateTokenToolTip] {
        VariableTemplateParser.parse(text, variables: variables).compactMap { segment -> VariableTemplateTokenToolTip? in
            guard case .token(let token) = segment else {
                return nil
            }
            return VariableTemplateTokenToolTip(
                range: token.range,
                status: token.status,
                content: Self.content(for: token)
            )
        }
    }

    private static func content(for token: VariableToken) -> VariableTemplateTokenToolTipContent {
        switch token.status {
        case .resolved:
            return .resolved(
                name: token.name ?? token.rawText,
                value: token.resolvedValue ?? ""
            )
        case .missing:
            return .diagnostic(token.diagnostic ?? "\(token.name ?? token.rawText) is missing")
        case .invalid:
            return .diagnostic(token.diagnostic ?? "\(token.rawText) has invalid syntax")
        }
    }
}

enum VariableTokenHoverGeometry {
    static func containsHorizontally(_ point: NSPoint, in rect: NSRect) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX
    }

    static func visibleGlyphRect(
        for characterRange: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else {
            return nil
        }
        for glyphIndex in glyphRange.location..<NSMaxRange(glyphRange)
        where layoutManager.propertyForGlyph(at: glyphIndex).contains(.null) {
            return nil
        }

        let rect = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )
        guard !rect.isNull, rect.width > 0, rect.height > 0 else {
            return nil
        }
        return rect
    }
}

@MainActor
enum VariableTokenToolTipLayout {
    static let presentationDelay: TimeInterval = 0.8
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 6
    static let minimumTextWidth: CGFloat = 32
    static let maximumTextWidth: CGFloat = 420
    static let maximumTextHeight: CGFloat = 240
    static let minimumPanelHeight: CGFloat = 28
    static let truncationNotice = "\n… value truncated"
    static let maximumPanelWidth = maximumTextWidth + (horizontalPadding * 2)
    static let font = NSFont.monospacedSystemFont(
        ofSize: NSFont.smallSystemFontSize,
        weight: .regular
    )

    static func panelSize(for text: String) -> NSSize {
        panelSizeForVisibleText(visibleText(for: text))
    }

    static func visibleText(for text: String) -> String {
        guard measuredTextHeight(text, width: maximumTextWidth) > maximumTextHeight else {
            return text
        }

        var lowerBound = 0
        var upperBound = text.count
        while lowerBound < upperBound {
            let candidateLength = (lowerBound + upperBound + 1) / 2
            let candidate = String(text.prefix(candidateLength)) + truncationNotice
            if measuredTextHeight(candidate, width: maximumTextWidth) <= maximumTextHeight {
                lowerBound = candidateLength
            } else {
                upperBound = candidateLength - 1
            }
        }
        return String(text.prefix(lowerBound)) + truncationNotice
    }

    private static func panelSizeForVisibleText(_ text: String) -> NSSize {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let naturalWidth = text
            .components(separatedBy: .newlines)
            .map { ceil(($0 as NSString).size(withAttributes: attributes).width) }
            .max() ?? minimumTextWidth
        let textWidth = min(max(naturalWidth, minimumTextWidth), maximumTextWidth)
        let textHeight = min(ceil(measuredTextHeight(text, width: textWidth)), maximumTextHeight)

        return NSSize(
            width: textWidth + (horizontalPadding * 2),
            height: max(textHeight + (verticalPadding * 2), minimumPanelHeight)
        )
    }

    private static func measuredTextHeight(_ text: String, width: CGFloat) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        return (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle
            ]
        ).height
    }

    static func makeTextView(for text: String) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.string = text
        textView.font = font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        return textView
    }
}

struct URLInputField: NSViewRepresentable {
    @Binding var text: String
    let variables: [Variable]
    let placeholder: String
    var isFocused: Binding<Bool>
    let focusRequest: Int
    let onPaste: (String) -> Bool
    var accessibilityIdentifier = "url-input-field"
    var accessibilityLabel = "Request URL"
    var enablesRequestImport = true
    var onCommit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: isFocused, onPaste: onPaste, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> PasteAwareTextField {
        let textField = PasteAwareTextField()
        textField.cell = URLTokenTextFieldCell(textCell: "")
        textField.cell?.isScrollable = true
        textField.delegate = context.coordinator
        textField.onWillFocus = { [weak coordinator = context.coordinator] in
            coordinator?.isFocused.wrappedValue = true
        }
        textField.onCommit = { [weak coordinator = context.coordinator] in
            coordinator?.onCommit()
        }
        textField.onEndFocus = { [weak coordinator = context.coordinator] in
            coordinator?.isFocused.wrappedValue = false
        }
        textField.variables = variables
        context.coordinator.installTextObserverIfNeeded()
        textField.placeholderString = placeholder
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.refusesFirstResponder = false
        textField.focusRingType = .none
        textField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.baseAccessibilityLabel = accessibilityLabel
        textField.enablesRequestImport = enablesRequestImport
        textField.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        textField.setAccessibilityElement(true)
        textField.setAccessibilityIdentifier(accessibilityIdentifier)
        textField.setAccessibilityRole(.textField)
        textField.refreshVariableAccessibility()
        textField.refreshVariableToolTips()
        return textField
    }

    func updateNSView(_ textField: PasteAwareTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = isFocused
        context.coordinator.onPaste = onPaste
        context.coordinator.onCommit = onCommit
        textField.onWillFocus = { [weak coordinator = context.coordinator] in
            coordinator?.isFocused.wrappedValue = true
        }
        textField.onCommit = { [weak coordinator = context.coordinator] in
            coordinator?.onCommit()
        }
        textField.onEndFocus = { [weak coordinator = context.coordinator] in
            coordinator?.isFocused.wrappedValue = false
        }
        textField.variables = variables
        textField.placeholderString = placeholder
        textField.baseAccessibilityLabel = accessibilityLabel
        textField.enablesRequestImport = enablesRequestImport
        textField.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        textField.setAccessibilityIdentifier(accessibilityIdentifier)

        if let editor = textField.currentEditor() as? NSTextView {
            if context.coordinator.shouldApplyModelText(text, editorText: editor.string) {
                let selectedRange = editor.selectedRange()
                editor.string = text
                editor.setSelectedRange(Self.clampedSelection(selectedRange, in: text))
                editor.applyURLTokenAttributes(variables: variables)
                context.coordinator.recordEditedText(text)
            }
        } else if textField.stringValue != text {
            textField.stringValue = text
            textField.needsDisplay = true
            context.coordinator.recordEditedText(text)
        } else {
            textField.needsDisplay = true
            context.coordinator.recordEditedText(text)
        }
        textField.refreshVariableAccessibility()
        textField.refreshVariableToolTips()

        let shouldFocus = isFocused.wrappedValue || context.coordinator.consumeFocusRequest(focusRequest)
        if shouldFocus {
            DispatchQueue.main.async {
                if let editor = textField.currentEditor(),
                   textField.window?.firstResponder === editor {
                    return
                }
                textField.window?.makeFirstResponder(textField)
                textField.selectText(nil)
            }
        }
    }

    static func clampedSelection(_ selection: NSRange, in text: String) -> NSRange {
        let textLength = (text as NSString).length
        let location = min(selection.location, textLength)
        let length = min(selection.length, textLength - location)
        return NSRange(location: location, length: length)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var onPaste: (String) -> Bool
        var onCommit: () -> Void
        private var lastSelectedRange = NSRange(location: 0, length: 0)
        private var isAdjustingSelection = false
        private var pendingCurlParseWorkItem: DispatchWorkItem?
        private var previousEditedText: String
        private var lastObservedModelText: String
        private var pendingUserEditedText: String?
        private weak var activeTextField: PasteAwareTextField?
        private var didInstallTextObserver = false
        private var lastHandledFocusRequest = 0

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            onPaste: @escaping (String) -> Bool,
            onCommit: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.onPaste = onPaste
            self.onCommit = onCommit
            let initialText = text.wrappedValue
            self.previousEditedText = initialText
            self.lastObservedModelText = initialText
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func installTextObserverIfNeeded() {
            guard !didInstallTextObserver else {
                return
            }
            didInstallTextObserver = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textDidChangeNotification(_:)),
                name: NSText.didChangeNotification,
                object: nil
            )
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
            if let textField = notification.object as? PasteAwareTextField,
               let editor = textField.currentEditor() as? NSTextView {
                activeTextField = textField
                textField.needsDisplay = true
                textField.prepareFieldEditor(editor)
                editor.delegate = self
                let adjustedRange = URLTokenEditingPolicy.adjustedSelectionRange(
                    editor.selectedRange(),
                    previousSelection: lastSelectedRange,
                    in: editor.string
                )
                editor.setSelectedRange(adjustedRange)
                lastSelectedRange = adjustedRange
                previousEditedText = editor.string
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
            if let textField = notification.object as? PasteAwareTextField {
                textField.invalidateVariableToolTip()
                textField.needsDisplay = true
            }
            activeTextField = nil
        }

        @objc private func textDidChangeNotification(_ notification: Notification) {
            guard let textField = activeTextField,
                  let editor = notification.object as? NSTextView,
                  textField.currentEditor() === editor else {
                return
            }
            handleTextChange(in: textField)
        }

        func recordEditedText(_ text: String) {
            previousEditedText = text
            lastObservedModelText = text
            if pendingUserEditedText == text {
                pendingUserEditedText = nil
            }
        }

        func shouldApplyModelText(_ modelText: String, editorText: String) -> Bool {
            if modelText == editorText {
                recordEditedText(modelText)
                return false
            }

            if let pendingUserEditedText,
               editorText == pendingUserEditedText,
               modelText == lastObservedModelText {
                return false
            }

            lastObservedModelText = modelText
            self.pendingUserEditedText = nil
            return true
        }

        func consumeFocusRequest(_ focusRequest: Int) -> Bool {
            guard focusRequest != lastHandledFocusRequest else {
                return false
            }
            lastHandledFocusRequest = focusRequest
            return true
        }

        private func handleTextChange(in textField: PasteAwareTextField) {
            let editor = textField.currentEditor() as? NSTextView
            var currentText = editor?.string ?? textField.stringValue
            if let correction = URLTokenEditingPolicy.correctedTextAfterAtomicTokenEdit(
                previousText: previousEditedText,
                currentText: currentText
            ) {
                currentText = correction.text
                if let editor {
                    editor.string = correction.text
                    editor.setSelectedRange(NSRange(location: correction.caretLocation, length: 0))
                } else {
                    textField.stringValue = correction.text
                }
            }

            previousEditedText = currentText
            pendingUserEditedText = currentText
            text.wrappedValue = currentText
            if let editor {
                snapSelectionIfNeeded(in: editor)
                editor.applyURLTokenAttributes(variables: textField.variables)
                snapSelectionIfNeeded(in: editor)
            }
            textField.refreshVariableAccessibility()
            textField.refreshVariableToolTips()
            scheduleCurlImportIfNeeded(from: currentText, textField: textField)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSText.deleteBackward(_:)):
                return deleteBackward(in: textView)
            case #selector(NSText.deleteForward(_:)):
                return deleteForward(in: textView)
            case #selector(NSText.moveLeft(_:)):
                return moveLeft(in: textView)
            case #selector(NSText.moveRight(_:)):
                return moveRight(in: textView)
            case #selector(NSText.selectAll(_:)):
                textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
                return true
            case #selector(NSText.insertTab(_:)):
                guard let activeTextField else { return false }
                onCommit()
                isFocused.wrappedValue = false
                activeTextField.window?.selectNextKeyView(activeTextField)
                return true
            case #selector(NSText.insertBacktab(_:)):
                guard let activeTextField else { return false }
                onCommit()
                isFocused.wrappedValue = false
                activeTextField.window?.selectPreviousKeyView(activeTextField)
                return true
            case #selector(NSText.insertNewline(_:)):
                onCommit()
                isFocused.wrappedValue = false
                activeTextField?.window?.makeFirstResponder(nil)
                return true
            case #selector(NSText.paste(_:)):
                guard let pastedText = NSPasteboard.general.string(forType: .string) else {
                    return false
                }
                return handlePaste(pastedText)
            default:
                return false
            }
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if activeTextField?.enablesRequestImport == true,
               shouldHandleBulkCurlReplacement(
                replacementString: replacementString,
                affectedCharRange: affectedCharRange,
                in: textView
            ) {
                return false
            }

            if activeTextField?.enablesRequestImport == true,
               shouldHandleCompleteURLReplacement(
                replacementString: replacementString,
                affectedCharRange: affectedCharRange,
                in: textView
            ) {
                return false
            }

            let expandedRange = URLTokenEditingPolicy.expandedRangeIncludingTokens(affectedCharRange, in: textView.string)
            if expandedRange != affectedCharRange {
                replace(range: expandedRange, with: replacementString ?? "", in: textView)
                return false
            }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isAdjustingSelection,
                  let textView = notification.object as? NSTextView else {
                return
            }

            let proposedRange = textView.selectedRange()
            let adjustedRange = URLTokenEditingPolicy.adjustedSelectionRange(
                proposedRange,
                previousSelection: lastSelectedRange,
                in: textView.string
            )
            if adjustedRange != proposedRange {
                isAdjustingSelection = true
                textView.setSelectedRange(adjustedRange)
                isAdjustingSelection = false
            }
            lastSelectedRange = adjustedRange
        }

        private func snapSelectionIfNeeded(in textView: NSTextView) {
            let proposedRange = textView.selectedRange()
            let adjustedRange = URLTokenEditingPolicy.adjustedSelectionRange(
                proposedRange,
                previousSelection: lastSelectedRange,
                in: textView.string
            )
            guard adjustedRange != proposedRange else {
                lastSelectedRange = adjustedRange
                return
            }
            isAdjustingSelection = true
            textView.setSelectedRange(adjustedRange)
            isAdjustingSelection = false
            lastSelectedRange = adjustedRange
        }

        private func deleteBackward(in textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            if selectedRange.length > 0 {
                textView.delete(nil)
                return true
            }

            guard let tokenRange = URLTokenEditingPolicy.tokenRangeBeforeOrContainingCaret(selectedRange.location, in: textView.string) else {
                return false
            }
            replace(range: tokenRange, with: "", in: textView)
            return true
        }

        private func deleteForward(in textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            if selectedRange.length > 0 {
                textView.delete(nil)
                return true
            }

            guard let tokenRange = URLTokenEditingPolicy.tokenRangeAfterOrContainingCaret(selectedRange.location, in: textView.string) else {
                return false
            }
            replace(range: tokenRange, with: "", in: textView)
            return true
        }

        private func moveLeft(in textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            guard selectedRange.length == 0,
                  let tokenRange = URLTokenEditingPolicy.tokenRanges(in: textView.string).first(where: { NSMaxRange($0) == selectedRange.location }) else {
                return false
            }
            textView.setSelectedRange(NSRange(location: tokenRange.location, length: 0))
            return true
        }

        private func moveRight(in textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            guard selectedRange.length == 0,
                  let tokenRange = URLTokenEditingPolicy.tokenRanges(in: textView.string).first(where: { $0.location == selectedRange.location }) else {
                return false
            }
            textView.setSelectedRange(NSRange(location: NSMaxRange(tokenRange), length: 0))
            return true
        }

        private func replace(range: NSRange, with replacement: String, in textView: NSTextView) {
            guard textView.shouldChangeText(in: range, replacementString: replacement) else {
                return
            }
            let source = textView.string as NSString
            textView.string = source.replacingCharacters(in: range, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
            text.wrappedValue = textView.string
            textView.applyURLTokenAttributes(variables: activeTextField?.variables ?? [])
        }

        private func shouldHandleBulkCurlReplacement(
            replacementString: String?,
            affectedCharRange: NSRange,
            in textView: NSTextView
        ) -> Bool {
            guard let replacementString,
                  replacementString.utf16.count > 1 else {
                return false
            }

            let candidate = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
            return Self.looksLikeCompleteCurlCommand(candidate) && handlePaste(candidate)
        }

        private func shouldHandleCompleteURLReplacement(
            replacementString: String?,
            affectedCharRange: NSRange,
            in textView: NSTextView
        ) -> Bool {
            guard let replacementString,
                  affectedCharRange.length == 0,
                  replacementString.utf16.count > 1,
                  Self.looksLikeAbsoluteURL(replacementString),
                  Self.looksLikeAbsoluteURL(textView.string) || Self.looksLikeURLWithMissingAuthority(textView.string) else {
                return false
            }

            replace(range: NSRange(location: 0, length: (textView.string as NSString).length), with: replacementString, in: textView)
            return true
        }

        private func scheduleCurlImportIfNeeded(from candidate: String, textField: PasteAwareTextField) {
            pendingCurlParseWorkItem?.cancel()
            guard textField.enablesRequestImport, Self.looksLikeCompleteCurlCommand(candidate) else {
                return
            }

            let workItem = DispatchWorkItem { [weak self, weak textField] in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    let currentText = (textField?.currentEditor() as? NSTextView)?.string
                        ?? textField?.stringValue
                        ?? self.text.wrappedValue
                    guard currentText == candidate else {
                        return
                    }
                    _ = self.handlePaste(candidate)
                }
            }
            pendingCurlParseWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
        }

        private func handlePaste(_ pastedText: String) -> Bool {
            let didHandle = onPaste(pastedText)
            if didHandle {
                pendingCurlParseWorkItem?.cancel()
            }
            return didHandle
        }

        private static func looksLikeCurlCommand(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "curl" ||
                trimmed.hasPrefix("curl ") ||
                trimmed.hasPrefix("curl\t") ||
                trimmed.hasPrefix("curl\n") ||
                trimmed.hasPrefix("printf '%b' ")
        }

        private static func looksLikeCompleteCurlCommand(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasURLCandidate = trimmed.contains("://") ||
                trimmed.contains("--url") ||
                (trimmed.contains("{{") && trimmed.contains("}}"))
            return looksLikeCurlCommand(trimmed) && hasURLCandidate
        }

        private static func looksLikeAbsoluteURL(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let schemeRange = trimmed.range(of: "://"),
                  !trimmed[..<schemeRange.lowerBound].isEmpty else {
                return false
            }
            return true
        }

        private static func looksLikeURLWithMissingAuthority(_ text: String) -> Bool {
            text.contains(":///")
        }
    }
}

enum URLTokenEditingPolicy {
    static func tokenRanges(in text: String) -> [NSRange] {
        VariableTemplateParser.parse(text).compactMap { segment in
            if case .token(let token) = segment {
                return token.range
            }
            return nil
        }
    }

    static func adjustedSelectionRange(_ range: NSRange, previousSelection: NSRange, in text: String) -> NSRange {
        guard range.length == 0 else {
            return expandedRangeIncludingTokens(range, in: text)
        }

        for tokenRange in tokenRanges(in: text) where containsInterior(tokenRange, location: range.location) {
            let previousLocation = previousSelection.location
            let midpoint = tokenRange.location + tokenRange.length / 2
            let targetLocation: Int
            if previousLocation <= tokenRange.location {
                targetLocation = NSMaxRange(tokenRange)
            } else if previousLocation >= NSMaxRange(tokenRange) {
                targetLocation = tokenRange.location
            } else {
                targetLocation = range.location < midpoint ? tokenRange.location : NSMaxRange(tokenRange)
            }
            return NSRange(location: targetLocation, length: 0)
        }

        return range
    }

    static func expandedRangeIncludingTokens(_ range: NSRange, in text: String) -> NSRange {
        var expandedRange = range
        for tokenRange in tokenRanges(in: text) where rangesIntersect(expandedRange, tokenRange) || rangeIsInside(expandedRange, tokenRange) {
            let lowerBound = min(expandedRange.location, tokenRange.location)
            let upperBound = max(NSMaxRange(expandedRange), NSMaxRange(tokenRange))
            expandedRange = NSRange(location: lowerBound, length: upperBound - lowerBound)
        }
        return expandedRange
    }

    static func tokenRangeBeforeOrContainingCaret(_ location: Int, in text: String) -> NSRange? {
        tokenRanges(in: text).first { tokenRange in
            NSMaxRange(tokenRange) == location || containsInterior(tokenRange, location: location)
        }
    }

    static func tokenRangeAfterOrContainingCaret(_ location: Int, in text: String) -> NSRange? {
        tokenRanges(in: text).first { tokenRange in
            tokenRange.location == location || containsInterior(tokenRange, location: location)
        }
    }

    static func correctedTextAfterAtomicTokenEdit(previousText: String, currentText: String) -> (text: String, caretLocation: Int)? {
        guard previousText != currentText else {
            return nil
        }

        let tokenRanges = tokenRanges(in: previousText)
        guard !tokenRanges.isEmpty else {
            return nil
        }

        let previousSource = previousText as NSString
        let currentSource = currentText as NSString
        let previousLength = previousSource.length
        let currentLength = currentSource.length
        var prefixLength = 0
        while prefixLength < previousLength,
              prefixLength < currentLength,
              previousSource.character(at: prefixLength) == currentSource.character(at: prefixLength) {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < previousLength - prefixLength,
              suffixLength < currentLength - prefixLength,
              previousSource.character(at: previousLength - suffixLength - 1) == currentSource.character(at: currentLength - suffixLength - 1) {
            suffixLength += 1
        }

        let changedPreviousRange = NSRange(
            location: prefixLength,
            length: previousLength - prefixLength - suffixLength
        )
        let insertedRange = NSRange(
            location: prefixLength,
            length: currentLength - prefixLength - suffixLength
        )
        let insertedText = currentSource.substring(with: insertedRange)

        guard let tokenRange = tokenRanges.first(where: { tokenRange in
            rangesIntersect(changedPreviousRange, tokenRange) || rangeIsInside(changedPreviousRange, tokenRange)
        }) else {
            return nil
        }

        let correctedText = previousSource.replacingCharacters(in: tokenRange, with: insertedText)
        return (correctedText, tokenRange.location + (insertedText as NSString).length)
    }

    private static func rangesIntersect(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    private static func rangeIsInside(_ range: NSRange, _ tokenRange: NSRange) -> Bool {
        range.length == 0 && containsInterior(tokenRange, location: range.location)
    }

    private static func containsInterior(_ range: NSRange, location: Int) -> Bool {
        location > range.location && location < NSMaxRange(range)
    }
}

final class PasteAwareTextField: NSTextField {
    private struct ToolTipRegion: Equatable {
        let rect: NSRect
        let item: VariableTemplateTokenToolTip
    }

    var onWillFocus: (() -> Void)?
    var onCommit: (() -> Void)?
    var onEndFocus: (() -> Void)?
    private var variableToolTipRegions: [ToolTipRegion] = []
    private var variableTrackingArea: NSTrackingArea?
    private var variableToolTipPanel: NSWindow?
    private var displayedVariableToolTip: VariableTemplateTokenToolTip?
    private var pendingVariableToolTip: DispatchWorkItem?
    private var pendingVariableToolTipItem: VariableTemplateTokenToolTip?
    private var pendingVariableToolTipID: UUID?
    var baseAccessibilityLabel = "Variable template field" {
        didSet {
            refreshVariableAccessibility()
        }
    }
    var enablesRequestImport = true
    var variables: [Variable] = [] {
        didSet {
            guard oldValue != variables else { return }
            hideVariableToolTip()
            if let editor = currentEditor() as? NSTextView {
                editor.applyURLTokenAttributes(variables: variables)
            }
            needsDisplay = true
            refreshVariableAccessibility()
            refreshVariableToolTips()
        }
    }

    func refreshVariableAccessibility() {
        let text = (currentEditor() as? NSTextView)?.string ?? stringValue
        let status = VariableTemplateFieldAccessibility.description(text: text, variables: variables)
        setAccessibilityLabel([baseAccessibilityLabel, status].compactMap { $0 }.joined(separator: ". "))
        setAccessibilityHelp(status)
    }

    func refreshVariableToolTips() {
        guard currentEditor() == nil else {
            replaceVariableToolTipRegions(with: [])
            return
        }
        let text = stringValue
        guard !text.isEmpty,
              bounds.width > 0,
              bounds.height > 0,
              let cell else {
            replaceVariableToolTipRegions(with: [])
            return
        }

        let drawingRect = cell.titleRect(forBounds: bounds)
        guard drawingRect.width > 0, drawingRect.height > 0 else {
            replaceVariableToolTipRegions(with: [])
            return
        }

        let attributedText = NSMutableAttributedString(string: text, attributes: Self.baseAttributes)
        let items = VariableTemplateTokenToolTips.items(text: text, variables: variables)
        for item in items {
            attributedText.addAttributes(
                Self.tokenAttributes(for: item.status),
                range: item.range
            )
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = lineBreakMode
        attributedText.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: attributedText.length)
        )

        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: drawingRect.size)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 1
        textContainer.lineBreakMode = lineBreakMode
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        var newRegions: [ToolTipRegion] = []
        for item in items {
            guard NSMaxRange(item.range) <= textStorage.length else {
                continue
            }
            guard var tokenRect = VariableTokenHoverGeometry.visibleGlyphRect(
                for: item.range,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) else {
                continue
            }
            tokenRect.origin.x += drawingRect.minX
            tokenRect.origin.y += drawingRect.minY
            tokenRect = tokenRect.intersection(drawingRect)
            guard !tokenRect.isNull, tokenRect.width > 0, tokenRect.height > 0 else {
                continue
            }

            newRegions.append(ToolTipRegion(rect: tokenRect, item: item))
        }
        replaceVariableToolTipRegions(with: newRegions)
    }

    private func replaceVariableToolTipRegions(with newRegions: [ToolTipRegion]) {
        if newRegions != variableToolTipRegions {
            hideVariableToolTip()
        }
        variableToolTipRegions = newRegions
    }

    override func layout() {
        super.layout()
        refreshVariableToolTips()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            hideVariableToolTip()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        if let variableTrackingArea {
            removeTrackingArea(variableTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        variableTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        guard currentEditor() == nil else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let region = variableToolTipRegions.first(where: { $0.rect.contains(point) }) else {
            hideVariableToolTip()
            return
        }
        showVariableToolTip(region.item, anchoredTo: region.rect, in: self)
    }

    override func mouseEntered(with event: NSEvent) {
        guard currentEditor() == nil else {
            return
        }
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if currentEditor() == nil {
            hideVariableToolTip()
        }
        super.mouseExited(with: event)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        guard didBecomeFirstResponder else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.beginEditingIfNeeded(selectAll: false)
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        hideVariableToolTip()
        onWillFocus?()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        beginEditingIfNeeded(selectAll: false)
    }

    override func scrollWheel(with event: NSEvent) {
        hideVariableToolTip()
        if currentEditor() == nil {
            beginEditingIfNeeded(selectAll: false)
        }
        guard let editor = currentEditor() as? URLTokenFieldEditor else {
            super.scrollWheel(with: event)
            return
        }
        editor.scrollHorizontally(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
    }

    override func accessibilityPerformPress() -> Bool {
        onWillFocus?()
        beginEditingIfNeeded(selectAll: true)
        return true
    }

    func beginEditingIfNeeded(selectAll: Bool) {
        guard let window else {
            return
        }
        onWillFocus?()
        let previousSelection = (currentEditor() as? NSTextView)?.selectedRange()
        if currentEditor() == nil || window.firstResponder !== currentEditor() {
            selectText(nil)
        }
        needsDisplay = true
        guard let editor = currentEditor() as? NSTextView else { return }
        prepareFieldEditor(editor)
        if selectAll {
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        } else if let previousSelection {
            let textLength = (editor.string as NSString).length
            let location = min(previousSelection.location, textLength)
            let length = min(previousSelection.length, textLength - location)
            editor.setSelectedRange(NSRange(location: location, length: length))
        } else {
            editor.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    func prepareFieldEditor(_ editor: NSTextView) {
        editor.isRichText = false
        editor.allowsUndo = true
        editor.allowsImageEditing = false
        editor.importsGraphics = false
        editor.font = Self.baseFont
        editor.textColor = .labelColor
        editor.typingAttributes = Self.baseAttributes
        editor.insertionPointColor = .labelColor
        editor.backgroundColor = surfaceRaisedNS
        editor.drawsBackground = true
        if let editor = editor as? URLTokenFieldEditor {
            editor.onVariableTokenHover = { [weak self] item, screenPoint in
                guard let self else { return }
                if let item, let screenPoint {
                    showVariableToolTip(item, anchoredAt: screenPoint)
                } else {
                    hideVariableToolTip()
                }
            }
            editor.onCommitAndMove = { [weak self] movesBackward in
                guard let self else { return }
                hideVariableToolTip()
                onCommit?()
                onEndFocus?()
                if movesBackward {
                    window?.selectPreviousKeyView(self)
                } else {
                    window?.selectNextKeyView(self)
                }
            }
            editor.onCommitAndEndEditing = { [weak self] in
                self?.hideVariableToolTip()
                self?.onCommit?()
                self?.onEndFocus?()
                self?.window?.makeFirstResponder(nil)
            }
        }
        editor.applyURLTokenAttributes(variables: variables)
        refreshVariableToolTips()
    }

    private func showVariableToolTip(
        _ item: VariableTemplateTokenToolTip,
        anchoredTo rect: NSRect,
        in view: NSView
    ) {
        guard let window = view.window else { return }
        let anchorInWindow = view.convert(NSPoint(x: rect.midX, y: rect.maxY), to: nil)
        showVariableToolTip(item, anchoredAt: window.convertPoint(toScreen: anchorInWindow))
    }

    private func showVariableToolTip(
        _ item: VariableTemplateTokenToolTip,
        anchoredAt screenPoint: NSPoint
    ) {
        if displayedVariableToolTip == item, variableToolTipPanel?.isVisible == true {
            return
        }
        if pendingVariableToolTipItem == item {
            return
        }
        hideVariableToolTip()

        let requestID = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, pendingVariableToolTipID == requestID else {
                return
            }
            pendingVariableToolTip = nil
            pendingVariableToolTipItem = nil
            pendingVariableToolTipID = nil
            presentVariableToolTip(item, anchoredAt: screenPoint)
        }
        pendingVariableToolTip = workItem
        pendingVariableToolTipItem = item
        pendingVariableToolTipID = requestID
        DispatchQueue.main.asyncAfter(
            deadline: .now() + VariableTokenToolTipLayout.presentationDelay,
            execute: workItem
        )
    }

    private func presentVariableToolTip(
        _ item: VariableTemplateTokenToolTip,
        anchoredAt screenPoint: NSPoint
    ) {
        let text = VariableTokenToolTipLayout.visibleText(for: item.text)
        let textView = VariableTokenToolTipLayout.makeTextView(for: text)
        textView.identifier = NSUserInterfaceItemIdentifier("variable-token-tooltip")
        textView.setAccessibilityElement(true)
        textView.setAccessibilityIdentifier("variable-token-tooltip")
        textView.setAccessibilityLabel(text)
        textView.setAccessibilityRole(.staticText)

        let panelSize = VariableTokenToolTipLayout.panelSize(for: text)
        let textSize = NSSize(
            width: panelSize.width - (VariableTokenToolTipLayout.horizontalPadding * 2),
            height: panelSize.height - (VariableTokenToolTipLayout.verticalPadding * 2)
        )
        let contentView = NSView(frame: NSRect(origin: .zero, size: panelSize))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        contentView.layer?.cornerRadius = 6
        contentView.layer?.borderWidth = 1
        contentView.layer?.borderColor = NSColor.separatorColor.cgColor
        textView.frame = NSRect(
            x: VariableTokenToolTipLayout.horizontalPadding,
            y: VariableTokenToolTipLayout.verticalPadding,
            width: textSize.width,
            height: textSize.height
        )
        contentView.addSubview(textView)

        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.contentView = contentView

        let visibleFrame = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        var origin = NSPoint(
            x: screenPoint.x - panelSize.width / 2,
            y: screenPoint.y - panelSize.height - 6
        )
        if let visibleFrame {
            origin.x = min(max(origin.x, visibleFrame.minX + 4), visibleFrame.maxX - panelSize.width - 4)
            if origin.y < visibleFrame.minY + 4 {
                origin.y = screenPoint.y + 6
            }
            origin.y = min(origin.y, visibleFrame.maxY - panelSize.height - 4)
        }
        panel.setFrameOrigin(origin)
        window?.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        variableToolTipPanel = panel
        displayedVariableToolTip = item
    }

    private func hideVariableToolTip() {
        pendingVariableToolTip?.cancel()
        pendingVariableToolTip = nil
        pendingVariableToolTipItem = nil
        pendingVariableToolTipID = nil
        guard let panel = variableToolTipPanel else {
            displayedVariableToolTip = nil
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        variableToolTipPanel = nil
        displayedVariableToolTip = nil
    }

    func invalidateVariableToolTip() {
        hideVariableToolTip()
    }

    func applyTokenAttributes() {
        needsDisplay = true
    }

    fileprivate var isEditingWithFieldEditor: Bool {
        guard let editor = currentEditor() else {
            return false
        }
        return window?.firstResponder === editor
    }

    fileprivate static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: baseFont,
        .foregroundColor: NSColor.labelColor
    ]

    fileprivate static let baseFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    fileprivate static func tokenAttributes(for status: VariableTokenStatus) -> [NSAttributedString.Key: Any] {
        return [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: VariableTokenPalette.nsColor(for: status)
        ]
    }
}

private extension NSTextView {
    func applyURLTokenAttributes(variables: [Variable]) {
        let selectedRangesBeforeStyling = selectedRanges
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        textStorage?.setAttributes(PasteAwareTextField.baseAttributes, range: fullRange)
        let items = VariableTemplateTokenToolTips.items(text: string, variables: variables)
        if let editor = self as? URLTokenFieldEditor {
            editor.updateVariableToolTips(items)
        }
        for item in items {
            textStorage?.addAttributes(
                PasteAwareTextField.tokenAttributes(for: item.status),
                range: item.range
            )
        }
        typingAttributes = PasteAwareTextField.baseAttributes
        selectedRanges = selectedRangesBeforeStyling
    }
}

private final class URLTokenTextFieldCell: NSTextFieldCell {
    private lazy var tokenFieldEditor: URLTokenFieldEditor = {
        let editor = URLTokenFieldEditor()
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.allowsImageEditing = false
        editor.importsGraphics = false
        editor.font = PasteAwareTextField.baseFont
        editor.textColor = .labelColor
        editor.typingAttributes = PasteAwareTextField.baseAttributes
        editor.backgroundColor = surfaceRaisedNS
        editor.drawsBackground = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        tokenFieldEditor
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let textField = controlView as? PasteAwareTextField else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        if textField.isEditingWithFieldEditor {
            return
        }

        guard !stringValue.isEmpty else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }

        let attributedValue = NSMutableAttributedString(string: stringValue, attributes: PasteAwareTextField.baseAttributes)
        for segment in VariableTemplateParser.parse(stringValue, variables: textField.variables) {
            guard case .token(let token) = segment else {
                continue
            }
            attributedValue.addAttributes(PasteAwareTextField.tokenAttributes(for: token.status), range: token.range)
        }

        let drawingRect = titleRect(forBounds: cellFrame)
        attributedValue.draw(with: drawingRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

final class URLTokenFieldEditor: NSTextView {
    var onCommitAndMove: ((Bool) -> Void)?
    var onCommitAndEndEditing: (() -> Void)?
    var onVariableTokenHover: ((VariableTemplateTokenToolTip?, NSPoint?) -> Void)?
    private var variableToolTips: [VariableTemplateTokenToolTip] = []
    private var variableTrackingArea: NSTrackingArea?
    nonisolated(unsafe) private var variableMouseMonitor: Any?

    deinit {
        if let variableMouseMonitor {
            NSEvent.removeMonitor(variableMouseMonitor)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window, let variableMouseMonitor {
            NSEvent.removeMonitor(variableMouseMonitor)
            self.variableMouseMonitor = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, variableMouseMonitor == nil else { return }
        variableMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleVariableHover(event)
            return event
        }
    }

    override func updateTrackingAreas() {
        if let variableTrackingArea {
            removeTrackingArea(variableTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        variableTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        handleVariableHover(event)
    }

    func updateVariableToolTips(_ items: [VariableTemplateTokenToolTip]) {
        guard items != variableToolTips else {
            return
        }
        variableToolTips = items
        onVariableTokenHover?(nil, nil)
    }

    func variableToolTip(atCharacterIndex characterIndex: Int) -> VariableTemplateTokenToolTip? {
        variableToolTips.first { NSLocationInRange(characterIndex, $0.range) }
    }

    private func handleVariableHover(_ event: NSEvent) {
        guard event.window === window,
              window?.firstResponder === self,
              visibleRect.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        guard let layoutManager,
              let textContainer,
              let textStorage,
              textStorage.length > 0 else {
            onVariableTokenHover?(nil, nil)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            onVariableTokenHover?(nil, nil)
            return
        }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length,
              let item = variableToolTip(atCharacterIndex: characterIndex) else {
            onVariableTokenHover?(nil, nil)
            return
        }

        guard var tokenRect = VariableTokenHoverGeometry.visibleGlyphRect(
            for: item.range,
            layoutManager: layoutManager,
            textContainer: textContainer
        ) else {
            onVariableTokenHover?(nil, nil)
            return
        }
        guard VariableTokenHoverGeometry.containsHorizontally(
            containerPoint,
            in: tokenRect
        ) else {
            onVariableTokenHover?(nil, nil)
            return
        }
        tokenRect.origin.x += textContainerOrigin.x
        tokenRect.origin.y += textContainerOrigin.y
        guard let window else {
            onVariableTokenHover?(nil, nil)
            return
        }
        let anchorInWindow = convert(NSPoint(x: tokenRect.midX, y: tokenRect.maxY), to: nil)
        onVariableTokenHover?(item, window.convertPoint(toScreen: anchorInWindow))
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onVariableTokenHover?(nil, nil)
        super.mouseExited(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        scrollHorizontally(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
    }

    func scrollHorizontally(deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool) {
        let dominantDelta = abs(deltaX) > 0.01 ? deltaX : deltaY
        guard abs(dominantDelta) > 0.01 else { return }

        onVariableTokenHover?(nil, nil)
        let distance = dominantDelta * (hasPreciseDeltas ? 1 : 16)
        let maximumOriginX = max(0, bounds.width - visibleRect.width)
        let targetOriginX = min(max(visibleRect.minX - distance, 0), maximumOriginX)
        scroll(NSPoint(x: targetOriginX, y: visibleRect.minY))
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48 {
            onCommitAndMove?(modifiers.contains(.shift))
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76), !modifiers.contains(.command) {
            onCommitAndEndEditing?()
            return
        }
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll(nil)
            return
        }

        super.keyDown(with: event)
    }
}
