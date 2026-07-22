import AppKit
import SwiftUI

struct JSONCodeEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var foldedRanges: [NSRange]
    var isEditable: Bool
    var accessibilityIdentifier: String
    var diagnostic: JSONDiagnostic?
    var revealDiagnosticGeneration: Int
    @Environment(\.colorScheme) var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            foldedRanges: $foldedRanges,
            highlightsVisibleRangeOnly: !isEditable
        )
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

        let textView = JSONCodeTextView(frame: .zero, textContainer: textContainer)
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
        textView.allowsUndo = isEditable
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
        context.coordinator.observeViewport(of: scrollView)
        let initialAnalysis = SyntaxAnalysisResult.analyze(text)
        context.coordinator.latestAnalysis = initialAnalysis
        context.coordinator.applyHighlighting(to: textView, using: initialAnalysis)
        context.coordinator.applyDiagnostic(diagnostic, to: textView)
        context.coordinator.lastRevealDiagnosticGeneration = revealDiagnosticGeneration

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? JSONCodeTextView else {
            return
        }

        scrollView.backgroundColor = resolvedSurfaceRaised(for: colorScheme)
        textView.backgroundColor = resolvedSurfaceRaised(for: colorScheme)

        context.coordinator.text = $text
        context.coordinator.foldedRanges = $foldedRanges
        let changedHighlightingMode = context.coordinator.highlightsVisibleRangeOnly == isEditable
        context.coordinator.highlightsVisibleRangeOnly = !isEditable
        if changedHighlightingMode {
            context.coordinator.highlightedRange = nil
        }

        if textView.string != text {
            context.coordinator.layoutManager?.foldedRanges = []
            context.coordinator.highlightedRange = nil
            let selectedRanges = context.coordinator.clampedSelectedRanges(for: textView, replacementLength: (text as NSString).length)
            context.coordinator.isProgrammaticUpdate = true
            textView.string = text
            textView.selectedRanges = selectedRanges
            context.coordinator.isProgrammaticUpdate = false
            let analysis = SyntaxAnalysisResult.analyze(text)
            context.coordinator.latestAnalysis = analysis
            context.coordinator.applyHighlighting(to: textView, using: analysis)
            context.coordinator.rulerView?.invalidateFoldCache()
        }

        textView.isEditable = isEditable
        textView.allowsUndo = isEditable
        context.coordinator.layoutManager?.foldedRanges = context.coordinator.validFoldedRanges(in: textView.string)
        context.coordinator.applyDiagnostic(diagnostic, to: textView)
        if context.coordinator.lastRevealDiagnosticGeneration != revealDiagnosticGeneration {
            context.coordinator.lastRevealDiagnosticGeneration = revealDiagnosticGeneration
            context.coordinator.revealDiagnostic(diagnostic, in: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var foldedRanges: Binding<[NSRange]>
        weak var textView: JSONCodeTextView?
        weak var layoutManager: JSONFoldingLayoutManager?
        weak var rulerView: JSONLineNumberRulerView?
        private var isApplyingHighlighting = false
        var isProgrammaticUpdate = false
        var latestAnalysis: SyntaxAnalysisResult?
        var highlightsVisibleRangeOnly: Bool
        var highlightedRange: NSRange?
        var lastRevealDiagnosticGeneration = 0
        nonisolated(unsafe) private var viewportObserver: NSObjectProtocol?

        init(
            text: Binding<String>,
            foldedRanges: Binding<[NSRange]>,
            highlightsVisibleRangeOnly: Bool = false
        ) {
            self.text = text
            self.foldedRanges = foldedRanges
            self.highlightsVisibleRangeOnly = highlightsVisibleRangeOnly
        }

        deinit {
            if let viewportObserver {
                NotificationCenter.default.removeObserver(viewportObserver)
            }
        }

        @MainActor
        func observeViewport(of scrollView: NSScrollView) {
            if let viewportObserver {
                NotificationCenter.default.removeObserver(viewportObserver)
            }
            scrollView.contentView.postsBoundsChangedNotifications = true
            viewportObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard
                        let self,
                        self.highlightsVisibleRangeOnly,
                        let textView = self.textView
                    else { return }
                    self.applyHighlighting(to: textView, using: self.latestAnalysis)
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? JSONCodeTextView else {
                return
            }

            guard !isProgrammaticUpdate else {
                return
            }

            let textVal = textView.string
            let analysis = SyntaxAnalysisResult.analyze(textVal)
            latestAnalysis = analysis
            highlightedRange = highlightedRange.flatMap { range in
                let length = (textVal as NSString).length
                guard range.location <= length else { return nil }
                return NSRange(location: range.location, length: min(range.length, length - range.location))
            }

            applyDiagnostic(nil, to: textView)
            rulerView?.invalidateFoldCache()
            text.wrappedValue = textVal
            foldedRanges.wrappedValue = validFoldedRanges(in: textVal)
            applyHighlighting(to: textView, using: analysis)
            rulerView?.needsDisplay = true
        }

        @MainActor
        func toggleFold(atZeroBasedLine lineNumber: Int) {
            guard let textView else { return }
            let analysis = latestAnalysis ?? SyntaxAnalysisResult.analyze(textView.string)
            let lineMap = analysis.lineMap
            guard let foldRange = analysis.foldRanges.first(where: {
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
            applyDiagnostic(currentDiagnostic, to: textView)
        }

        func validFoldedRanges(in string: String) -> [NSRange] {
            let length = (string as NSString).length
            return foldedRanges.wrappedValue.filter { range in
                range.location >= 0 && range.length > 0 && NSMaxRange(range) <= length
            }
        }

        private var currentDiagnostic: JSONDiagnostic?

        @MainActor
        func applyDiagnostic(_ diagnostic: JSONDiagnostic?, to textView: JSONCodeTextView) {
            currentDiagnostic = diagnostic
            guard
                let diagnostic,
                let range = diagnostic.range,
                range.location <= (textView.string as NSString).length
            else {
                textView.diagnosticLineRange = nil
                rulerView?.setDiagnostic(actualLineNumber: nil, markerLineNumber: nil)
                return
            }

            let analysis = latestAnalysis ?? SyntaxAnalysisResult.analyze(textView.string)
            latestAnalysis = analysis
            let lineMap = analysis.lineMap
            let actualLine = lineMap.lineNumber(at: range.location)
            let containingFolds = validFoldedRanges(in: textView.string).filter { foldRange in
                foldRange.location < range.location && NSMaxRange(foldRange) > range.location
            }

            if let visibleFold = containingFolds.min(by: { $0.location < $1.location }) {
                let markerLine = lineMap.lineNumber(at: visibleFold.location)
                textView.diagnosticLineRange = nil
                rulerView?.setDiagnostic(actualLineNumber: nil, markerLineNumber: markerLine)
            } else {
                textView.diagnosticLineRange = lineMap.lineRange(forZeroBasedLine: actualLine, in: textView.string)
                rulerView?.setDiagnostic(actualLineNumber: actualLine, markerLineNumber: actualLine)
            }
        }

        @MainActor
        func revealDiagnostic(_ diagnostic: JSONDiagnostic?, in textView: JSONCodeTextView) {
            guard let diagnostic, let range = diagnostic.range else { return }
            let textLength = (textView.string as NSString).length
            let location = min(max(0, range.location), textLength)
            foldedRanges.wrappedValue.removeAll { foldRange in
                foldRange.location < location && NSMaxRange(foldRange) > location
            }
            layoutManager?.foldedRanges = validFoldedRanges(in: textView.string)
            applyDiagnostic(diagnostic, to: textView)

            let lineMap = latestAnalysis?.lineMap ?? JSONLineMap(text: textView.string)
            let line = lineMap.lineNumber(at: location)
            let lineRange = lineMap.lineRange(forZeroBasedLine: line, in: textView.string)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.window?.makeFirstResponder(textView)
            textView.scrollRangeToVisible(lineRange)
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
        func applyHighlighting(
            to textView: NSTextView,
            using analysis: SyntaxAnalysisResult? = nil,
            visibleCharacterRange: NSRange? = nil
        ) {
            guard !isApplyingHighlighting else {
                return
            }

            isApplyingHighlighting = true
            defer { isApplyingHighlighting = false }

            autoreleasepool {
                let source = textView.string as NSString
                let fullRange = NSRange(location: 0, length: source.length)
                let targetRange = highlightingRange(
                    in: textView,
                    source: source,
                    requestedVisibleRange: visibleCharacterRange
                )
                let selectedRanges = textView.selectedRanges

                let storage = textView.textStorage
                storage?.beginEditing()
                if highlightsVisibleRangeOnly {
                    let previousRange = highlightedRange.flatMap { range -> NSRange? in
                        guard range.location <= source.length else { return nil }
                        return NSRange(
                            location: range.location,
                            length: min(range.length, source.length - range.location)
                        )
                    }
                    if let previousRange {
                        if previousRange.length > 0 {
                            storage?.setAttributes(baseAttributes, range: previousRange)
                        }
                        if targetRange != previousRange, targetRange.length > 0 {
                            storage?.setAttributes(baseAttributes, range: targetRange)
                        }
                    } else if fullRange.length > 0 {
                        storage?.setAttributes(baseAttributes, range: fullRange)
                    }
                } else if fullRange.length > 0 {
                    storage?.setAttributes(baseAttributes, range: fullRange)
                }

                let resolvedAnalysis = analysis ?? latestAnalysis ?? SyntaxAnalysisResult.analyze(textView.string)
                latestAnalysis = resolvedAnalysis

                let lexicalText: String
                let rangeOffset: Int
                if highlightsVisibleRangeOnly {
                    lexicalText = source.substring(with: targetRange)
                    rangeOffset = targetRange.location
                } else {
                    lexicalText = textView.string
                    rangeOffset = 0
                }

                JSONLexer.forEachToken(in: lexicalText) { token in
                    let absoluteRange = NSRange(
                        location: token.range.location + rangeOffset,
                        length: token.range.length
                    )
                    guard absoluteRange.location != NSNotFound, NSMaxRange(absoluteRange) <= source.length else {
                        return true
                    }
                    storage?.addAttributes(attributes(for: token.kind), range: absoluteRange)
                    return true
                }
                highlightedRange = highlightsVisibleRangeOnly ? targetRange : fullRange

                storage?.endEditing()
                let currentLength = (textView.string as NSString).length
                let safeRanges = selectedRanges.compactMap { value -> NSValue? in
                    let range = value.rangeValue
                    guard range.location <= currentLength else { return nil }
                    return NSValue(range: NSRange(location: range.location, length: min(range.length, currentLength - range.location)))
                }
                textView.selectedRanges = safeRanges.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : safeRanges
            }
        }

        @MainActor
        private func highlightingRange(
            in textView: NSTextView,
            source: NSString,
            requestedVisibleRange: NSRange?
        ) -> NSRange {
            let fullRange = NSRange(location: 0, length: source.length)
            guard highlightsVisibleRangeOnly, source.length > 0 else {
                return fullRange
            }

            let candidate = requestedVisibleRange ?? visibleCharacterRange(in: textView, sourceLength: source.length)
            let location = min(max(0, candidate.location), source.length)
            let length = min(max(0, candidate.length), source.length - location)
            let safeRange = NSRange(location: location, length: length)
            return source.lineRange(for: safeRange)
        }

        @MainActor
        private func visibleCharacterRange(in textView: NSTextView, sourceLength: Int) -> NSRange {
            guard
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer,
                !textView.visibleRect.isEmpty
            else {
                return NSRange(location: 0, length: min(sourceLength, 16_384))
            }

            let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
            guard glyphRange.length > 0 else {
                return NSRange(location: 0, length: min(sourceLength, 16_384))
            }
            return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
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

    @State private var validationResult = JSONValidationResult.valid
    @State private var validatedText: String?
    @State private var formattingError: String?
    @State private var revealDiagnosticGeneration = 0

    private enum TransformResult: Sendable {
        case transformed(String)
        case invalid(JSONValidationResult)
        case failed(String)
    }

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
                accessibilityIdentifier: accessibilityIdentifier,
                diagnostic: currentDiagnostic,
                revealDiagnosticGeneration: revealDiagnosticGeneration
            )
            .frame(minHeight: minHeight, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }

            if showsValidation {
                diagnosticRow
            }
        }
        .onChange(of: text) { _, _ in
            foldedRanges = []
            formattingError = nil
            validatedText = nil
        }
        .task(id: text) {
            guard showsValidation else { return }
            let source = text
            if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationResult = .valid
                validatedText = source
                return
            }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                let validationTask = Task.detached(priority: .userInitiated) {
                    JSONValidator.validate(source)
                }
                let result = await withTaskCancellationHandler {
                    await validationTask.value
                } onCancel: {
                    validationTask.cancel()
                }
                guard !Task.isCancelled, text == source else { return }
                validationResult = result
                validatedText = source
            } catch {
                // Task was cancelled
            }
        }
    }

    private var validationBadge: some View {
        Label(validationResult.isValid ? "Valid JSON" : "Invalid JSON", systemImage: validationResult.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(validationResult.isValid ? Color.green : Color.orange)
            .help(badgeHelp)
            .accessibilityIdentifier("\(accessibilityIdentifier)-validation-badge")
    }

    @ViewBuilder
    private var diagnosticRow: some View {
        Group {
            if let diagnostic = currentDiagnostic {
                if diagnostic.range != nil {
                    Button {
                        revealDiagnosticGeneration &+= 1
                    } label: {
                        diagnosticLabel(diagnostic.displayMessage)
                    }
                    .buttonStyle(.plain)
                    .help(diagnostic.displayMessage)
                    .accessibilityLabel(diagnostic.displayMessage)
                    .accessibilityHint("Show the JSON error in the request body editor")
                    .accessibilityIdentifier("\(accessibilityIdentifier)-diagnostic")
                } else {
                    diagnosticLabel(diagnostic.displayMessage)
                        .help(diagnostic.displayMessage)
                        .accessibilityLabel(diagnostic.displayMessage)
                        .accessibilityIdentifier("\(accessibilityIdentifier)-diagnostic")
                }
            } else if let formattingError {
                diagnosticLabel(formattingError)
                    .help(formattingError)
                    .accessibilityLabel(formattingError)
                    .accessibilityIdentifier("\(accessibilityIdentifier)-diagnostic")
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 16, alignment: .leading)
    }

    private func diagnosticLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(Color.orange)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var currentDiagnostic: JSONDiagnostic? {
        guard validatedText == text else { return nil }
        return validationResult.diagnostic
    }

    private var badgeHelp: String {
        guard validatedText == text else {
            return validationResult.isValid ? "JSON is valid" : "JSON is invalid"
        }
        return validationResult.errorMessage ?? "JSON is valid"
    }

    private var borderColor: Color {
        validationResult.isValid ? Color(nsColor: .separatorColor).opacity(0.7) : .orange.opacity(0.8)
    }

    private func collapseAll() {
        foldedRanges = JSONFoldIndex.foldRanges(in: text)
            .filter { $0.depth > 0 }
            .map(\.fullRange)
    }

    private func expandAll() {
        foldedRanges = []
    }

    private func format() {
        transform { text in
            try JSONFormatter.format(text)
        }
    }

    private func compact() {
        transform(using: JSONFormatter.compact)
    }

    private func transform(using operation: @escaping @Sendable (String) throws -> String) {
        let currentText = text
        Task {
            let transformTask = Task.detached(priority: .userInitiated) { () -> TransformResult in
                do {
                    return .transformed(try operation(currentText))
                } catch let error as JSONFormattingError {
                    return .invalid(error.validationResult)
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            let result = await withTaskCancellationHandler {
                await transformTask.value
            } onCancel: {
                transformTask.cancel()
            }
            guard !Task.isCancelled, text == currentText else { return }

            switch result {
            case .transformed(let transformed):
                text = transformed
                formattingError = nil
            case .invalid(let validation):
                validationResult = validation
                validatedText = currentText
                formattingError = nil
                if validation.diagnostic?.range != nil {
                    revealDiagnosticGeneration &+= 1
                }
            case .failed(let message):
                formattingError = message
            }
        }
    }
}
