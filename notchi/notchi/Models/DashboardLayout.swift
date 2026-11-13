import CoreGraphics

/// AppKit coordinates increase upward. The primary display is NSScreen.screens.first, not the focused screen.
nonisolated enum DashboardAnchor: Equatable {
    case left, topCenter, right

    var isSide: Bool { self != .topCenter }

    static func resolve(screen: CGRect, primary: CGRect) -> Self {
        guard screen != primary else { return .topCenter }
        // A display above/below the primary uses the middle of its top edge.
        // For diagonal arrangements, the dominant normalized displacement wins.
        let dx = screen.midX - primary.midX
        let dy = screen.midY - primary.midY
        let horizontal = abs(dx) / max(1, (screen.width + primary.width) / 2)
        let vertical = abs(dy) / max(1, (screen.height + primary.height) / 2)
        guard horizontal >= vertical, abs(dx) > 1 else { return .topCenter }
        return dx < 0 ? .left : .right
    }
}

/// All dimensions use AppKit points, so changing display scaling also changes the layout.
struct DashboardLayout: Equatable {
    let screenFrame: CGRect
    let visibleFrame: CGRect
    let collapsedSize: CGSize
    let hasNotch: Bool
    let anchor: DashboardAnchor
    let sideDrawer: Bool
    var isExternal: Bool { !hasNotch && (!anchor.isSide || sideDrawer) }
    var composition: PanelComposition { !isExternal ? .notch : (anchor.isSide ? .side : .top) }
    private let availableWidth: CGFloat
    private let availableHeight: CGFloat

    init(screenFrame: CGRect, visibleFrame: CGRect, notchSize: CGSize, hasNotch: Bool = true, anchor: DashboardAnchor = .topCenter, sideDrawer: Bool = true) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.hasNotch = hasNotch
        self.anchor = anchor
        self.sideDrawer = sideDrawer
        availableWidth = max(0, screenFrame.width - 40)
        availableHeight = max(0, screenFrame.maxY - max(screenFrame.minY, visibleFrame.minY) - 40)
        collapsedSize = anchor.isSide
            ? CGSize(width: min(28, availableWidth), height: min(sideDrawer ? 104 : 80, availableHeight))
            : CGSize(width: min(max(0, notchSize.width + 12), availableWidth),
                     height: min(max(0, notchSize.height + 4), availableHeight))
    }

    func width(for mode: NotchDashboardMode) -> CGFloat {
        if anchor.isSide { return min(availableWidth, sideDrawer ? 408 : (mode == .overview ? 740 : 1080)) }
        if !hasNotch { return min(availableWidth, mode == .overview ? 760 : 1080) }
        let preferredWidth = mode == .overview
            ? max(740, hasNotch ? collapsedSize.width + 420 : 740)
            : max(collapsedSize.width + 848, 1080)
        return min(availableWidth, preferredWidth)
    }

    func headerBelowNotch(for mode: NotchDashboardMode) -> Bool {
        guard hasNotch, mode == .residential else { return false }
        // Both wings must fit independently; otherwise controls sit below the camera.
        let wingWidth = (width(for: mode) - collapsedSize.width) / 2 - 18
        return wingWidth < 320
    }

    func headerGap(for mode: NotchDashboardMode) -> CGFloat {
        hasNotch && !headerBelowNotch(for: mode) ? collapsedSize.width : 8
    }

    func headerHeight(for mode: NotchDashboardMode) -> CGFloat {
        anchor.isSide && !sideDrawer ? 32 : isExternal ? (anchor.isSide ? 52 : 92) : (headerBelowNotch(for: mode) ? collapsedSize.height + 40 : max(32, collapsedSize.height))
    }

    func expandedSize(for mode: NotchDashboardMode, page: Int = 1) -> CGSize {
        if anchor.isSide && !sideDrawer { return CGSize(width: width(for: mode), height: min(availableHeight, mode == .residential ? 356 : (page == 0 ? 216 : 353))) }
        if anchor.isSide {
            let cap: CGFloat = screenFrame.height >= 1400 ? 700 : 640
            let preferred: CGFloat = mode == .residential || [1, 2, 6].contains(page) ? cap : [0: 520.0, 1: 640, 2: 640, 3: 600, 4: 600, 5: 580, 6: 640][page, default: 640]
            return CGSize(width: width(for: mode), height: min(availableHeight, min(cap, preferred)))
        }
        if !hasNotch {
            let preferred: CGFloat = mode == .residential ? 520 : [0: 300.0, 1: 380, 2: 420, 3: 420, 4: 380, 5: 420, 6: 420][page, default: 380]
            return CGSize(width: width(for: mode), height: min(availableHeight, preferred))
        }
        let bodyHeight: CGFloat = mode == .overview ? (page == 0 ? 184 : 321) : 324
        return CGSize(width: width(for: mode), height: min(availableHeight, headerHeight(for: mode) + bodyHeight))
    }

    func carouselHeight(for page: Int) -> CGFloat {
        max(0, expandedSize(for: .overview, page: page).height - headerHeight(for: .overview) - (isExternal ? 0 : 31))
    }

    /// Global bounds of the visible shape, shared by layout and mouse hit testing.
    func contentFrame(size: CGSize) -> CGRect {
        let x: CGFloat
        switch anchor {
        case .left: x = screenFrame.minX
        case .right: x = screenFrame.maxX - size.width
        case .topCenter: x = screenFrame.midX - size.width / 2
        }
        let y = anchor.isSide ? screenFrame.midY - size.height / 2 : screenFrame.maxY - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    var windowFrame: CGRect {
        let overview = expandedSize(for: .overview)
        let residential = expandedSize(for: .residential)
        // Reserve the largest tab, so changing page never clips content or its shadow.
        let largestHeight = (0...6).map { expandedSize(for: .overview, page: $0).height }.max() ?? overview.height
        let size = CGSize(width: min(screenFrame.width, max(overview.width, residential.width) + (anchor.isSide ? 48 : 40)),
                          height: min(screenFrame.height, max(largestHeight, residential.height) + (isExternal ? 60 : 30)))
        let x: CGFloat
        switch anchor {
        case .left: x = screenFrame.minX
        case .right: x = screenFrame.maxX - size.width
        case .topCenter: x = screenFrame.midX - size.width / 2
        }
        let y = anchor.isSide ? screenFrame.midY - size.height / 2 : screenFrame.maxY - size.height
        return CGRect(x: x, y: y,
                      width: size.width, height: size.height)
    }
}
