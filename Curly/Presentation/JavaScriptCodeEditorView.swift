import AppKit
import SwiftUI

struct JavaScriptCodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.setAccessibilityIdentifier("\(accessibilityIdentifier)-scroll-view")

        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(
                width: scrollView.contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = JavaScriptTextView(frame: .zero, textContainer: textContainer)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.insertionPointColor = .controlAccentColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier(accessibilityIdentifier)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? JavaScriptTextView else { return }
        context.coordinator.text = $text

        if textView.string != text {
            let replacementLength = (text as NSString).length
            let selectedRanges = textView.selectedRanges.compactMap { value -> NSValue? in
                let range = value.rangeValue
                guard range.location <= replacementLength else { return nil }
                return NSValue(range: NSRange(
                    location: range.location,
                    length: min(range.length, replacementLength - range.location)
                ))
            }
            context.coordinator.isProgrammaticUpdate = true
            textView.string = text
            textView.selectedRanges = selectedRanges.isEmpty
                ? [NSValue(range: NSRange(location: replacementLength, length: 0))]
                : selectedRanges
            context.coordinator.isProgrammaticUpdate = false
        }

        textView.isEditable = isEditable
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var isProgrammaticUpdate = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

final class JavaScriptTextView: NSTextView {
    private static let identifierCharacters = CharacterSet.alphanumerics
        .union(.nonBaseCharacters)
        .union(CharacterSet(charactersIn: "_$"))

    override func selectionRange(
        forProposedRange proposedCharRange: NSRange,
        granularity: NSSelectionGranularity
    ) -> NSRange {
        guard granularity == .selectByWord,
              proposedCharRange.location != NSNotFound else {
            return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        }

        let source = string as NSString
        guard source.length > 0 else { return proposedCharRange }
        let location = min(proposedCharRange.location, source.length - 1)
        let clickedRange = source.rangeOfComposedCharacterSequence(at: location)
        guard isIdentifierRange(clickedRange, in: source) else {
            return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        }

        var lowerBound = clickedRange.location
        var upperBound = NSMaxRange(clickedRange)

        while lowerBound > 0 {
            let candidate = source.rangeOfComposedCharacterSequence(at: lowerBound - 1)
            guard isIdentifierRange(candidate, in: source) else { break }
            lowerBound = candidate.location
        }

        while upperBound < source.length {
            let candidate = source.rangeOfComposedCharacterSequence(at: upperBound)
            guard isIdentifierRange(candidate, in: source) else { break }
            upperBound = NSMaxRange(candidate)
        }

        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }

    private func isIdentifierRange(_ range: NSRange, in source: NSString) -> Bool {
        source.substring(with: range).unicodeScalars.allSatisfy {
            Self.identifierCharacters.contains($0)
        }
    }
}
