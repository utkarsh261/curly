import AppKit
import XCTest
@testable import NativeCurlRunner

final class JSONTextKitFoldingSpikeTests: XCTestCase {
    func testFoldedRangeHidesGlyphsWithoutMutatingSourceText() {
        let source = """
        {
          "user": {
            "name": "utk"
          }
        }
        """
        let storage = NSTextStorage(string: source)
        let layoutManager = JSONFoldingLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))

        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let userObjectRange = (source as NSString).range(of: """
        {
            "name": "utk"
          }
        """)
        XCTAssertNotEqual(userObjectRange.location, NSNotFound)

        layoutManager.foldedRanges = [userObjectRange]
        layoutManager.ensureLayout(for: textContainer)

        let hiddenCharacterLocation = userObjectRange.location + 1
        let visibleOpenBraceLocation = userObjectRange.location
        let hiddenGlyphIndex = layoutManager.glyphIndexForCharacter(at: hiddenCharacterLocation)
        let openBraceGlyphIndex = layoutManager.glyphIndexForCharacter(at: visibleOpenBraceLocation)

        XCTAssertTrue(layoutManager.isHiddenFoldCharacter(at: hiddenCharacterLocation))
        XCTAssertEqual(layoutManager.propertyForGlyph(at: hiddenGlyphIndex), .null)
        XCTAssertNotEqual(layoutManager.propertyForGlyph(at: openBraceGlyphIndex), .null)
        XCTAssertEqual(storage.string, source)
    }

    @MainActor
    func testRulerViewCachesFoldStartLinesAndInvalidatesCacheCorrectly() {
        let source = """
        {
          "user": {
            "name": "utk"
          }
        }
        """
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let textStorage = NSTextStorage(string: source)
        let layoutManager = JSONFoldingLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: textContainer)
        scrollView.documentView = textView
        
        let ruler = JSONLineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        
        // Initially, the cache must be nil
        XCTAssertNil(ruler.cachedFoldStartLines)
        XCTAssertNil(ruler.cachedLineMap)
        
        // We push a graphics context to allow safe drawing without crashing
        let image = NSImage(size: NSSize(width: 52, height: 400))
        image.lockFocus()
        ruler.drawHashMarksAndLabels(in: NSRect(x: 0, y: 0, width: 52, height: 400))
        image.unlockFocus()
        
        // Now, cache should be populated
        XCTAssertNotNil(ruler.cachedFoldStartLines)
        XCTAssertNotNil(ruler.cachedLineMap)
        
        // Line 0 ({) and Line 1 ("user": {) should be in the fold start lines
        XCTAssertEqual(ruler.cachedFoldStartLines, Set([0, 1]))
        
        // Invalidation should reset it back to nil
        ruler.invalidateFoldCache()
        XCTAssertNil(ruler.cachedFoldStartLines)
        XCTAssertNil(ruler.cachedLineMap)
    }
}
