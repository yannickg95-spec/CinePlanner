//
//  ScheduleSunSyncTests.swift
//  CinePlannerTests
//
//  Scheduling a scene on a dated day carries that date into the scene's sun seeker
//  so the scene-map daylight matches the shoot day. The rule: adopt only when the
//  scene sits on exactly one dated day (noon, in the scene's timezone). No dated
//  day means nothing to adopt; several means no single date to pick, so the
//  per-strip warning guides the choice instead of a silent overwrite.
//

import XCTest
@testable import CinePlanner

final class ScheduleSunSyncTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func day(_ iso: String) -> Date {
        let f = DateFormatter(); f.timeZone = utc; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    func testNoDatedDayAdoptsNothing() {
        XCTAssertNil(ScheduleSummary.adoptedSunDateEpoch(datedShootDates: [], timeZone: utc))
    }

    func testOneDatedDayAdoptsThatDayAtNoon() {
        let epoch = ScheduleSummary.adoptedSunDateEpoch(datedShootDates: [day("2027-01-05")],
                                                        timeZone: utc)
        XCTAssertNotNil(epoch)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let adopted = Date(timeIntervalSince1970: epoch!)
        // Same calendar day as the shoot date…
        XCTAssertTrue(cal.isDate(adopted, inSameDayAs: day("2027-01-05")))
        // …and pinned to noon so it can't drift across a day boundary in any zone.
        XCTAssertEqual(cal.component(.hour, from: adopted), 12)
    }

    func testSplitAcrossDaysAdoptsNothing() {
        let epoch = ScheduleSummary.adoptedSunDateEpoch(
            datedShootDates: [day("2027-01-05"), day("2027-01-06")], timeZone: utc)
        XCTAssertNil(epoch, "a scene split across dated days has no single date to adopt")
    }
}
