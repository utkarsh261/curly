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
}
