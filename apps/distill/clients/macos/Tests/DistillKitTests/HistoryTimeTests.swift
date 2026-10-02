import XCTest
@testable import DistillKit

final class HistoryTimeTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let us = Locale(identifier: "en_US")

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testTodayYesterdayAndOlder() {
        let now = date(2026, 10, 2, 15, 0)
        func phrase(_ d: Date) -> String {
            HistoryTime.phrase(d, now: now, calendar: calendar, locale: us).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(phrase(date(2026, 10, 2, 3, 4)), "today at 3:04 AM")
        XCTAssertEqual(phrase(date(2026, 10, 1, 21, 12)), "yesterday at 9:12 PM")
        XCTAssertEqual(phrase(date(2026, 9, 30, 16, 10)), "Sep 30 at 4:10 PM")
        XCTAssertEqual(phrase(date(2025, 9, 30, 16, 10)), "Sep 30, 2025 at 4:10 PM")
    }

    func testFollows24HourLocale() {
        let now = date(2026, 10, 2, 15, 0)
        let s = HistoryTime.phrase(date(2026, 10, 2, 16, 10), now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(s, "today at 16:10")
    }
}
