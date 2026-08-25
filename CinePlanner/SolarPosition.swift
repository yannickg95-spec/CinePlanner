//
//  SolarPosition.swift
//  CinePlanner
//
//  Where the sun sits in the sky for a place, date, and time — used to draw the
//  scene map's sun-direction overlay. Pure math (USNO low-precision solar
//  coordinates, good to well under a degree), no dependencies.
//

import Foundation

enum SolarPosition {
    /// Sun altitude and azimuth for an instant and location.
    /// - Returns: `altitude` in degrees above the horizon (negative = below), and
    ///   `azimuth` in degrees from North, clockwise (N=0, E=90, S=180, W=270).
    static func altAzimuth(date: Date, latitude: Double, longitude: Double) -> (altitude: Double, azimuth: Double) {
        let rad = Double.pi / 180
        let jd = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        let d = jd - 2451545.0                                   // days since J2000 (UT)
        let g = (357.529 + 0.98560028 * d).truncatingRemainder(dividingBy: 360)  // mean anomaly
        let q = (280.459 + 0.98564736 * d).truncatingRemainder(dividingBy: 360)  // mean longitude
        let L = (q + 1.915 * sin(g*rad) + 0.020 * sin(2*g*rad))                  // ecliptic longitude
            .truncatingRemainder(dividingBy: 360)
        let e = 23.439 - 0.00000036 * d                          // obliquity
        let ra = atan2(cos(e*rad)*sin(L*rad), cos(L*rad)) / rad  // right ascension
        let dec = asin(sin(e*rad)*sin(L*rad)) / rad              // declination
        let gmst = (280.46061837 + 360.98564736629 * d).truncatingRemainder(dividingBy: 360)
        let lst = (gmst + longitude).truncatingRemainder(dividingBy: 360)
        var ha = lst - ra                                        // hour angle
        ha = (ha + 540).truncatingRemainder(dividingBy: 360) - 180
        let latR = latitude*rad, decR = dec*rad, haR = ha*rad
        let alt = asin(sin(latR)*sin(decR) + cos(latR)*cos(decR)*cos(haR)) / rad
        var az = atan2(-sin(haR), tan(decR)*cos(latR) - sin(latR)*cos(haR)) / rad
        az = (az + 360).truncatingRemainder(dividingBy: 360)
        return (alt, az)
    }

    /// Sunrise and sunset for the day, as minutes since local midnight in
    /// `timeZone`. Found by scanning the day for the sun crossing the standard
    /// −0.833° horizon (refraction + solar radius). Nil on a polar day/night where
    /// there's no crossing.
    static func sunriseSunset(date: Date, latitude: Double, longitude: Double,
                              timeZone: TimeZone) -> (sunrise: Int, sunset: Int)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let startOfDay = cal.startOfDay(for: date)
        let horizon = -0.833
        var previous = altAzimuth(date: startOfDay, latitude: latitude, longitude: longitude).altitude
        var sunrise: Int?
        var sunset: Int?
        for minute in 1...1440 {
            let alt = altAzimuth(date: startOfDay.addingTimeInterval(Double(minute) * 60),
                                 latitude: latitude, longitude: longitude).altitude
            if sunrise == nil, previous < horizon, alt >= horizon { sunrise = minute }
            if previous >= horizon, alt < horizon { sunset = minute }
            previous = alt
        }
        guard let sr = sunrise, let ss = sunset else { return nil }
        return (sr, ss)
    }

    /// Daylight landmarks for a day, as minutes since local midnight in `timeZone`:
    /// sunrise/sunset (−0.833° horizon) plus the golden-hour edges (sun at +6°) — the
    /// morning golden hour runs sunrise→goldenMorningEnd, the evening one
    /// goldenEveningStart→sunset. Nil where the sun never rises/sets that day.
    struct DayLight {
        let sunrise: Int, sunset: Int
        let goldenMorningEnd: Int, goldenEveningStart: Int
    }

    static func dayLight(date: Date, latitude: Double, longitude: Double,
                         timeZone: TimeZone) -> DayLight? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let startOfDay = cal.startOfDay(for: date)
        let horizon = -0.833, golden = 6.0
        func alt(_ minute: Int) -> Double {
            altAzimuth(date: startOfDay.addingTimeInterval(Double(minute) * 60),
                       latitude: latitude, longitude: longitude).altitude
        }
        var previous = alt(0)
        var sunrise: Int?, sunset: Int?, gMorn: Int?, gEve: Int?
        for minute in 1...1440 {
            let a = alt(minute)
            if sunrise == nil, previous < horizon, a >= horizon { sunrise = minute }
            if previous >= horizon, a < horizon { sunset = minute }
            if gMorn == nil, previous < golden, a >= golden { gMorn = minute }
            if previous >= golden, a < golden { gEve = minute }
            previous = a
        }
        guard let sr = sunrise, let ss = sunset else { return nil }
        return DayLight(sunrise: sr, sunset: ss,
                        goldenMorningEnd: gMorn ?? sr, goldenEveningStart: gEve ?? ss)
    }
}

/// Per-scene settings for the sun-direction overlay, stored as JSON on the scene.
struct SunSettings: Codable, Equatable {
    var enabled: Bool = false
    var address: String = ""
    var latitude: Double? = nil
    var longitude: Double? = nil
    var timeZoneID: String? = nil
    var dateEpoch: Double? = nil        // any instant on the chosen calendar day
    var northOffsetDeg: Double = 0      // screen angle (from up, clockwise) that points North
    var timeMinutes: Double = 720       // minutes since local midnight (default noon)

    var hasLocation: Bool { latitude != nil && longitude != nil }
    var timeZone: TimeZone { timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current }
    var date: Date { dateEpoch.map { Date(timeIntervalSince1970: $0) } ?? Date() }

    /// The absolute instant for the chosen date at the chosen time-of-day, read in
    /// the location's timezone.
    var instant: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let startOfDay = cal.startOfDay(for: date)
        return startOfDay.addingTimeInterval(timeMinutes * 60)
    }
}
