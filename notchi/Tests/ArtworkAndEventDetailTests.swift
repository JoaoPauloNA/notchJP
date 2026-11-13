import AppKit
import SwiftUI
import XCTest
@testable import notchi

final class ArtworkAndEventDetailTests: XCTestCase {
    private func solidImage(_ color: NSColor, side: Int = 64) -> CGImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    func testDominantColourOfARedCoverIsAReadableRed() throws {
        let color = try XCTUnwrap(ArtworkPalette.dominantColor(in: solidImage(NSColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))))
        XCTAssertGreaterThan(color.red, 0.6)
        XCTAssertLessThan(color.green, 0.5)
        XCTAssertLessThan(color.blue, 0.5)
    }

    func testDarkColoursAreBrightenedSoTheyShowOnBlack() throws {
        let color = try XCTUnwrap(ArtworkPalette.dominantColor(in: solidImage(NSColor(red: 0.1, green: 0.05, blue: 0.4, alpha: 1))))
        XCTAssertGreaterThanOrEqual(max(color.red, color.green, color.blue), 0.59)
    }

    func testGreyCoverHasNoDominantColour() {
        XCTAssertNil(ArtworkPalette.dominantColor(in: solidImage(NSColor(white: 0.5, alpha: 1))))
    }

    func testMonochromeCoverUsesNeutralReadableReference() throws {
        let color = try XCTUnwrap(ArtworkPalette.referenceColor(in: solidImage(NSColor(white: 0.5, alpha: 1))))
        XCTAssertEqual(color.red, color.green, accuracy: 0.001)
        XCTAssertEqual(color.green, color.blue, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(color.red, 0.62)
    }

    func testColouredCoverKeepsItsOwnHue() throws {
        let color = try XCTUnwrap(ArtworkPalette.referenceColor(in: solidImage(NSColor(red: 0.05, green: 0.2, blue: 0.8, alpha: 1))))
        XCTAssertGreaterThan(color.blue, color.red)
        XCTAssertGreaterThan(color.blue, color.green)
    }

    func testTimeRangeForTimedAllDayAndMultiDayEvents() {
        let locale = Locale(identifier: "pt_BR")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9, minute: 30))!
        func event(end: Date, allDay: Bool = false) -> CalendarEventItem {
            CalendarEventItem(id: "e", title: "T", start: start, end: end, isAllDay: allDay, color: .orange, joinURL: nil)
        }
        let sameDay = event(end: start.addingTimeInterval(15 * 60)).timeRangeText(locale: locale, calendar: calendar)
        XCTAssertTrue(sameDay.contains("09:30") && sameDay.contains("09:45") && sameDay.contains("·"), sameDay)
        XCTAssertTrue(event(end: start.addingTimeInterval(86_400), allDay: true).timeRangeText(locale: locale, calendar: calendar).hasSuffix("Dia todo"))
        let multi = event(end: start.addingTimeInterval(2 * 86_400)).timeRangeText(locale: locale, calendar: calendar)
        XCTAssertTrue(multi.contains("–") && !multi.contains("·"), multi)
    }

    func testShortNotesTrimsEmptyAndLongText() {
        func item(_ notes: String?) -> CalendarEventItem {
            CalendarEventItem(id: "n", title: "T", start: Date(), end: Date(), isAllDay: false, color: .orange, joinURL: nil, notes: notes)
        }
        XCTAssertNil(item(nil).shortNotes)
        XCTAssertNil(item("  \n ").shortNotes)
        XCTAssertEqual(item(" Pauta ").shortNotes, "Pauta")
        XCTAssertEqual(item(String(repeating: "a", count: 400)).shortNotes?.count, 221)
    }
}
