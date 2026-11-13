import AppKit
import ServiceManagement
import Combine
import Security
import UniformTypeIdentifiers

import SwiftUI

private struct SpotifyMark: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            ZStack {
                Circle().fill(.white)
                ForEach(0..<3) { index in
                    Path { path in
                        let y = size * (0.34 + CGFloat(index) * 0.14)
                        path.move(to: CGPoint(x: size * 0.22, y: y))
                        path.addQuadCurve(to: CGPoint(x: size * (0.79 - CGFloat(index) * 0.04), y: y + size * 0.08),
                                          control: CGPoint(x: size * 0.52, y: y - size * 0.10))
                    }
                    .stroke(Color.black.opacity(0.85), style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round))
                }
            }
        }
        .accessibilityLabel("Spotify")
    }
}

/// Shared data has one polling pipeline regardless of the number of display panels.
@MainActor
final class NotchSharedContent: ObservableObject {
    // Avoid Swift isolated-deinit back-deployment crashes (swiftlang/swift#88036).
    nonisolated deinit {}
    @Published var spotifyStatus: String?
    @Published var track = AppLanguage.text("Spotify não está aberto")
    @Published var artist = ""
    @Published var album = ""
    @Published var artworkURL = ""
    /// Accent taken from the current album cover; nil falls back to the app accent.
    @Published var artworkTint: Color?
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var seeking = false
    @Published var routerAccount = UserDefaults.standard.string(forKey: "openRouterAccountLabel") ?? ""
    @Published var openAIAccount = UserDefaults.standard.string(forKey: "openAIOrganizationLabel") ?? ""
    @Published var runpodAccount = UserDefaults.standard.string(forKey: "runpodAccountLabel") ?? ""
    @Published var runpodBalance: Double?
    @Published var runpodStatus = AppLanguage.text("Configurar chave")
    @Published var routerBalance: Double?
    @Published var routerStatus = AppLanguage.text("Configurar chave")
    @Published var routerBalanceStale = false
    @Published var alert: NotchAlert?
}

@MainActor
final class NotchState: ObservableObject {
    // Avoid Swift isolated-deinit back-deployment crashes (swiftlang/swift#88036).
    nonisolated deinit {}
    let content: NotchSharedContent
    private var contentObservation: AnyCancellable?
    var spotifyStatus: String? { get { content.spotifyStatus } set { content.spotifyStatus = newValue } }
    var track: String { get { content.track } set { content.track = newValue } }
    var artist: String { get { content.artist } set { content.artist = newValue } }
    var album: String { get { content.album } set { content.album = newValue } }
    var artworkURL: String { get { content.artworkURL } set { content.artworkURL = newValue } }
    var artworkTint: Color? { get { content.artworkTint } set { content.artworkTint = newValue } }
    var playing: Bool { get { content.playing } set { content.playing = newValue } }
    var position: Double { get { content.position } set { content.position = newValue } }
    var duration: Double { get { content.duration } set { content.duration = newValue } }
    var seeking: Bool { get { content.seeking } set { content.seeking = newValue } }
    var routerAccount: String { get { content.routerAccount } set { content.routerAccount = newValue } }
    var openAIAccount: String { get { content.openAIAccount } set { content.openAIAccount = newValue } }
    var runpodAccount: String { get { content.runpodAccount } set { content.runpodAccount = newValue } }
    var runpodBalance: Double? { get { content.runpodBalance } set { content.runpodBalance = newValue } }
    var runpodStatus: String { get { content.runpodStatus } set { content.runpodStatus = newValue } }
    var routerBalance: Double? { get { content.routerBalance } set { content.routerBalance = newValue } }
    var routerStatus: String { get { content.routerStatus } set { content.routerStatus = newValue } }
    var routerBalanceStale: Bool { get { content.routerBalanceStale } set { content.routerBalanceStale = newValue } }
    var alert: NotchAlert? { get { content.alert } set { content.alert = newValue } }
    @Published var collapsedHovered = false
    @Published var expanded = false
    @Published var page = NJPSettings.initialPage {
        didSet {
            // Preview renders must not overwrite the user's remembered tab.
            guard NJPSettings.rememberPage, !CommandLine.arguments.contains(where: { $0.hasPrefix("--render") }) else { return }
            UserDefaults.standard.set(page, forKey: NJPSettings.lastPageKey)
        }
    }
    /// Opened with the keyboard shortcut: stays open until the pointer visits and leaves.
    @Published var pinned = false
    @Published var dashboardMode: NotchDashboardMode = .overview
    @Published var residentialDevice: ResidentialDevice = .favorites
    let home: HomeAutomation
    let tvController: LGTVController
    @Published var airDirection: WindDirectionIcon.Axis?
    let airController: ACController
    @Published var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())
    /// Event whose details are open in a popover; keeps the panel from closing.
    @Published var eventDetail: CalendarEventItem?
    @Published var dayListOpen = false
    /// Width added to each side of the collapsed notch while an alert is shown.
    static let alertWing: CGFloat = 84
    @Published var layout = DashboardLayout(screenFrame: .zero, visibleFrame: .zero, notchSize: .zero)
    var collapsedSize: CGSize { layout.collapsedSize }
    var collapsedDisplaySize: CGSize {
        layout.anchor.isSide ? CGSize(width: collapsedHovered ? 32 : collapsedSize.width, height: collapsedSize.height) : CGSize(width: collapsedSize.width + (alert == nil ? 0 : 2 * Self.alertWing), height: collapsedSize.height)
    }
    var activeExpandedSize: CGSize { layout.expandedSize(for: dashboardMode, page: page) }

    init(airController: ACController? = nil, tvController: LGTVController? = nil, content: NotchSharedContent? = nil, home: HomeAutomation? = nil) {
        self.content = content ?? NotchSharedContent()
        self.airController = airController ?? ACController(backend: TCLBackend.shared)
        self.tvController = tvController ?? LGTVController()
        self.home = home ?? HomeAutomation(air: self.airController, tv: self.tvController)
        contentObservation = self.content.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

private struct BlackNotchView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var state: NotchState
    @State private var codexUsage = CodexUsageService.shared
    @State private var claudeUsage = ClaudeUsageService.shared
    @State private var agyUsage = AntigravityUsageService.shared
    @State private var openAIBalance = OpenAICreditBalanceService.shared
    @State private var refreshingQuotas = false
    @ObservedObject private var calendarService = CalendarEventsService.shared
    @AppStorage(NJPSettings.accentIndexKey) private var accentIndex = 0
    @AppStorage("njp.liquidGlass") private var liquidGlass = false
    @AppStorage("njp.glassContrast") private var glassContrast = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppLanguage.key) private var language = "pt-BR"
    @State private var tabsRevision = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var updatingQuotas: Bool {
        refreshingQuotas || claudeUsage.isLoading || agyUsage.isRefreshing || openAIBalance.isRefreshing
    }

    /// The app ships no pt-BR localization, so dates would fall back to English without this.
    private static var locale: Locale { AppLanguage.locale }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Self.locale
        return calendar
    }

    private var days: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: state.month),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: state.month)) else { return [] }
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: offset) + range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: first)
        }.map(Optional.some)
    }

    private var weekdays: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    /// Collapsed keeps the tight camera-housing curve; expanded rounds the shoulders and the base.
    private static let expandedTopRadius: CGFloat = 22
    private var topRadius: CGFloat { state.expanded ? Self.expandedTopRadius : 6 }
    private var bottomRadius: CGFloat { state.expanded ? 36 : 28 }
    private var backdrop: AnyShape {
        if state.layout.isExternal && !state.layout.anchor.isSide {
            return AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: state.expanded ? 22 : 14, bottomTrailingRadius: state.expanded ? 22 : 14))
        }
        guard state.layout.anchor.isSide else {
            return AnyShape(NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius))
        }
        let radius: CGFloat = state.expanded ? 22 : 14
        let left: CGFloat = state.layout.anchor == .left ? 0 : radius
        let right: CGFloat = state.layout.anchor == .right ? 0 : radius
        return AnyShape(UnevenRoundedRectangle(topLeadingRadius: left, bottomLeadingRadius: left,
                                               bottomTrailingRadius: right, topTrailingRadius: right))
    }

    private var useGlass: Bool {
        let requested = liquidGlass || CommandLine.arguments.contains("--preview-glass")
        let reduced = reduceTransparency || CommandLine.arguments.contains("--preview-reduce-transparency")
        if #available(macOS 26.0, *) { return requested && state.expanded && !reduced }
        return false
    }

    @ViewBuilder private var panelBackground: some View {
        if useGlass {
            PanelContentMaterial()
                .overlay(Color.black.opacity(glassContrast ? 0.72 : 0.52))
                .allowsHitTesting(false)
        } else {
            backdrop.fill(Color(nsColor: NSColor(calibratedWhite: 0.03, alpha: 1)))
        }
    }

    private var displayAlignment: Alignment {
        switch state.layout.anchor {
        case .left: .leading
        case .right: .trailing
        case .topCenter: .top
        }
    }

    var body: some View {
        panelBackground
            .frame(width: state.expanded ? state.activeExpandedSize.width : state.collapsedDisplaySize.width,
                   height: state.expanded ? state.activeExpandedSize.height : state.collapsedSize.height)
            .overlay(alignment: .top) {
                if state.expanded {
                    Group {
                        if state.layout.isExternal { externalExpandedContent }
                        else { notchExpandedContent }
                    }
                        .frame(width: state.layout.isExternal ? state.activeExpandedSize.width : state.activeExpandedSize.width - 2 * Self.expandedTopRadius,
                               height: state.activeExpandedSize.height, alignment: .top)
                        .clipped()
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            loadFileURLs(from: providers) { urls in
                                FileShelfStore.shared.add(urls)
                                UserDefaults.standard.set(2, forKey: NJPSettings.toolsSectionKey)
                                withAnimation(.easeInOut(duration: 0.22)) { state.page = 5 }
                            }
                            return true
                        }
                        // Appears after the shape has grown, and leaves before it shrinks.
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                            removal: .opacity.animation(.easeIn(duration: 0.08))))
                }
            }
            .overlay(alignment: .top) {
                if !state.expanded {
                    if state.layout.anchor.isSide {
                        DockStatusTab(alert: state.alert, anchor: state.layout.anchor)
                            .onHover { inside in if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
                    } else if let alert = state.alert { collapsedAlert(alert) }
                }
            }
            // Content can never draw outside the (animating) background.
            .clipShape(backdrop)
            .overlay { if state.layout.isExternal { backdrop.stroke(.white.opacity(0.16), lineWidth: 1).allowsHitTesting(false) } }
            .shadow(color: .black.opacity(state.layout.isExternal && state.expanded ? 0.45 : 0), radius: 22,
                    x: state.layout.anchor == .left ? 14 : (state.layout.anchor == .right ? -14 : 0), y: state.layout.anchor.isSide ? 0 : 14)
            .onReceive(NotificationCenter.default.publisher(for: .njpSettingsChanged)) { _ in
                tabsRevision += 1
                if !PanelTabs.visible.contains(state.page) { state.page = PanelTabs.visible[0] }
            }
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Self.locale)
            .id(language)
            .padding(.horizontal, state.layout.anchor.isSide ? 0 : 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: displayAlignment)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : (state.expanded ? .spring(response: 0.5, dampingFraction: 0.78)
                       : .spring(response: 0.36, dampingFraction: 0.88)), value: state.expanded)
            .animation(.easeInOut(duration: 0.22), value: state.page)
            .animation(.easeOut(duration: 0.12), value: state.collapsedHovered)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.85), value: state.alert)
    }

    private var notchExpandedContent: some View {
                    VStack(spacing: 0) {
                        navigation
                        Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
                        if state.dashboardMode == .residential {
                            ScrollView(.vertical) {
                                switch state.residentialDevice {
                                case .favorites:
                                    HomeFavoritesView(home: state.home, selection: $state.residentialDevice)
                                case .air:
                                    ResidentialAirControlView(controller: state.airController, directionAxis: $state.airDirection)
                                case .tv:
                                    ResidentialTVControlView(controller: state.tvController)
                                case .scenes:
                                    HomeScenesView(home: state.home)
                                }
                            }
                        } else {
                            carouselView
                        }
                    }
    }

    private var externalExpandedContent: some View {
        Group {
            if state.layout.anchor.isSide {
                HStack(spacing: 0) {
                    if state.layout.anchor == .left { dockRail }
                    externalColumn.frame(width: max(0, state.activeExpandedSize.width - 56))
                    if state.layout.anchor == .right { dockRail }
                }
            } else {
                VStack(spacing: 0) {
                    externalTopNavigation.frame(height: 48)
                    externalColumn
                }
            }
        }.environment(\.panelComposition, state.layout.composition)
    }

    private var dockRail: some View {
        VStack(spacing: 3) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 3) {
            NotchJPMark(size: 28).padding(.vertical, 9)
            ForEach(PanelTabs.visible, id: \.self) { index in
                DockRailButton(symbol: PanelTabs.symbols[index], title: PanelTabs.titles[index],
                               selected: state.dashboardMode == .overview && state.page == index,
                               badge: index == 4 && state.alert?.pulses == true) {
                    withAnimation(.easeInOut(duration: 0.22)) { state.dashboardMode = .overview; state.page = index }
                }
            }
                }
            }
            DockRailButton(symbol: state.dashboardMode == .residential ? "house.fill" : "house", title: AppLanguage.text("Casa"),
                           selected: state.dashboardMode == .residential) {
                withAnimation(.easeInOut(duration: 0.22)) { state.dashboardMode.toggleResidential() }
            }
            DisplayResolutionQuickMenu().frame(width: 40, height: 40)
            DockRailButton(symbol: "gearshape", title: "Ajustes") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
        }.padding(.vertical, 12).frame(width: 56).frame(maxHeight: .infinity)
            .background(NJP.layer1.opacity(useGlass ? 0.65 : 1))
            .modifier(PanelRailMaterial(enabled: useGlass))
            .overlay(alignment: state.layout.anchor == .left ? .trailing : .leading) { Color.white.opacity(0.09).frame(width: 1) }
    }

    private var externalTopNavigation: some View {
        HStack(spacing: 6) {
            NotchJPMark(size: 28)
            ForEach(PanelTabs.visible, id: \.self) { index in
                DockRailButton(symbol: PanelTabs.symbols[index], title: PanelTabs.titles[index],
                               selected: state.dashboardMode == .overview && state.page == index) {
                    withAnimation(.easeInOut(duration: 0.22)) { state.dashboardMode = .overview; state.page = index }
                }
            }
            Spacer(minLength: 0)
            DockRailButton(symbol: "house", title: AppLanguage.text("Casa"), selected: state.dashboardMode == .residential) { state.dashboardMode.toggleResidential() }
            DisplayResolutionQuickMenu()
            DockRailButton(symbol: "gearshape", title: "Ajustes") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
        }.padding(.horizontal, 16).background(NJP.layer1.opacity(useGlass ? 0.6 : 1))
    }

    private var externalColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state.dashboardMode == .residential ? AppLanguage.text("Casa") : PanelTabs.titles[state.page]).font(.system(size: 15, weight: .semibold))
                Spacer()
                if state.page == 1 && state.dashboardMode == .overview {
                    Button(action: refreshQuotas) { Image(systemName: "arrow.clockwise").frame(width: 30, height: 30).background(NJP.surfaceStrong, in: Circle()) }
                        .buttonStyle(.plain).disabled(updatingQuotas).help(AppLanguage.text("Atualizar cotas e saldos"))
                }
            }.padding(.horizontal, 16).frame(height: state.layout.anchor.isSide ? 52 : 44)
            Divider().overlay(.white.opacity(0.1))
            if state.dashboardMode == .residential {
                Picker("Aparelho", selection: $state.residentialDevice) {
                    ForEach(ResidentialDevice.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.vertical, 10)
                ScrollView(.vertical) {
                    residentialContent.frame(width: max(0, state.activeExpandedSize.width - (state.layout.anchor.isSide ? 56 : 0)), alignment: .topLeading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical) {
                    externalPageContent.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 18)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(state.page == 0 ? .hidden : .automatic)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var residentialContent: some View {
        switch state.residentialDevice {
        case .favorites: HomeFavoritesView(home: state.home, selection: $state.residentialDevice)
        case .air: ResidentialAirControlView(controller: state.airController, directionAxis: $state.airDirection)
        case .tv: ResidentialTVControlView(controller: state.tvController)
        case .scenes: HomeScenesView(home: state.home)
        }
    }

    @ViewBuilder private var externalPageContent: some View {
        switch state.page {
        case 0: SpotifyPanelView(state: state)
        case 1:
            let layout = state.layout.anchor.isSide ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
            layout { codexView.externalPanelCard(); balancesView.externalPanelCard() }
                .onAppear {
                    guard !CommandLine.arguments.contains(where: { $0.hasPrefix("--render") }) else { return }
                    CostHistoryStore.shared.start(); CostHistoryStore.sharedCodex.start(); CostHistoryStore.sharedDevin.start()
                }
        case 2: calendarView.externalPanelCard()
        case 3: MacHealthView()
        case 4: SessionsView().frame(minHeight: state.layout.anchor.isSide ? 380 : 240)
        case 6: AppAudioMixerView().frame(height: state.layout.anchor.isSide ? 480 : 250)
        default: ToolsView(home: state.home).frame(minHeight: state.layout.anchor.isSide ? 440 : 260)
        }
    }

    @ViewBuilder private func collapsedAlert(_ alert: NotchAlert) -> some View {
        if state.layout.anchor.isSide {
            Image(systemName: alert.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(alert.tint)
                .frame(width: state.collapsedSize.width, height: state.collapsedSize.height)
                .help(alert.accessibilityText)
                .accessibilityLabel(alert.accessibilityText)
        } else { alertWings(alert) }
    }

    /// Icon on the left and countdown or figure on the right, either side of the camera housing.
    private func alertWings(_ alert: NotchAlert) -> some View {
        HStack(spacing: 0) {
            Image(systemName: alert.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(alert.tint)
                .symbolEffect(.pulse, isActive: alert.pulses)
                .symbolEffect(.variableColor.iterative, isActive: alert.animatesIcon)
                .frame(width: NotchState.alertWing)
            Spacer(minLength: state.collapsedSize.width)
            TimelineView(.periodic(from: .now, by: alert.ticksEverySecond ? 1 : 20)) { context in
                Text(alert.label(now: context.date))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: NotchState.alertWing - 10)
            .padding(.trailing, 10)
        }
        .frame(width: state.collapsedDisplaySize.width, height: state.collapsedSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(alert.accessibilityText)
    }

    private var carouselView: some View {
        VStack(spacing: 4) {
            Group {
                switch state.page {
                case 0:
                    SpotifyPanelView(state: state)
                case 1:
                    HStack(alignment: .top, spacing: 10) {
                        ScrollView(.vertical) { codexView.frame(maxWidth: .infinity, alignment: .topLeading).padding(.bottom, 8) }
                        ScrollView(.vertical) { balancesView.frame(maxWidth: .infinity, alignment: .topLeading).padding(.bottom, 8) }
                    }
                    .onAppear {
                        CostHistoryStore.shared.start()
                        CostHistoryStore.sharedCodex.start()
                        CostHistoryStore.sharedDevin.start()
                    }
                case 2:
                    calendarView
                case 3:
                    MacHealthView()
                case 4:
                    SessionsView()
                case 6:
                    AppAudioMixerView()
                default:
                    ToolsView(home: state.home)
                }
            }
            .frame(width: max(0, state.activeExpandedSize.width - 24 - 2 * Self.expandedTopRadius), height: state.layout.carouselHeight(for: state.page), alignment: .top)
            .clipped()
            .id(state.page)
            .transition(.opacity)
            // Keeps the old dots' height so DashboardLayout's sizes stay valid.
            Color.clear.frame(height: 6)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var navigation: some View {
        VStack(spacing: 0) {
            if state.layout.headerBelowNotch(for: state.dashboardMode) {
                Color.clear.frame(height: state.collapsedSize.height)
            }
            navigationRow
                .frame(height: state.layout.headerBelowNotch(for: state.dashboardMode) ? 40 : max(32, state.collapsedSize.height))
        }
        .foregroundStyle(Color.primary)
    }

    private var navigationRow: some View {
        let _ = tabsRevision
        return HStack(spacing: 8) {
            if showBrand { NotchJPMark(size: 22) }
            if state.dashboardMode == .residential {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { state.dashboardMode = .overview }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "house.fill")
                        Text(AppLanguage.text("Controle residencial"))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Voltar ao painel principal")
            } else {
                HStack(spacing: 2) {
                    ForEach(PanelTabs.visible, id: \.self) { id in
                        pageTab(id, symbol: PanelTabs.symbols[id], title: PanelTabs.titles[id])
                    }
                }
                .padding(.horizontal, useGlass ? 4 : 0)
                .modifier(PanelNavigationMaterial(enabled: useGlass))
            }
            if state.dashboardMode == .residential {
                HStack(spacing: 3) {
                    ForEach(ResidentialDevice.allCases, id: \.self) { device in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { state.residentialDevice = device }
                        } label: {
                            Label(device.title, systemImage: device.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .foregroundStyle(Color.primary.opacity(state.residentialDevice == device ? 1 : 0.5))
                                .background(.white.opacity(state.residentialDevice == device ? 0.16 : 0), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(device == .air ? "Controle do ar-condicionado" : (device == .tv ? AppLanguage.text("Controle da TV") : AppLanguage.text("Cenas da casa")))
                        .accessibilityIdentifier("residential-device-" + device.rawValue)
                        .accessibilityAddTraits(state.residentialDevice == device ? .isSelected : [])
                    }
                }
            }
            Spacer(minLength: state.layout.headerGap(for: state.dashboardMode))
            if state.dashboardMode == .overview && state.page == 1 {
                Button(action: refreshQuotas) {
                    Group {
                        if updatingQuotas {
                            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(updatingQuotas)
                .help(AppLanguage.text("Atualizar cotas e saldos"))
                .accessibilityLabel(AppLanguage.text("Atualizar cotas e saldos"))
                .accessibilityIdentifier("refresh-quotas")
            }
            DisplayResolutionQuickMenu()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { state.dashboardMode.toggleResidential() }
            } label: {
                Image(systemName: state.dashboardMode == .residential ? "house.fill" : "house")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state.dashboardMode == .residential ? Color.white : Color.white.opacity(0.7))
                    .frame(width: 32, height: 28)
                    .background(.white.opacity(state.dashboardMode == .residential ? 0.16 : 0), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(state.dashboardMode == .residential ? "Voltar ao painel principal" : AppLanguage.text("Controle residencial"))
            .accessibilityLabel(AppLanguage.text("Controle residencial"))
            .accessibilityValue(state.dashboardMode == .residential ? "Ativado" : "Desativado")
            .accessibilityIdentifier("residential-mode-toggle")
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(AppLanguage.text("Configurações do notchJP"))
            .accessibilityLabel(AppLanguage.text("Configurações do notchJP"))
            .accessibilityIdentifier("open-notchi-settings")
        }
        .padding(.horizontal, 4)
    }

    /// Room for each wing beside the camera housing, in points.
    private var wingWidth: CGFloat {
        let inner = state.activeExpandedSize.width - 2 * Self.expandedTopRadius
        return (inner - state.layout.headerGap(for: .overview)) / 2 - 4
    }

    /// The N mark gives way before the tabs get cramped.
    private var showBrand: Bool { wingWidth >= 30 + CGFloat(PanelTabs.visible.count) * 24 + 10 }
    private var tabWidth: CGFloat {
        max(18, min(26, (wingWidth - (showBrand ? 30 : 0) - 10) / CGFloat(PanelTabs.visible.count)))
    }

    /// Page switcher kept inside the wing beside the notch; the title lives in the tooltip.
    private func pageTab(_ index: Int, symbol: String, title: String) -> some View {
        let selected = state.page == index
        return Button {
            withAnimation(.easeInOut(duration: 0.22)) { state.page = index }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.55))
                .frame(width: tabWidth, height: 28)
                .background(selected ? NJP.accent : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func refreshQuotas() {
        guard !updatingQuotas else { return }
        refreshingQuotas = true
        claudeUsage.retryNow()
        Task {
            defer { refreshingQuotas = false }
            async let codex: Void = codexUsage.refreshFromAPI(force: true)
            async let agy: Void = agyUsage.refresh()
            async let openAI: Void = openAIBalance.refresh()
            async let router: Void = refreshRouter(state)
            async let runpod: Void = refreshRunpod(state)
            _ = await (codex, agy, openAI, router, runpod)
        }
    }

    private var codexView: some View {
        VStack(alignment: .leading, spacing: 10) {
            CostSummaryCard()
            providerQuota("Codex", session: codexUsage.currentUsage, weekly: codexUsage.currentWeeklyUsage,
                          stale: codexUsage.isUsageStale, unlimited: codexUsage.hasUnlimitedCredits)
            providerQuota("Claude", session: claudeUsage.currentUsage, weekly: claudeUsage.currentWeeklyUsage,
                          stale: claudeUsage.isUsageStale, unlimited: false,
                          emptyText: claudeUsage.statusMessage ?? claudeUsage.error ?? "Aguardando cota do Claude Code")
            providerQuota("AGY · Argon", session: nil, weekly: agyUsage.snapshot.argonWeekly,
                          stale: agyUsage.isUsageStale, unlimited: false, emptyText: agyUsage.status)
                .help("Cota semanal do Gemini Argon no AGY")
            providerQuota("AGY · Gemini Flash", session: agyUsage.snapshot.geminiSession,
                          weekly: agyUsage.snapshot.geminiWeekly,
                          stale: agyUsage.isUsageStale, unlimited: false, emptyText: agyUsage.status)
                .help("Cota do grupo Gemini no AGY, compartilhada entre Flash e Pro")
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var balancesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("API OpenAI").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.primary)
                    Spacer()
                    if openAIBalance.snapshot != nil && openAIBalance.isStale {
                        Text("Desatualizado").font(.system(size: 9, weight: .semibold)).foregroundStyle(NJP.warn)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(NJP.warn.opacity(0.15), in: Capsule())
                    }
                }
                if !state.openAIAccount.isEmpty {
                    Text(state.openAIAccount).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7)).lineLimit(1)
                }
                if let snapshot = openAIBalance.snapshot {
                    Text(openAIBalance.isStale ? AppLanguage.text("Último saldo lido") : AppLanguage.text("Saldo disponível"))
                        .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
                    Text(snapshot.balance, format: .currency(code: "USD"))
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Color.primary)
                    Text(snapshot.observedAt, format: .dateTime.day().month().hour().minute())
                        .font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.7))
                }
                if openAIBalance.snapshot == nil || openAIBalance.isStale {
                    Text(openAIBalance.status).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .njpCard()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("OpenRouter").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.primary)
                    Spacer()
                }
                if !state.routerAccount.isEmpty {
                    Text(state.routerAccount).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7)).lineLimit(1)
                }
                if let balance = state.routerBalance {
                    Text(balance, format: .currency(code: "USD"))
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Color.primary)
                }
                if state.routerBalance == nil || state.routerBalanceStale {
                    Text(state.routerStatus)
                        .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .njpCard()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Runpod").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.primary)
                    Spacer()
                }
                if !state.runpodAccount.isEmpty {
                    Text(state.runpodAccount).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7)).lineLimit(1)
                }
                if let balance = state.runpodBalance {
                    Text(balance, format: .currency(code: "USD"))
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Color.primary)
                } else {
                    Text(state.runpodStatus)
                        .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .njpCard()
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func providerQuota(_ name: String, session: QuotaPeriod?, weekly: QuotaPeriod?,
                               stale: Bool, unlimited: Bool, emptyText: String = AppLanguage.text("Cota indisponível")) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.primary)
                Spacer()
                if stale { Text("Desatualizado").font(.system(size: 9, weight: .semibold)).foregroundStyle(NJP.warn).padding(.horizontal, 7).padding(.vertical, 3).background(NJP.warn.opacity(0.15), in: Capsule()) }
            }
            if unlimited {
                Text("Ilimitado").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.7))
            } else if session != nil || weekly != nil {
                if let session { quotaRow(AppLanguage.text("Sessão"), period: session) }
                if let weekly { quotaRow("Semanal", period: weekly) }
            } else {
                Text(emptyText).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .njpCard()
    }

    private func quotaRow(_ title: String, period: QuotaPeriod) -> some View {
        let remaining = max(0, min(100, 100 - period.usagePercentage))
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).foregroundStyle(Color.primary.opacity(0.7))
                Spacer()
                Text("\(remaining)%").foregroundStyle(Color.primary)
            }.font(.system(size: 12, weight: .medium))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule().fill(NJP.level(forRemaining: remaining)).frame(width: proxy.size.width * CGFloat(remaining) / 100)
                }
            }.frame(height: 6)
        }
        .help(period.formattedResetTime.map { "Renova em \($0)" } ?? "Cota restante")
    }

    private var calendarView: some View {
        Group {
            if state.layout.isExternal && !state.layout.anchor.isSide {
                HStack(alignment: .top, spacing: 20) {
                    monthGrid.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 12) { Text("Compromissos \(selectedDayPhrase)").font(.headline); agendaStrip }.frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 10) { monthGrid; agendaStrip; Spacer(minLength: 0) }
            }
        }.onAppear { calendarService.setVisibleMonth(state.month) }
         .onChange(of: state.month) { _, month in calendarService.setVisibleMonth(month) }
    }

    private var monthGrid: some View {
        VStack(spacing: 8) {
            HStack {
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)).frame(width: 28, height: 28).background(NJP.surfaceStrong, in: Circle()) }
                Spacer()
                Text(monthTitle)
                    .font(.system(size: 17, weight: .bold))
                if !calendar.isDate(state.month, equalTo: Date(), toGranularity: .month) {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { goToToday() } } label: {
                        Text(AppLanguage.text("Hoje")).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(NJP.accent, in: Capsule())
                    }
                }
                Spacer()
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 28, height: 28).background(NJP.surfaceStrong, in: Circle()) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 5)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, day in
                    Text(day.uppercased()).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(height: 20)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayCell(date)
                    } else {
                        Color.clear.frame(height: 32)
                    }
                }
            }
        }
        .padding(.horizontal, state.layout.isExternal ? 0 : 26)
    }

    private func dayCell(_ date: Date) -> some View {
        let today = calendar.isDateInToday(date)
        let selected = calendar.isDate(date, inSameDayAs: state.selectedDay)
        let colors = calendarService.dotColors(on: date)
        return Button { state.selectedDay = date } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 14, weight: today ? .bold : .medium))
                .foregroundStyle(Color.primary)
                .frame(width: 32, height: 32)
                .background(today ? NJP.accent : Color.clear, in: Circle())
                .overlay { if selected && !today { Circle().stroke(.white.opacity(0.35), lineWidth: 1.5) } }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 2) {
                        ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                            Circle().fill(today ? Color.white : color).frame(width: 4, height: 4)
                        }
                    }
                    .padding(.bottom, 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(.dateTime.day().month(.wide).locale(Self.locale)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Events of the selected day, or the way to connect the Mac's calendar.
    @ViewBuilder
    private var agendaStrip: some View {
        switch calendarService.access {
        case .unknown:
            Button { Task { await calendarService.requestAccess() } } label: {
                agendaLabel(symbol: "calendar.badge.plus", text: AppLanguage.text("Conectar agenda do Mac"), prominent: true)
            }
            .buttonStyle(.plain)
        case .denied:
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                agendaLabel(symbol: "lock", text: AppLanguage.text("Permitir a agenda em Ajustes do Sistema"), prominent: false)
            }
            .buttonStyle(.plain)
        case .granted:
            let events = calendarService.events(on: state.selectedDay)
            if events.isEmpty {
                agendaLabel(symbol: "checkmark.circle", text: "Sem compromissos \(selectedDayPhrase)", prominent: false)
            } else {
                let layout = state.layout.isExternal ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    ForEach(events.prefix(state.layout.isExternal ? 20 : 2)) { event in eventPill(event) }
                    if events.count > 2 && !state.layout.isExternal {
                        Button { state.dayListOpen = true } label: {
                            Text("+\(events.count - 2)").font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(NJP.surfaceStrong, in: Capsule())
                        }
                        .buttonStyle(.plain).help(AppLanguage.text("Ver todos os compromissos do dia"))
                        .popover(isPresented: $state.dayListOpen, arrowEdge: .top) {
                            DayEventsListView(day: state.selectedDay, events: events) { event in
                                state.dayListOpen = false
                                state.eventDetail = event
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var selectedDayPhrase: String {
        calendar.isDateInToday(state.selectedDay)
            ? "hoje"
            : "em " + state.selectedDay.formatted(.dateTime.day().month(.abbreviated).locale(Self.locale))
    }

    private func agendaLabel(symbol: String, text: String, prominent: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(prominent ? Color.white : .white.opacity(0.6))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(prominent ? NJP.accent : NJP.surface, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eventPill(_ event: CalendarEventItem) -> some View {
        let time = event.isAllDay ? AppLanguage.text("Dia todo") : event.start.formatted(.dateTime.hour().minute().locale(Self.locale))
        let label = HStack(spacing: 5) {
            Circle().fill(event.color).frame(width: 7, height: 7)
            Text(time).font(.system(size: 11, weight: .bold))
            Text(event.title).font(.system(size: 11)).lineLimit(1)
            if event.joinURL != nil { Image(systemName: "video.fill").font(.system(size: 10)).foregroundStyle(NJP.accentSoft) }
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(NJP.surface, in: Capsule())
        return VStack(alignment: .leading, spacing: 6) {
            Button { state.eventDetail = event } label: { label }
            if state.layout.isExternal, let url = event.joinURL {
                Link(AppLanguage.text("Entrar na reunião"), destination: url).font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5).background(NJP.accent, in: Capsule())
            }
        }
            .buttonStyle(.plain)
            .help(AppLanguage.text("Ver detalhes"))
            .popover(isPresented: Binding(
                get: { state.eventDetail?.id == event.id },
                set: { if !$0 { state.eventDetail = nil } }
            ), arrowEdge: .top) { EventDetailView(event: event) }
    }

    /// "novembro de 2026" with only the first letter capitalised.
    private var monthTitle: String {
        let title = state.month.formatted(.dateTime.month(.wide).year().locale(Self.locale))
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    private func goToToday() {
        state.month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? state.month
    }

    private func changeMonth(_ offset: Int) {
        if let month = calendar.date(byAdding: .month, value: offset, to: state.month) {
            state.month = month
        }
    }
}

let routerKeyService = "com.appmac.notch.openrouter.management"

@MainActor
func refreshRouter(_ state: NotchState) async {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: routerKeyService, kSecAttrAccount as String: "management",
        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip]
    var result: CFTypeRef?
    let keyStatus = SecItemCopyMatching(KeychainAccessPolicy.query(query) as CFDictionary, &result)
    guard keyStatus == errSecSuccess, let data = result as? Data,
          let key = String(data: data, encoding: .utf8) else {
        state.routerBalanceStale = state.routerBalance != nil
        state.routerStatus = keyStatus == errSecItemNotFound ? "Configure a chave de gerenciamento"
            : "Salve a chave novamente nas configurações"
        return
    }
    guard key.hasPrefix("sk-or-") else {
        state.routerBalance = nil
        state.routerBalanceStale = false
        state.routerStatus = "A chave salva não é do OpenRouter"
        return
    }
    var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/credits")!)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            state.routerBalanceStale = state.routerBalance != nil
            state.routerStatus = OpenRouterCreditBalance.status(for: http.statusCode)
            return
        }
        state.routerBalance = try OpenRouterCreditBalance.parse(data)
        state.routerBalanceStale = false
        state.routerStatus = "Atualizado"
    } catch {
        state.routerBalanceStale = state.routerBalance != nil
        state.routerStatus = (error as? URLError)?.code == .cannotParseResponse
            ? "Resposta de saldo inesperada" : "Falha de conexão — use Atualizar"
    }
}

let runpodKeyService = "com.appmac.notch.runpod"

@MainActor
func refreshRunpod(_ state: NotchState) async {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: runpodKeyService, kSecAttrAccount as String: "api",
        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    guard SecItemCopyMatching(KeychainAccessPolicy.query(query) as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
        state.runpodStatus = "Autorize a chave nos ajustes do Runpod"; return
    }
    var request = URLRequest(url: URL(string: "https://api.runpod.io/graphql")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": "query { myself { clientBalance } }"])
    request.timeoutInterval = 15
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["errors"] == nil,
              let payload = object["data"] as? [String: Any],
              let myself = payload["myself"] as? [String: Any],
              let balance = myself["clientBalance"] as? Double, balance.isFinite else { throw URLError(.badServerResponse) }
        state.runpodBalance = balance
        state.runpodStatus = "Atualizado"
    } catch {
        state.runpodBalance = nil
        state.runpodStatus = AppLanguage.text("Saldo indisponível")
    }
}


private final class DashboardNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class DashboardScreenPanel {
    let state: NotchState
    let window: NSPanel
    var hovering = false
    var hoverChangedAt = Date()
    var pinnedAt = Date.distantPast
    var pinnedMouseSeen = false
    var swipeAccumulator: CGFloat = 0
    var swipeLocked = false
    init(state: NotchState, window: NSPanel) { self.state = state; self.window = window }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    private var qaWindows: [NSWindow] = []
    #endif
    private var displayPanels: [ScreenIdentifier: DashboardScreenPanel] = [:]
    private var timer: Timer?
    private var alertTimer: Timer?
    private var serviceTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var sleeping = false
    private var shortcutService: GlobalShortcutService?
    private var scrollMonitor: Any?
    private var settingsObserver: NSObjectProtocol?
    private var agentObserver: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    let state = NotchState()
    private var lastSpotifyRefresh = Date.distantPast
    private var lastRouterRefresh = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Explicit maintenance commands run only from the canonical installed bundle.
        if CommandLine.arguments.contains("--enable-launch-at-login") || CommandLine.arguments.contains("--launch-at-login-status") {
            guard Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/notchJP.app" else {
                print("A abertura automática deve apontar para /Applications/notchJP.app.")
                exit(1)
            }
            do {
                if CommandLine.arguments.contains("--enable-launch-at-login"), SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound {
                    try SMAppService.mainApp.register()
                }
                switch SMAppService.mainApp.status {
                case .enabled: print("launch-at-login: enabled"); exit(0)
                case .requiresApproval: print("launch-at-login: requires-approval"); exit(2)
                case .notRegistered: print("launch-at-login: not-registered"); exit(3)
                case .notFound: print("launch-at-login: not-found"); exit(4)
                @unknown default: print("launch-at-login: unknown"); exit(5)
                }
            } catch {
                print("Falha ao configurar abertura automática: \(error.localizedDescription)")
                exit(1)
            }
        }

        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        if let flag = CommandLine.arguments.firstIndex(of: "--render-overview-preview"),
           CommandLine.arguments.count > flag + 2 {
            renderResidentialPreview(to: CommandLine.arguments[flag + 1], overviewPage: Int(CommandLine.arguments[flag + 2]))
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-event-preview"),
           CommandLine.arguments.count > flag + 1 {
            renderEventPreview(to: CommandLine.arguments[flag + 1])
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-settings-preview"),
           CommandLine.arguments.count > flag + 1 {
            renderSettingsPreview(to: CommandLine.arguments[flag + 1])
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-residential-preview"),
           CommandLine.arguments.count > flag + 1 {
            renderResidentialPreview(to: CommandLine.arguments[flag + 1])
            return
        }
        // Test hosts must not start real account polling or open the notch.
        if NSClassFromString("XCTestCase") != nil { return }
        #endif
        AppExperience.home = state.home
        if !UserDefaults.standard.bool(forKey: "njp.guideCompleted") {
            DispatchQueue.main.async { AppExperience.showGuide() }
        }
        AppUpdateService.shared.start()
        AppAudioMixer.shared.start()
        state.home.start()
        configurePanel()
        SystemHealthService.shared.startBackground()
        CalendarEventsService.shared.refresh()
        applyIntegrationSettings()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .njpSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyIntegrationSettings()
                guard let self else { return }
                if NSScreen.screens.contains(where: { screen in
                    self.displayPanels[ScreenIdentifier(screen: screen)].map { $0.state.layout.sideDrawer != DisplayPanelPreferences.usesDrawer(on: screen) } ?? false
                }) { self.configurePanel() }
            }
        }
        agentObserver = AgentActivityMonitor.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAlerts() }
        SystemHealthService.shared.$micInUse.combineLatest(SystemHealthService.shared.$cameraInUse)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAlerts() }
            .store(in: &cancellables)
        DictationController.shared.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAlerts() }
            .store(in: &cancellables)
        FocusTimerService.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAlerts() }
            .store(in: &cancellables)
        state.content.$playing.combineLatest(state.content.$track)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAlerts() }
            .store(in: &cancellables)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
            return event
        }
        refreshAlerts()
        alertTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                CalendarEventsService.shared.refresh()
                self?.refreshAlerts()
            }
        }
        CodexUsageService.shared.startPolling()
        ClaudeUsageService.shared.startPolling()
        AntigravityUsageService.shared.startPolling()
        Task { await OpenAICreditBalanceService.shared.refresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        startInteractionTimers()
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleeping = true
                self?.timer?.invalidate(); self?.timer = nil
                self?.serviceTimer?.invalidate(); self?.serviceTimer = nil
            }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.startInteractionTimers(); self?.lastSpotifyRefresh = .distantPast; self?.refreshVisibleServices() }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        DisplayResolutionService.shared.revert()
        AppAudioMixer.shared.stop()
        state.home.stop()
        CodexUsageService.shared.stopPolling()
        ClaudeUsageService.shared.stopPolling()
        AntigravityUsageService.shared.stopPolling()
        timer?.invalidate()
        alertTimer?.invalidate()
        serviceTimer?.invalidate()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    /// Starts or stops the keyboard shortcut and the hook listener to match the settings.
    private func applyIntegrationSettings() {
        DictationController.applySetting()
        ClipboardHistoryService.shared.apply()
        if NJPSettings.shortcutEnabled {
            if shortcutService == nil {
                shortcutService = GlobalShortcutService(togglePanel: { [weak self] in self?.togglePanelFromShortcut() })
            }
            shortcutService?.start()
        } else {
            shortcutService?.stop()
        }
        if NJPSettings.agentAlert {
            AgentActivityMonitor.shared.start()
        } else {
            AgentActivityMonitor.shared.stop()
        }
        refreshAlerts()
    }

    private func togglePanelFromShortcut() {
        // Use the display under the pointer; NSScreen.main follows focus and is not the primary display.
        let mouse = NSEvent.mouseLocation
        let context = displayPanels.values.first { $0.state.layout.screenFrame.contains(mouse) }
            ?? NSScreen.screens.first.flatMap { displayPanels[ScreenIdentifier(screen: $0)] }
        guard let context else { return }
        let state = context.state
        if state.expanded {
            state.pinned = false; state.expanded = false
            context.window.ignoresMouseEvents = true
            context.hovering = false; context.hoverChangedAt = Date()
        } else {
            state.pinned = true; context.pinnedAt = Date(); context.pinnedMouseSeen = false
            state.expanded = true; context.window.ignoresMouseEvents = false
        }
    }

    /// A swipe belongs only to the panel receiving the event.
    private func handleScroll(_ event: NSEvent) {
        guard let context = displayPanels.values.first(where: { $0.window === event.window }) else { return }
        let state = context.state
        guard state.expanded, NJPSettings.swipeTabs, state.dashboardMode == .overview else { return }
        if event.phase == .began { context.swipeAccumulator = 0; context.swipeLocked = false }
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
            context.swipeAccumulator = 0; context.swipeLocked = false; return
        }
        let vertical = state.layout.anchor.isSide
        if vertical {
            let point = context.window.convertPoint(toScreen: event.locationInWindow)
            let frame = state.layout.contentFrame(size: state.activeExpandedSize)
            guard state.layout.anchor == .left ? point.x < frame.minX + 56 : point.x > frame.maxX - 56 else { return }
        }
        let delta = vertical ? event.scrollingDeltaY : event.scrollingDeltaX
        let cross = vertical ? event.scrollingDeltaX : event.scrollingDeltaY
        guard !context.swipeLocked, abs(delta) > abs(cross) else { return }
        context.swipeAccumulator += delta
        guard abs(context.swipeAccumulator) > 50 else { return }
        let tabs = PanelTabs.visible
        let position = tabs.firstIndex(of: state.page) ?? 0
        let next = tabs[min(tabs.count - 1, max(0, position + (context.swipeAccumulator < 0 ? 1 : -1)))]
        context.swipeAccumulator = 0; context.swipeLocked = true
        if next != state.page { withAnimation(.easeInOut(duration: 0.22)) { state.page = next } }
    }

    /// Approval beats an event about to start, which beats a finished run, which beats low disk.
    private func refreshAlerts(now: Date = Date()) {
        // Dictation is something you are doing right now, so it comes before everything else.
        if NJPSettings.dictationEnabled, DictationController.created, case let phase = DictationController.shared.phase, phase != .idle {
            state.alert = .dictation(phase)
            return
        }
        if NJPSettings.agentAlert, case let alert? = AgentActivityMonitor.shared.alert(now: now), case .agentApproval = alert {
            state.alert = alert
        } else if NJPSettings.privacyAlert,
                  SystemHealthService.shared.micInUse || SystemHealthService.shared.cameraInUse {
            state.alert = .privacy(mic: SystemHealthService.shared.micInUse, camera: SystemHealthService.shared.cameraInUse)
        } else if NJPSettings.eventAlert, let event = CalendarEventsService.shared.imminentEvent(now: now) {
            state.alert = .event(title: event.title, start: event.start)
        } else if case .finished(let at) = FocusTimerService.shared.state,
                  now.timeIntervalSince(at) < FocusTimerService.finishedWindow {
            state.alert = .timerDone
        } else if NJPSettings.agentAlert, let alert = AgentActivityMonitor.shared.alert(now: now) {
            state.alert = alert
        } else if case .running(let end, _) = FocusTimerService.shared.state {
            state.alert = .timer(end: end)
        } else if NJPSettings.diskAlert, let freeGB = SystemHealthService.shared.lowDiskGB() {
            state.alert = .lowDisk(freeGB: freeGB)
        } else if NJPSettings.nowPlayingAlert, state.playing, !state.track.isEmpty {
            state.alert = .nowPlaying(title: state.track)
        } else {
            state.alert = nil
        }
    }

    @objc private func screenParametersChanged() { configurePanel() }

    private func configurePanel() {
        // Mirrored displays may describe the same desktop rectangle; one window is enough there.
        var screens: [NSScreen] = []
        for screen in NSScreen.screens where !screens.contains(where: { $0.frame == screen.frame }) { screens.append(screen) }
        guard let primary = screens.first else {
            for context in displayPanels.values { context.window.close() }
            displayPanels.removeAll(); return
        }
        let connected = Set(screens.map { ScreenIdentifier(screen: $0) })
        for id in Array(displayPanels.keys) where !connected.contains(id) {
            displayPanels.removeValue(forKey: id)?.window.close()
        }
        for screen in screens {
            let id = ScreenIdentifier(screen: screen)
            let anchor = DashboardAnchor.resolve(screen: screen.frame, primary: primary.frame)
            let layout = DashboardLayout(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                notchSize: screen.notchSize, hasNotch: screen.hasNotch && anchor == .topCenter, anchor: anchor, sideDrawer: DisplayPanelPreferences.usesDrawer(on: screen))
            let context: DashboardScreenPanel
            if let existing = displayPanels[id] { context = existing }
            else {
                // Settings retain the canonical state; every display shares its content and controllers.
                let displayState = NotchState(airController: state.airController, tvController: state.tvController,
                                              content: state.content, home: state.home)
                let window = DashboardNotchPanel(contentRect: layout.windowFrame, styleMask: [.borderless, .nonactivatingPanel],
                                                backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.level = .mainMenu + 3
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
                window.ignoresMouseEvents = true
                let host = NSHostingView(rootView: BlackNotchView(state: displayState))
                host.sizingOptions = []
                window.contentView = host
                context = DashboardScreenPanel(state: displayState, window: window)
                displayPanels[id] = context
            }
            context.state.layout = layout
            // Reset transient hover/pinning after a monitor is moved or rescaled.
            context.state.expanded = false; context.state.pinned = false
            context.state.airDirection = nil; context.state.eventDetail = nil; context.state.dayListOpen = false
            context.hovering = false; context.pinnedMouseSeen = false
            context.window.ignoresMouseEvents = true
            context.window.setFrame(layout.windowFrame, display: true)
            context.window.orderFrontRegardless()
        }
    }

    private func startInteractionTimers() {
        guard timer == nil, serviceTimer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        serviceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleServices() }
        }
        serviceTimer?.tolerance = 0.2
    }

    private func refreshVisibleServices() {
        guard !sleeping else { return }
        let now = Date()
        let expanded = displayPanels.values.filter { $0.state.expanded }
        if !expanded.isEmpty && now.timeIntervalSince(lastRouterRefresh) >= 300 {
            lastRouterRefresh = now
            Task {
                async let openAI: Void = OpenAICreditBalanceService.shared.refresh()
                async let router: Void = refreshRouter(state)
                async let runpod: Void = refreshRunpod(state)
                _ = await (openAI, router, runpod)
            }
        }
        let musicVisible = expanded.contains { $0.state.page == 0 }
        if now.timeIntervalSince(lastSpotifyRefresh) >= (musicVisible ? 3 : 8), musicVisible || NJPSettings.nowPlayingAlert {
            lastSpotifyRefresh = now; SpotifyService.refresh(state)
        }
    }

    private func updateHover() {
        guard !sleeping, NJPSettings.expandOnHover || displayPanels.values.contains(where: { $0.state.expanded }) else { return }
        let now = Date()
        let mouse = NSEvent.mouseLocation
        for context in displayPanels.values { updateHover(context, mouse: mouse, now: now) }
    }

    private func updateHover(_ context: DashboardScreenPanel, mouse: CGPoint, now: Date) {
        let state = context.state
        let size = state.expanded ? state.activeExpandedSize : state.collapsedDisplaySize
        let area = state.layout.contentFrame(size: size).insetBy(dx: -8, dy: -8)
        let inside = state.layout.screenFrame.contains(mouse) && area.contains(mouse)
        if state.pinned {
            if inside { context.pinnedMouseSeen = true }
            else if context.pinnedMouseSeen || now.timeIntervalSince(context.pinnedAt) > 8 {
                state.pinned = false; context.pinnedMouseSeen = false
            }
        }
        let editing = state.expanded && (state.home.editorOpen || ResidentialDeviceNames.shared.isEditing)
        let isHovering = (NJPSettings.expandOnHover && inside) || (state.expanded && inside) || state.pinned
            || editing || state.airDirection != nil || state.eventDetail != nil || state.dayListOpen || context.window.attachedSheet != nil
        if isHovering != context.hovering {
            context.hovering = isHovering; context.hoverChangedAt = now
        }
        state.collapsedHovered = inside && !state.expanded
        let delay: TimeInterval = state.layout.isExternal ? (context.hovering ? 0.09 : 0.35) : (context.hovering ? NJPSettings.hoverDelay : 0.5)
        if context.hovering != state.expanded && now.timeIntervalSince(context.hoverChangedAt) >= delay {
            state.expanded = context.hovering
        }
        context.window.ignoresMouseEvents = !state.expanded
    }

}
#if DEBUG
extension AppDelegate {
    private func renderResidentialPreview(to path: String, overviewPage: Int? = nil) {
        let disconnected = CommandLine.arguments.contains("--preview-disconnected")
        let backend = ResidentialPreviewBackend(disconnected: disconnected)
        let controller = ACController(backend: backend, initialState: disconnected ? nil : backend.value)
        if CommandLine.arguments.contains("--preview-devices") {
            func make(_ temperature: Double, power: Bool) -> ACState {
                var value = backend.value
                value.temperature = temperature
                value.power = power
                return value
            }
            controller.previewLoad(
                devices: [ACDeviceInfo(id: "jp", name: "Meu quarto", online: true),
                          ACDeviceInfo(id: "mae", name: "Quarto da mamãe", online: true),
                          ACDeviceInfo(id: "sala", name: "Sala", online: false)],
                states: ["jp": make(24, power: true), "mae": make(26, power: true)],
                selected: "jp")
        }
        let previewTV = LGTVController(store: LGTVPairingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), preview: !disconnected)
        let preview = NotchState(airController: controller, tvController: previewTV)
        if CommandLine.arguments.contains("--preview-devices") { preview.page = 0; preview.residentialDevice = .air }
        preview.expanded = true
        preview.dashboardMode = overviewPage == nil ? .residential : .overview
        if let overviewPage { preview.page = max(0, min(6, overviewPage)) }
        if overviewPage == 0 {
            preview.track = CommandLine.arguments.contains("--preview-long-title")
                ? "Uma faixa com um título bem comprido para conferir o espaço de leitura" : AppLanguage.text("Faixa em reprodução")
            preview.artist = "Artista"
            preview.position = 61
            preview.duration = 178
        }
        if CommandLine.arguments.contains("--preview-tv") { preview.residentialDevice = .tv }
        if CommandLine.arguments.contains("--preview-scenes") { preview.residentialDevice = .scenes }
        if CommandLine.arguments.contains("--preview-tint") { preview.artworkTint = Color(red: 0.55, green: 0.35, blue: 0.9) }
        if CommandLine.arguments.contains("--preview-collapsed-alert") {
            preview.expanded = false
            preview.alert = .event(title: "Daily do time", start: Date().addingTimeInterval(12 * 60 - 20))
        }
        if CommandLine.arguments.contains("--preview-disk-alert") {
            preview.expanded = false
            preview.alert = .lowDisk(freeGB: 18)
        }
        let previewWidth = previewArgument("--preview-screen-width").flatMap(Double.init) ?? 1440
        let previewHeight = previewArgument("--preview-screen-height").flatMap(Double.init) ?? 900
        let previewNotchWidth = previewArgument("--preview-notch-width").flatMap(Double.init) ?? 188
        let previewNotchHeight = previewArgument("--preview-notch-height").flatMap(Double.init) ?? 32
        let previewFrame = CGRect(x: 0, y: 0, width: previewWidth, height: previewHeight)
        let anchorName = previewArgument("--preview-anchor")
        let anchor: DashboardAnchor = anchorName == "left" ? .left : (anchorName == "right" ? .right : .topCenter)
        preview.layout = DashboardLayout(screenFrame: previewFrame, visibleFrame: previewFrame,
                                         notchSize: CGSize(width: previewNotchWidth, height: previewNotchHeight), hasNotch: anchorName == nil, anchor: anchor)
        let host = NSHostingView(rootView: BlackNotchView(state: preview))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: preview.expanded ? preview.layout.windowFrame.size : CGSize(width: preview.collapsedDisplaySize.width, height: preview.collapsedDisplaySize.height + 8))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        if CommandLine.arguments.contains("--preview-live") {
            // Native behind-window materials need a real composited window for visual QA.
            let background = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 550), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            background.title = "notchJP · QA de contraste"
            let bright = !CommandLine.arguments.contains("--preview-dark-background")
            background.contentView = NSHostingView(rootView:
                ZStack {
                    (bright ? Color.white : Color.black)
                    HStack(spacing: 30) {
                        ForEach(0..<7) { index in
                            Rectangle().fill(index.isMultiple(of: 2) ? Color.blue.opacity(0.25) : Color.orange.opacity(0.25)).frame(width: 60)
                        }
                    }
                })
            background.center()
            background.orderFrontRegardless()
            window.styleMask = [.titled, .closable]
            window.title = "Painel notchJP · QA"
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: .darkAqua)
            window.setFrameOrigin(NSPoint(x: background.frame.midX - host.frame.width / 2, y: background.frame.midY - host.frame.height / 2))
            window.makeKeyAndOrderFront(nil)
            qaWindows = [background, window]
            NSApp.activate()
            return
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: path)); exit(0) }
        catch { exit(1) }
    }

    private func renderEventPreview(to path: String) {
        let start = Date().addingTimeInterval(3600)
        let event = CalendarEventItem(
            id: "p", title: "Daily do time", start: start, end: start.addingTimeInterval(900), isAllDay: false,
            color: NJP.accent, joinURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            location: "Sala 3 · Prédio Central", notes: "Pauta: andamento da sprint, bloqueios e próximos passos. Levar o relatório de ontem.",
            calendarName: "Trabalho")
        let list = DayEventsListView(day: start, events: [event, event, event]) { _ in }
        let view = HStack(alignment: .top, spacing: 16) { EventDetailView(event: event); list }
            .padding(16).background(Color.black)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: path)); exit(0) }
        catch { exit(1) }
    }

    private func renderSettingsPreview(to path: String) {
        let host = NSHostingView(rootView: DashboardSettingsView(state: NotchState()))
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: path)); exit(0) }
        catch { exit(1) }
    }

    private func previewArgument(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }
}

@MainActor
private final class ResidentialPreviewBackend: ACBackend {
    let name = "Prévia TCL Home"
    let disconnected: Bool
    init(disconnected: Bool) { self.disconnected = disconnected }
    var value = ACState(power: true, temperature: 24, roomTemperature: 27,
                        eco: true, mode: .cool, fan: .auto, sleep: false, airflow: .vertical,
                        deviceName: AppLanguage.text("Ar-condicionado"), verticalDirection: .swingAll,
                        horizontalDirection: .middle, breeze: false)
    func configure(email: String, password: String, region: String) async throws { }
    func readState() async throws -> ACState {
        if disconnected { throw TCLBackendError(AppLanguage.text("Conecte sua conta TCL Home para controlar o ar.")) }
        return value
    }
    func perform(_ command: ACCommand) async throws -> ACState { value }
}
#endif
