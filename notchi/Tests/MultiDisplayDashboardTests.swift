import XCTest
import CoreGraphics
@testable import notchi

@MainActor final class MultiDisplayDashboardTests: XCTestCase {
    let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testPrimaryAndVerticalDisplaysAreCentered() {
        XCTAssertEqual(DashboardAnchor.resolve(screen: primary, primary: primary), .topCenter)
        XCTAssertEqual(DashboardAnchor.resolve(screen: CGRect(x: -200, y: 900, width: 1920, height: 1080), primary: primary), .topCenter)
        XCTAssertEqual(DashboardAnchor.resolve(screen: CGRect(x: 0, y: -1080, width: 1920, height: 1080), primary: primary), .topCenter)
    }
    func testSideDisplaysUseLiteralSideEdgesDespiteDifferentSizesAndOffsets() {
        XCTAssertEqual(DashboardAnchor.resolve(screen: CGRect(x: 1440, y: -200, width: 2560, height: 1440), primary: primary), .right)
        XCTAssertEqual(DashboardAnchor.resolve(screen: CGRect(x: -1920, y: 200, width: 1920, height: 1080), primary: primary), .left)
    }
    func testChangingThePrimaryDisplayRecomputesDirection() {
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(DashboardAnchor.resolve(screen: primary, primary: external), .left)
        XCTAssertEqual(DashboardAnchor.resolve(screen: external, primary: external), .topCenter)
    }
    func testAllShapesAndWindowsStayOnTheirOwnScreen() {
        for frame in [CGRect(x: -1600, y: 400, width: 1600, height: 900),
                      CGRect(x: 1440, y: -900, width: 800, height: 600),
                      CGRect(x: -200, y: 900, width: 1920, height: 1080)] {
            let anchor = DashboardAnchor.resolve(screen: frame, primary: primary)
            let layout = DashboardLayout(screenFrame: frame, visibleFrame: frame.insetBy(dx: 0, dy: 30),
                                         notchSize: CGSize(width: 224, height: 24), hasNotch: false, anchor: anchor)
            XCTAssertTrue(frame.contains(layout.windowFrame))
            for size in [layout.collapsedSize, layout.expandedSize(for: .overview), layout.expandedSize(for: .residential)] {
                let shape = layout.contentFrame(size: size)
                XCTAssertTrue(frame.contains(shape))
                XCTAssertTrue(layout.windowFrame.contains(shape))
                switch anchor {
                case .left:
                    XCTAssertEqual(shape.minX, frame.minX)
                    XCTAssertEqual(shape.midY, frame.midY)
                case .right:
                    XCTAssertEqual(shape.maxX, frame.maxX)
                    XCTAssertEqual(shape.midY, frame.midY)
                case .topCenter:
                    XCTAssertEqual(shape.midX, frame.midX)
                    XCTAssertEqual(shape.maxY, frame.maxY)
                }
            }
        }
    }
    func testDisplayStatesShareContentAndServicesButKeepPresentationIndependent() {
        let a = NotchState()
        let b = NotchState(airController: a.airController, tvController: a.tvController, content: a.content, home: a.home)
        a.track = "Faixa de teste"
        XCTAssertEqual(b.track, a.track)
        b.playing = true
        XCTAssertTrue(a.playing)
        a.expanded = true
        XCTAssertFalse(b.expanded)
        b.dashboardMode = .residential
        XCTAssertEqual(a.dashboardMode, .overview)
        XCTAssertTrue(a.home === b.home)
        XCTAssertTrue(a.airController === b.airController)
        XCTAssertTrue(a.tvController === b.tvController)
        a.layout = DashboardLayout(screenFrame: primary, visibleFrame: primary, notchSize: CGSize(width: 188, height: 32))
        XCTAssertNotEqual(a.layout, b.layout)
    }
    func testDrawerMatchesReferenceDimensionsAndReservesEveryTab() {
        for anchor in [DashboardAnchor.left, .right] {
            for height in [1080.0, 1440.0] {
                let frame = CGRect(x: -1920, y: 100, width: 1920, height: height)
                let layout = DashboardLayout(screenFrame: frame, visibleFrame: frame, notchSize: CGSize(width: 224, height: 24), hasNotch: false, anchor: anchor)
                XCTAssertEqual(layout.collapsedSize, CGSize(width: 28, height: 104))
                XCTAssertEqual(layout.width(for: .overview), 408)
                XCTAssertEqual(layout.width(for: .residential), 408)
                XCTAssertEqual(layout.expandedSize(for: .residential).height, height >= 1400 ? 700 : 640)
                for page in 0...6 {
                    let size = layout.expandedSize(for: .overview, page: page)
                    XCTAssertTrue(layout.windowFrame.contains(layout.contentFrame(size: size)))
                    XCTAssertEqual(layout.carouselHeight(for: page), size.height - 52)
                }
            }
        }
    }
    func testLegacySideStripCanBeSelectedWithoutChangingTheNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let strip = DashboardLayout(screenFrame: frame, visibleFrame: frame, notchSize: CGSize(width: 224, height: 24), hasNotch: false, anchor: .left, sideDrawer: false)
        XCTAssertFalse(strip.isExternal)
        XCTAssertEqual(strip.width(for: .overview), 740)
        XCTAssertEqual(strip.collapsedSize.height, 80)
        let main = DashboardLayout(screenFrame: frame, visibleFrame: frame, notchSize: CGSize(width: 188, height: 32))
        XCTAssertEqual(main.composition, .notch)
        XCTAssertEqual(main.expandedSize(for: .overview, page: 0).height, 220)
    }
    func testTopExternalPanelHasSeparateNavigationAndHeader() {
        let frame = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let layout = DashboardLayout(screenFrame: frame, visibleFrame: frame, notchSize: CGSize(width: 224, height: 24), hasNotch: false)
        XCTAssertEqual(layout.composition, .top)
        XCTAssertEqual(layout.width(for: .overview), 760)
        XCTAssertEqual(layout.headerHeight(for: .overview), 92)
        XCTAssertEqual(layout.expandedSize(for: .overview, page: 0).height, 300)
        XCTAssertEqual(layout.contentFrame(size: layout.expandedSize(for: .residential)).maxY, frame.maxY)
    }

}
