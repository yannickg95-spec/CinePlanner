//
//  PurchasesTests.swift
//  CinePlannerTests
//
//  Who gets the app free (bought it before 2.0) and how long a trial runs decide
//  whether a customer is let in or shown the paywall — and get it wrong and paying
//  customers lose access, or everyone gets the app for nothing.
//

import XCTest
@testable import CinePlanner

final class PurchasesTests: XCTestCase {

    // MARK: Grandfathering

    func testIOSBuildsBeforeTheFreeBuildCountAsBought() {
        XCTAssertTrue(Purchases.isPreFreeDownload(originalAppVersion: "1"))
        XCTAssertTrue(Purchases.isPreFreeDownload(originalAppVersion: "5"))
        XCTAssertFalse(Purchases.isPreFreeDownload(originalAppVersion: "6"))
        XCTAssertFalse(Purchases.isPreFreeDownload(originalAppVersion: "7"))
        XCTAssertFalse(Purchases.isPreFreeDownload(originalAppVersion: "12"))
    }

    func testMacVersionsBeforeTwoPointOhCountAsBought() {
        XCTAssertTrue(Purchases.isPreFreeDownload(originalAppVersion: "1.0"))
        XCTAssertTrue(Purchases.isPreFreeDownload(originalAppVersion: "1.5"))
        XCTAssertTrue(Purchases.isPreFreeDownload(originalAppVersion: "1.6"))
        XCTAssertFalse(Purchases.isPreFreeDownload(originalAppVersion: "2.0"))
        XCTAssertFalse(Purchases.isPreFreeDownload(originalAppVersion: "2.0.1"))
        XCTAssertFalse(Purchases.isPreFreeDownload(originalAppVersion: "10.0"))
    }

    func testDottedVersionsCompareNumerically() {
        XCTAssertTrue(Purchases.isVersion("1.9", olderThan: "1.10"))
        XCTAssertFalse(Purchases.isVersion("1.10", olderThan: "1.9"))
        XCTAssertFalse(Purchases.isVersion("2.0", olderThan: "2"))   // trailing zeros are equal
        XCTAssertFalse(Purchases.isVersion("2.0", olderThan: "2.0"))
    }

    // MARK: Trial clock

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    func testAFreshTrialHasSevenDays() {
        let s = TrialClock.status(start: start, now: start.addingTimeInterval(60))
        XCTAssertTrue(s.isActive)
        XCTAssertEqual(s.daysRemaining, 7)
    }

    func testDaysLeftRoundUpSoTheLastDayReadsOne() {
        let midway = TrialClock.status(start: start, now: start.addingTimeInterval(3.5 * day))
        XCTAssertEqual(midway.daysRemaining, 4)
        let lastHour = TrialClock.status(start: start, now: start.addingTimeInterval(7 * day - 3600))
        XCTAssertTrue(lastHour.isActive)
        XCTAssertEqual(lastHour.daysRemaining, 1)
    }

    func testTheTrialEndsAfterSevenDays() {
        let end = TrialClock.status(start: start, now: start.addingTimeInterval(7 * day))
        XCTAssertFalse(end.isActive)
        XCTAssertEqual(end.daysRemaining, 0)
        XCTAssertFalse(TrialClock.status(start: start, now: start.addingTimeInterval(30 * day)).isActive)
    }
}
