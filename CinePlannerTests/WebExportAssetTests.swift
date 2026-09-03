//
//  WebExportAssetTests.swift
//  CinePlannerTests
//
//  The published page's stylesheet and script are bundled resources rather than
//  inline strings. That is easier to read and edit, but it moves a guarantee out
//  of the compiler's hands: rename the file, or let it fall out of the target,
//  and the export silently produces a page with no styling or no behaviour.
//  These tests put that guarantee back.
//

import XCTest
@testable import CinePlanner

final class WebExportAssetTests: XCTestCase {

    private func asset(_ name: String, _ ext: String) throws -> String {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext),
                                "\(name).\(ext) is not in the app bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testStylesheetIsBundled() throws {
        let css = try asset("WebExport", "css")
        XCTAssertFalse(css.isEmpty)
        XCTAssertTrue(css.contains(":root"), "Expected the page's custom properties.")
    }

    func testScriptIsBundled() throws {
        let js = try asset("WebExport", "js")
        XCTAssertFalse(js.isEmpty)
        XCTAssertTrue(js.contains("CP_EPISODES"),
                      "The script reads the schedule the page injects; without that it is the wrong file.")
    }

    func testAssetsCarryNoSwiftInterpolation() throws {
        // They were lifted out of a Swift string literal. A stray \( would have
        // been interpolated there and is now meaningless — a sign of a bad edit.
        for (name, ext) in [("WebExport", "css"), ("WebExport", "js")] {
            XCTAssertFalse(try asset(name, ext).contains("\\("),
                           "\(name).\(ext) still contains Swift interpolation")
        }
    }

    func testStylesheetDoesNotCloseItsOwnStyleTag() throws {
        // Both are inlined into the page, so a closing tag inside them would end
        // the element early — the same class of bug as the schedule JSON.
        XCTAssertFalse(try asset("WebExport", "css").localizedCaseInsensitiveContains("</style"))
        XCTAssertFalse(try asset("WebExport", "js").localizedCaseInsensitiveContains("</script"))
    }
}
