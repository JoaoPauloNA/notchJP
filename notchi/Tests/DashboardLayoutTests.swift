import Combine
import CoreGraphics
import XCTest
@testable import notchi

@MainActor
final class DashboardLayoutTests: XCTestCase {
    func testResolutionChangePublishesNewGeometryAndKeepsCompactHeader() {
        let state = NotchState()
        let highResolution = layout(width: 1800, height: 1169, notchWidth: 188, notchHeight: 32)
        let scaledResolution = layout(width: 1024, height: 665, notchWidth: 340, notchHeight: 54)
        state.layout = highResolution
        var updates = 0
        let observation = state.objectWillChange.sink { updates += 1 }

        state.layout = scaledResolution

        XCTAssertEqual(updates, 1)
        XCTAssertFalse(highResolution.headerBelowNotch(for: .overview))
        XCTAssertFalse(state.layout.headerBelowNotch(for: .overview))
        XCTAssertEqual(state.layout.headerHeight(for: .overview), state.collapsedSize.height)
        XCTAssertGreaterThanOrEqual(state.activeExpandedSize.width - state.collapsedSize.width, 272)
        XCTAssertEqual(state.collapsedSize.height, 58)
        XCTAssertEqual(state.activeExpandedSize.height, scaledResolution.expandedSize(for: .overview, page: state.page).height)
        XCTAssertNotEqual(highResolution.windowFrame, state.layout.windowFrame)
        withExtendedLifetime(observation) {}
    }

    func testPanelStaysInsideDisplayAtDifferentScalesAndScreenOrigins() {
        for (width, height, notchWidth, notchHeight) in [
            (2560.0, 1664.0, 188.0, 32.0), (1440, 900, 220, 36),
            (1024, 665, 340, 54), (800, 500, 380, 64)
        ] {
            for origin in [CGPoint.zero, CGPoint(x: -1440, y: 300), CGPoint(x: 2560, y: -900)] {
                let screen = CGRect(origin: origin, size: CGSize(width: width, height: height))
                let visible = CGRect(x: screen.minX, y: screen.minY + 60, width: width, height: height - 90)
                let geometry = DashboardLayout(screenFrame: screen, visibleFrame: visible,
                                               notchSize: CGSize(width: notchWidth, height: notchHeight))
                XCTAssertTrue(screen.contains(geometry.windowFrame))
                XCTAssertEqual(geometry.windowFrame.midX, screen.midX)
                XCTAssertEqual(geometry.windowFrame.maxY, screen.maxY)
                XCTAssertGreaterThanOrEqual(geometry.windowFrame.minY, visible.minY)
                for mode in [NotchDashboardMode.overview, .residential] {
                    XCTAssertLessThanOrEqual(geometry.expandedSize(for: mode).width, width - 40)
                    XCTAssertLessThanOrEqual(geometry.expandedSize(for: mode).height, geometry.windowFrame.height)
                }
                for page in 0...2 {
                    XCTAssertGreaterThan(geometry.carouselHeight(for: page), 0)
                    XCTAssertLessThanOrEqual(geometry.expandedSize(for: .overview, page: page).height, geometry.windowFrame.height)
                }
            }
        }
    }

    func testCompactViewportShrinksWhenVerticalSpaceIsLimited() {
        let normal = layout(width: 1440, height: 900, notchWidth: 188, notchHeight: 32)
        let short = layout(width: 800, height: 400, notchWidth: 340, notchHeight: 54)
        XCTAssertEqual(normal.carouselHeight(for: 1), 290)
        XCTAssertEqual(normal.expandedSize(for: .overview).height, 357)
        XCTAssertLessThan(normal.expandedSize(for: .overview, page: 0).height, normal.expandedSize(for: .overview, page: 1).height)
        XCTAssertEqual(normal.expandedSize(for: .overview, page: 0).height, 220)
        XCTAssertLessThan(short.carouselHeight(for: 1), normal.carouselHeight(for: 1))
        XCTAssertEqual(short.expandedSize(for: .overview).height,
                       short.headerHeight(for: .overview) + short.carouselHeight(for: 1) + 31)
    }

    func testExternalScreenDoesNotReserveSpaceForCamera() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let geometry = DashboardLayout(screenFrame: frame, visibleFrame: frame,
                                       notchSize: CGSize(width: 224, height: 24), hasNotch: false)
        XCTAssertFalse(geometry.headerBelowNotch(for: .overview))
        XCTAssertEqual(geometry.headerGap(for: .overview), 8)
        XCTAssertEqual(geometry.headerHeight(for: .overview), 92)
    }

    private func layout(width: CGFloat, height: CGFloat, notchWidth: CGFloat, notchHeight: CGFloat) -> DashboardLayout {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        return DashboardLayout(screenFrame: frame, visibleFrame: frame,
                               notchSize: CGSize(width: notchWidth, height: notchHeight))
    }
}
