import AppKit
import SwiftUI
import Combine
import CoreGraphics

struct ResolutionMode: Identifiable, Equatable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refresh: Int // hundredths of Hz; zero means system-managed
    var id: String { "\(width)x\(height):\(pixelWidth)x\(pixelHeight):\(refresh)" }
    var title: String {
        var text = "\(width) × \(height)"
        if pixelWidth > width { text += " · HiDPI" }
        if refresh > 0 { text += " · \(String(format: "%g", Double(refresh) / 100)) Hz" }
        return text
    }
    init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refresh: Int) {
        self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.refresh = refresh
    }
    init(_ mode: CGDisplayMode) {
        self.init(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                  pixelHeight: mode.pixelHeight, refresh: Int((mode.refreshRate * 100).rounded()))
    }
    static func ordered(_ modes: [ResolutionMode]) -> [ResolutionMode] {
        var seen = Set<String>()
        return modes.filter { seen.insert($0.id).inserted }.sorted {
            if $0.width != $1.width { return $0.width < $1.width }
            if $0.height != $1.height { return $0.height < $1.height }
            if $0.pixelWidth != $1.pixelWidth { return $0.pixelWidth > $1.pixelWidth }
            if $0.pixelHeight != $1.pixelHeight { return $0.pixelHeight > $1.pixelHeight }
            return $0.refresh > $1.refresh
        }
    }
}

struct ResolutionScreen: Identifiable {
    let id: String // persistent display UUID, not transient display ID or screen order
    let name: String
    let modes: [ResolutionMode]
    let current: ResolutionMode?
    let mirrored: Bool
}

@MainActor protocol DisplayResolutionBackend {
    func screens() -> [ResolutionScreen]
    func apply(screen: String, mode: ResolutionMode) throws
}

private struct ResolutionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor final class CoreGraphicsResolutionBackend: DisplayResolutionBackend {
    // Avoid Swift isolated-deinit back-deployment crashes (swiftlang/swift#88036).
    nonisolated deinit {}
    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
    private func identifier(_ display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    private func modes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? [])
            .filter { $0.isUsableForDesktopGUI() && $0.width > 0 && $0.height > 0 }
    }
    func screens() -> [ResolutionScreen] {
        NSScreen.screens.compactMap { screen in
            guard let display = displayID(screen), let uuid = identifier(display) else { return nil }
            return ResolutionScreen(id: uuid, name: screen.localizedName,
                                    modes: ResolutionMode.ordered(modes(display).map(ResolutionMode.init)),
                                    current: CGDisplayCopyDisplayMode(display).map(ResolutionMode.init),
                                    mirrored: CGDisplayIsInMirrorSet(display) != 0)
        }
    }
    func apply(screen: String, mode: ResolutionMode) throws {
        guard let display = NSScreen.screens.compactMap(displayID).first(where: { identifier($0) == screen }) else {
            throw ResolutionError(message: "A tela foi desconectada. Reconecte e tente novamente.")
        }
        guard CGDisplayIsInMirrorSet(display) == 0 else {
            throw ResolutionError(message: "Desative o espelhamento nos Ajustes do macOS para alterar somente esta tela.")
        }
        guard let native = modes(display).first(where: { ResolutionMode($0) == mode }) else {
            throw ResolutionError(message: "Esta resolução não está mais disponível para a tela.")
        }
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else {
            throw ResolutionError(message: "Não foi possível iniciar a alteração (\(begin.rawValue)).")
        }
        let result = CGConfigureDisplayWithDisplayMode(configuration, display, native, nil)
        guard result == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw ResolutionError(message: "O macOS recusou a resolução (\(result.rawValue)).")
        }
        let complete = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard complete == .success else {
            throw ResolutionError(message: "Não foi possível aplicar a resolução (\(complete.rawValue)).")
        }
    }
}

@MainActor final class DisplayResolutionService: ObservableObject {
    // Avoid Swift isolated-deinit back-deployment crashes (swiftlang/swift#88036).
    nonisolated deinit {}
    static let shared = DisplayResolutionService(backend: CoreGraphicsResolutionBackend(), observe: true)
    static let favoritesKey = "njp.displayResolution.favorites"
    @Published private(set) var screens: [ResolutionScreen] = []
    @Published private(set) var favorites: [String: [String]]
    @Published private(set) var pendingScreen: String?
    @Published private(set) var deadline: Date?
    @Published private(set) var error: String?
    private var previous: ResolutionMode?
    private let backend: any DisplayResolutionBackend
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    private var rollback: DispatchWorkItem?
    private var confirmation: NSWindow?
    private let rollbackDelay: TimeInterval

    init(backend: any DisplayResolutionBackend, defaults: UserDefaults = .standard, observe: Bool = false, rollbackDelay: TimeInterval = 15) {
        self.backend = backend; self.defaults = defaults
        self.rollbackDelay = rollbackDelay
        favorites = defaults.dictionary(forKey: Self.favoritesKey) as? [String: [String]] ?? [:]
        refresh()
        if observe {
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }
    func refresh() { screens = backend.screens() }
    func isFavorite(_ mode: ResolutionMode, screen: String) -> Bool { favorites[screen]?.contains(mode.id) == true }
    func setFavorite(_ mode: ResolutionMode, screen: String, enabled: Bool) {
        guard screens.contains(where: { $0.id == screen && $0.modes.contains(mode) }) else { return }
        var saved = favorites[screen] ?? []
        saved.removeAll { $0 == mode.id }
        if enabled { saved.append(mode.id) }
        favorites[screen] = saved
        defaults.set(favorites, forKey: Self.favoritesKey)
    }
    func selectedModes(_ screen: ResolutionScreen) -> [ResolutionMode] {
        screen.modes.filter { isFavorite($0, screen: screen.id) }
    }
    func apply(_ mode: ResolutionMode, screen id: String, presentConfirmation: Bool = true) {
        guard pendingScreen == nil else { return }
        refresh(); error = nil
        guard let screen = screens.first(where: { $0.id == id }), let old = screen.current,
              screen.modes.contains(mode), !screen.mirrored else {
            error = "A tela ou a resolução está indisponível. Verifique também se há espelhamento ativo."
            return
        }
        guard old != mode else { return }
        do {
            try backend.apply(screen: id, mode: mode)
            previous = old; pendingScreen = id; deadline = Date().addingTimeInterval(rollbackDelay)
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.revert() } }
            rollback = work
            DispatchQueue.main.asyncAfter(deadline: .now() + rollbackDelay, execute: work)
            refresh()
            if presentConfirmation { showConfirmation() }
        } catch { self.error = error.localizedDescription; refresh() }
    }
    func keep() { clearPending(); refresh() }
    func revert() {
        guard let id = pendingScreen, let previous else { return }
        do { try backend.apply(screen: id, mode: previous); error = nil }
        catch { self.error = "Não foi possível restaurar a resolução: \(error.localizedDescription)" }
        clearPending(); refresh()
    }
    private func clearPending() {
        rollback?.cancel(); rollback = nil
        pendingScreen = nil; previous = nil; deadline = nil
        confirmation?.close(); confirmation = nil
    }
    private func showConfirmation() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 155), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Resolução da tela"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: ResolutionConfirmationView(service: self))
        confirmation = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
    }
}
