//
//  ScriptParseTests.swift
//  CinePlannerTests
//
//  Script import reads the PDF and parses it off the main actor (`parseScript`),
//  then creates the scenes on the main actor. These build small screenplay PDFs
//  and check the background half: headings, page mapping, and the outcome for a
//  PDF without readable text (which must still keep the PDF itself).
//

import XCTest
import CoreText
@testable import CinePlanner

final class ScriptParseTests: XCTestCase {

    /// A US-letter PDF with one page per entry, each page's lines set in Courier.
    private func makePDF(pages: [[String]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("script-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Courier" as CFString, 12, nil)
        for lines in pages {
            ctx.beginPDFPage(nil)
            var y: CGFloat = 720
            for line in lines {
                let text = NSAttributedString(string: line, attributes: [.init(kCTFontAttributeName as String): font])
                let ctLine = CTLineCreateWithAttributedString(text)
                ctx.textPosition = CGPoint(x: 108, y: y)
                CTLineDraw(ctLine, ctx)
                y -= 14
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testHeadingsAndPagesAreParsedOffTheMainActor() async throws {
        let url = try makePDF(pages: [
            ["1 INT. KITCHEN - DAY", "", "Anna fills the kettle.", "",
             "2 EXT. STREET - NIGHT", "", "Rain on the windows."],
            ["3 INT. CAR - DAY", "", "Bob drives."],
        ])
        // Run it the way the import does: detached from the main actor.
        let parsed = try await Task.detached { try ScriptImporter.parseScript(at: url) }.value

        XCTAssertFalse(parsed.textExtractionFailed)
        XCTAssertNotNil(parsed.pdfData)
        XCTAssertEqual(parsed.scenes.map(\.number), [1, 2, 3])
        XCTAssertEqual(parsed.scenes.map(\.isInterior), [true, false, true])
        XCTAssertEqual(parsed.scenes.map(\.isDay), [true, false, true])
        XCTAssertEqual(parsed.scenes.map(\.pageNumber), [0, 0, 1])
        XCTAssertEqual(parsed.sceneCharacters.count, parsed.scenes.count)
    }

    func testAPDFWithoutTextIsReportedButKept() async throws {
        let url = try makePDF(pages: [[]])
        let parsed = try await Task.detached { try ScriptImporter.parseScript(at: url) }.value
        XCTAssertTrue(parsed.textExtractionFailed)
        XCTAssertNotNil(parsed.pdfData, "the PDF is still stored, so it can be shown")
        XCTAssertTrue(parsed.scenes.isEmpty)
    }

    func testANonPDFIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-script-\(UUID().uuidString).pdf")
        try Data("plain text".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ScriptImporter.parseScript(at: url))
    }
}
