import AppKit
import SwiftUI

struct JSONCodeEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var foldedRanges: [NSRange]
    var isEditable: Bool
    var accessibilityIdentifier: String
    @Environment(\.colorScheme) var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, foldedRanges: $foldedRanges)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = resolvedSurfaceRaised(for: colorScheme)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.setAccessibilityIdentifier(accessibilityIdentifier)

        let textStorage = NSTextStorage(string: text)
        let layoutManager = JSONFoldingLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false

        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.backgroundColor = resolvedSurfaceRaised(for: colorScheme)
        textView.drawsBackground = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("\(accessibilityIdentifier)-text-view")

        scrollView.documentView = textView
        let rulerView = JSONLineNumberRulerView(textView: textView)
        rulerView.onToggleFold = { [weak coordinator = context.coordinator] lineNumber in
            coordinator?.toggleFold(atZeroBasedLine: lineNumber)
        }
        scrollView.verticalRulerView = rulerView

        context.coordinator.textView = textView
        context.coordinator.layoutManager = layoutManager
        context.coordinator.rulerView = rulerView
        context.coordinator.applyHighlighting(to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        scrollView.backgroundColor = resolvedSurfaceRaised(for: colorScheme)
        textView.backgroundColor = resolvedSurfaceRaised(for: colorScheme)

        context.coordinator.text = $text
        context.coordinator.foldedRanges = $foldedRanges

        if textView.string != text {
            context.coordinator.layoutManager?.foldedRanges = []
            let selectedRanges = context.coordinator.clampedSelectedRanges(for: textView, replacementLength: (text as NSString).length)
            context.coordinator.isProgrammaticUpdate = true
            textView.string = text
            textView.selectedRanges = selectedRanges
            context.coordinator.isProgrammaticUpdate = false
            context.coordinator.applyHighlighting(to: textView)
        }

        textView.isEditable = isEditable
        context.coordinator.layoutManager?.foldedRanges = context.coordinator.validFoldedRanges(in: textView.string)
        context.coordinator.rulerView?.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var foldedRanges: Binding<[NSRange]>
        weak var textView: NSTextView?
        weak var layoutManager: JSONFoldingLayoutManager?
        weak var rulerView: JSONLineNumberRulerView?
        private var isApplyingHighlighting = false
        var isProgrammaticUpdate = false

        init(text: Binding<String>, foldedRanges: Binding<[NSRange]>) {
            self.text = text
            self.foldedRanges = foldedRanges
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            guard !isProgrammaticUpdate else {
                return
            }

            text.wrappedValue = textView.string
            foldedRanges.wrappedValue = validFoldedRanges(in: textView.string)
            applyHighlighting(to: textView)
            rulerView?.needsDisplay = true
        }

        @MainActor
        func toggleFold(atZeroBasedLine lineNumber: Int) {
            guard let textView else { return }
            let lineMap = JSONLineMap(text: textView.string)
            guard let foldRange = JSONFoldIndex.foldRanges(in: textView.string).first(where: {
                lineMap.lineNumber(at: $0.openTokenRange.location) == lineNumber
            }) else {
                return
            }

            if let index = foldedRanges.wrappedValue.firstIndex(where: { $0 == foldRange.fullRange }) {
                foldedRanges.wrappedValue.remove(at: index)
            } else {
                foldedRanges.wrappedValue.append(foldRange.fullRange)
            }

            layoutManager?.foldedRanges = validFoldedRanges(in: textView.string)
            rulerView?.needsDisplay = true
        }

        func validFoldedRanges(in string: String) -> [NSRange] {
            let length = (string as NSString).length
            return foldedRanges.wrappedValue.filter { range in
                range.location >= 0 && range.length > 0 && NSMaxRange(range) <= length
            }
        }

        @MainActor
        func clampedSelectedRanges(for textView: NSTextView, replacementLength: Int) -> [NSValue] {
            let ranges = textView.selectedRanges.compactMap { value -> NSValue? in
                let range = value.rangeValue
                guard range.location <= replacementLength else {
                    return nil
                }
                let length = min(range.length, replacementLength - range.location)
                return NSValue(range: NSRange(location: range.location, length: length))
            }
            return ranges.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : ranges
        }

        @MainActor
        func applyHighlighting(to textView: NSTextView) {
            guard !isApplyingHighlighting else {
                return
            }

            isApplyingHighlighting = true
            defer { isApplyingHighlighting = false }

            let source = textView.string as NSString
            let fullRange = NSRange(location: 0, length: source.length)
            let selectedRanges = textView.selectedRanges

            let storage = textView.textStorage
            storage?.beginEditing()
            storage?.setAttributes(baseAttributes, range: fullRange)

            for token in JSONLexer.tokenize(textView.string) {
                guard token.range.location != NSNotFound, NSMaxRange(token.range) <= source.length else {
                    continue
                }
                storage?.addAttributes(attributes(for: token.kind), range: token.range)
            }

            storage?.endEditing()
            let currentLength = (textView.string as NSString).length
            let safeRanges = selectedRanges.compactMap { value -> NSValue? in
                let range = value.rangeValue
                guard range.location <= currentLength else { return nil }
                return NSValue(range: NSRange(location: range.location, length: min(range.length, currentLength - range.location)))
            }
            textView.selectedRanges = safeRanges.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : safeRanges
        }

        private var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        }

        private func attributes(for kind: JSONTokenKind) -> [NSAttributedString.Key: Any] {
            switch kind {
            case .string:
                return [.foregroundColor: NSColor.systemGreen]
            case .number:
                return [.foregroundColor: NSColor.systemOrange]
            case .boolLiteral, .nullLiteral:
                return [.foregroundColor: NSColor.systemPurple]
            case .lineComment, .blockComment:
                return [.foregroundColor: NSColor.secondaryLabelColor]
            case .leftBrace, .rightBrace, .leftBracket, .rightBracket, .colon, .comma:
                return [.foregroundColor: NSColor.systemBlue]
            case .other:
                return [.foregroundColor: NSColor.systemRed]
            case .whitespace:
                return [:]
            }
        }
    }
}

struct JSONEditorPanel: View {
    @Binding var text: String
    var isEditable: Bool
    var showsValidation: Bool = true
    var minHeight: CGFloat = 220
    var accessibilityIdentifier: String
    @Binding var foldedRanges: [NSRange]
    var showsFoldingControls: Bool = true

    @State private var validationResult = JSONValidationResult(isValid: true, errorMessage: nil)
    @State private var formattingError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if showsValidation {
                    validationBadge
                }

                Spacer()

                if showsFoldingControls {
                    Button {
                        collapseAll()
                    } label: {
                        Label("Collapse", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .labelStyle(.iconOnly)
                    .help("Collapse JSON containers")
                    .accessibilityIdentifier("\(accessibilityIdentifier)-collapse")
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        expandAll()
                    } label: {
                        Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .labelStyle(.iconOnly)
                    .help("Expand JSON containers")
                    .accessibilityIdentifier("\(accessibilityIdentifier)-expand")
                    .disabled(foldedRanges.isEmpty)
                }

                if isEditable {
                    Button("Format") {
                        format()
                    }
                    .accessibilityIdentifier("\(accessibilityIdentifier)-format")
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Compact") {
                        compact()
                    }
                    .accessibilityIdentifier("\(accessibilityIdentifier)-compact")
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            JSONCodeEditorView(
                text: $text,
                foldedRanges: $foldedRanges,
                isEditable: isEditable,
                accessibilityIdentifier: accessibilityIdentifier
            )
            .frame(minHeight: minHeight, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }

            if let formattingError {
                Text(formattingError)
                    .font(.caption)
                    .foregroundStyle(Color.accent)
            }
        }
        .onAppear(perform: refreshValidation)
        .onChange(of: text) { _, _ in
            refreshValidation()
            foldedRanges = []
            formattingError = nil
        }
    }

    private var validationBadge: some View {
        Label(validationResult.isValid ? "Valid JSON" : "Invalid JSON", systemImage: validationResult.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(validationResult.isValid ? Color.green : Color.orange)
            .help(validationResult.errorMessage ?? "JSON is valid")
    }

    private var borderColor: Color {
        validationResult.isValid ? Color(nsColor: .separatorColor).opacity(0.7) : .orange.opacity(0.8)
    }

    private func refreshValidation() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        validationResult = trimmed.isEmpty ? JSONValidationResult(isValid: true, errorMessage: nil) : JSONValidator.validate(text)
    }

    private func collapseAll() {
        foldedRanges = JSONFoldIndex.foldRanges(in: text).map(\.fullRange)
    }

    private func expandAll() {
        foldedRanges = []
    }

    private func format() {
        do {
            text = try JSONFormatter.format(text)
            formattingError = nil
        } catch {
            formattingError = error.localizedDescription
        }
    }

    private func compact() {
        do {
            text = try JSONFormatter.compact(text)
            formattingError = nil
        } catch {
            formattingError = error.localizedDescription
        }
    }
}
