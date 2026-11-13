import SwiftUI
import XCTest
@testable import notchi

final class NotchAlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ title: String, startsIn minutes: Double, lasting: Double = 30, allDay: Bool = false) -> CalendarEventItem {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEventItem(id: title, title: title, start: start, end: start.addingTimeInterval(lasting * 60),
                                 isAllDay: allDay, color: .orange, joinURL: nil)
    }

    func testImminentPicksTheEarliestEventInsideTheWindow() {
        let events = [event("Tarde", startsIn: 120), event("Daily", startsIn: 12), event("Antes", startsIn: 5)]
        XCTAssertEqual(CalendarEventsService.imminent(in: events, now: now)?.title, "Antes")
    }

    func testImminentIgnoresFarAndAllDayEvents() {
        let events = [event("Longe", startsIn: 60), event("Feriado", startsIn: 0, allDay: true)]
        XCTAssertNil(CalendarEventsService.imminent(in: events, now: now))
    }

    func testImminentKeepsAnEventForFiveMinutesAfterItStarts() {
        XCTAssertNotNil(CalendarEventsService.imminent(in: [event("Começou", startsIn: -4)], now: now))
        XCTAssertNil(CalendarEventsService.imminent(in: [event("Passou", startsIn: -6)], now: now))
    }

    func testJoinURLFindsMeetZoomAndTeamsLinks() {
        XCTAssertEqual(CalendarEventsService.joinURL(in: [nil, "Entre em https://meet.google.com/abc-defg-hij agora"])?.host,
                       "meet.google.com")
        XCTAssertEqual(CalendarEventsService.joinURL(in: ["https://us02web.zoom.us/j/123?pwd=x"])?.host, "us02web.zoom.us")
        XCTAssertNil(CalendarEventsService.joinURL(in: ["https://example.com/reuniao", nil]))
    }

    func testEventsOnDayIncludesEventsThatSpanMidnight() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(for: now)
        let overnight = CalendarEventItem(id: "n", title: "Plantão", start: day.addingTimeInterval(-3600),
                                          end: day.addingTimeInterval(3600), isAllDay: false, color: .red, joinURL: nil)
        XCTAssertEqual(CalendarEventsService.events(in: [overnight], on: day, calendar: calendar).count, 1)
        XCTAssertEqual(CalendarEventsService.events(in: [overnight], on: day.addingTimeInterval(86_400 * 2), calendar: calendar).count, 0)
    }

    func testLowDiskOnlyBelowTheThreshold() {
        let plenty = DiskUsage(total: 460_000_000_000, available: 66_000_000_000)
        let tight = DiskUsage(total: 460_000_000_000, available: 18_000_000_000)
        XCTAssertNil(SystemHealthService.lowDiskGB(plenty))
        XCTAssertEqual(SystemHealthService.lowDiskGB(tight), 18)
        XCTAssertNil(SystemHealthService.lowDiskGB(nil))
    }

    func testCPUUsageIsTheBusyShareOfTheTickDelta() {
        let old = (user: UInt32(100), system: UInt32(50), idle: UInt32(800), nice: UInt32(0))
        let new = (user: UInt32(200), system: UInt32(100), idle: UInt32(850), nice: UInt32(0))
        XCTAssertEqual(SystemHealthService.cpuUsage(from: old, to: new), 0.75, accuracy: 0.001)
        XCTAssertEqual(SystemHealthService.cpuUsage(from: old, to: old), 0)
    }

    func testAlertLabelsCountDownAndShowFreeSpace() {
        let start = now.addingTimeInterval(12 * 60 - 20)
        XCTAssertEqual(NotchAlert.event(title: "Daily", start: start).label(now: now), "12 min")
        XCTAssertEqual(NotchAlert.event(title: "Daily", start: now.addingTimeInterval(-30)).label(now: now), "agora")
        XCTAssertEqual(NotchAlert.lowDisk(freeGB: 18).label(now: now), "18 GB")
    }
}
