import AppKit

final class JSONFoldingLayoutManager: NSLayoutManager {
    var foldedRanges: [NSRange] = [] {
        didSet {
            guard let textStorage else { return }
            invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: textStorage.length), changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length), actualCharacterRange: nil)
        }
    }

    override func setGlyphs(
        _ glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) {
        var mutableProperties: [NSLayoutManager.GlyphProperty] = []
        mutableProperties.reserveCapacity(glyphRange.length)

        for offset in 0..<glyphRange.length {
            let characterIndex = charIndexes[offset]
            if isHiddenFoldCharacter(at: characterIndex) {
                mutableProperties.append(.null)
            } else {
                mutableProperties.append(props[offset])
            }
        }

        mutableProperties.withUnsafeBufferPointer { propertyBuffer in
            super.setGlyphs(
                glyphs,
                properties: propertyBuffer.baseAddress!,
                characterIndexes: charIndexes,
                font: aFont,
                forGlyphRange: glyphRange
            )
        }
    }

    func isHiddenFoldCharacter(at characterIndex: Int) -> Bool {
        foldedRanges.contains { range in
            guard range.length > 2 else { return false }
            let hiddenRange = NSRange(location: range.location + 1, length: range.length - 2)
            return NSLocationInRange(characterIndex, hiddenRange)
        }
    }
}

final class JSONLineNumberRulerView: NSRulerView {
    var onToggleFold: ((Int) -> Void)?

    private weak var observedTextView: NSTextView?
    private let numberAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor
    ]
    private let foldAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 16, weight: .bold),
        .foregroundColor: NSColor.labelColor
    ]

    init(textView: NSTextView) {
        self.observedTextView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 52
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard
            let textView = observedTextView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else {
            return
        }

        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let text = textView.string
        let lineMap = JSONLineMap(text: text)
        let foldStartLines = Set(JSONFoldIndex.foldRanges(in: text).map { lineMap.lineNumber(at: $0.openTokenRange.location) })
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)

        var glyphIndex = glyphRange.location
        var drawnLines = Set<Int>()

        while glyphIndex < NSMaxRange(glyphRange) {
            var lineGlyphRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange)
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineNumber = lineMap.lineNumber(at: characterIndex)

            if !drawnLines.contains(lineNumber) {
                drawnLines.insert(lineNumber)
                let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY + 1
                drawLineNumber(lineNumber + 1, y: y)
                if foldStartLines.contains(lineNumber) {
                    drawFoldMarker(y: y)
                }
            }

            glyphIndex = max(NSMaxRange(lineGlyphRange), glyphIndex + 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard
            let textView = observedTextView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard point.x <= 16 else {
            return
        }

        let visibleRect = textView.visibleRect
        let textPoint = NSPoint(
            x: textView.textContainerOrigin.x + 1,
            y: point.y + visibleRect.minY - textView.textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: textPoint, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let lineNumber = JSONLineMap(text: textView.string).lineNumber(at: characterIndex)
        onToggleFold?(lineNumber)
    }

    private func drawLineNumber(_ lineNumber: Int, y: CGFloat) {
        let text = "\(lineNumber)" as NSString
        let size = text.size(withAttributes: numberAttributes)
        text.draw(
            at: NSPoint(x: ruleThickness - size.width - 7, y: y),
            withAttributes: numberAttributes
        )
    }

    private func drawFoldMarker(y: CGFloat) {
        ("▾" as NSString).draw(at: NSPoint(x: 7, y: y), withAttributes: foldAttributes)
    }
}
