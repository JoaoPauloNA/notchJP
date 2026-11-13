import SwiftUI

/// Preferences of the notchJP panel (the original Notchi settings live in AppSettings).
enum NJPSettings {
    static let pageCount = 7
    static let accentIndexKey = "njp.accentIndex"
    static let expandOnHoverKey = "njp.expandOnHover"
    static let hoverDelayKey = "njp.hoverDelay"
    static let rememberPageKey = "njp.rememberPage"
    static let lastPageKey = "njp.lastPage"
    static let swipeTabsKey = "njp.swipeTabs"
    static let shortcutEnabledKey = "njp.shortcutEnabled"
    static let eventAlertKey = "njp.eventAlert"
    static let diskAlertKey = "njp.diskAlert"
    static let agentAlertKey = "njp.agentAlert"

    static var accentPalette: [(name: String, color: Color)] { [
        (AppLanguage.text("Laranja"), Color(red: 0.78, green: 0.39, blue: 0.23)),
        (AppLanguage.text("Azul"), Color(red: 0.30, green: 0.55, blue: 0.95)),
        (AppLanguage.text("Verde"), Color(red: 0.30, green: 0.70, blue: 0.45)),
        (AppLanguage.text("Roxo"), Color(red: 0.62, green: 0.45, blue: 0.95)),
        (AppLanguage.text("Rosa"), Color(red: 0.92, green: 0.38, blue: 0.62)),
        (AppLanguage.text("Amarelo"), Color(red: 0.85, green: 0.68, blue: 0.20)),
    ] }

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static var accentIndex: Int {
        let stored = UserDefaults.standard.integer(forKey: accentIndexKey)
        return accentPalette.indices.contains(stored) ? stored : 0
    }

    static var expandOnHover: Bool { bool(expandOnHoverKey, default: true) }
    static var rememberPage: Bool { bool(rememberPageKey, default: true) }
    static var swipeTabs: Bool { bool(swipeTabsKey, default: true) }
    static var shortcutEnabled: Bool { bool(shortcutEnabledKey, default: true) }
    static var eventAlert: Bool { bool(eventAlertKey, default: true) }
    static var diskAlert: Bool { bool(diskAlertKey, default: true) }
    static var agentAlert: Bool { bool(agentAlertKey, default: true) }

    /// Seconds the pointer must rest on the notch before the panel opens.
    static var hoverDelay: Double {
        let stored = UserDefaults.standard.double(forKey: hoverDelayKey)
        return stored > 0 ? stored : 0.3
    }

    static var initialPage: Int {
        guard rememberPage else {
            let chosen = UserDefaults.standard.integer(forKey: PanelTabs.openingKey)
            return PanelTabs.visible.contains(chosen) ? chosen : PanelTabs.visible[0]
        }
        let page = UserDefaults.standard.integer(forKey: lastPageKey)
        return PanelTabs.visible.contains(page) ? page : PanelTabs.visible[0]
    }
}

extension Notification.Name {
    /// Posted by the settings screens so the app can start or stop shortcuts and listeners.
    static let njpSettingsChanged = Notification.Name("njp.settingsChanged")
}

extension NJPSettings {
    static let clipboardHistoryKey = "njp.clipboardHistory"
    static let nowPlayingAlertKey = "njp.nowPlayingAlert"
    static let privacyAlertKey = "njp.privacyAlert"
    static let toolsSectionKey = "njp.toolsSection"
    static let projectShortcutsKey = "njp.projectShortcuts"
    static let fileShelfKey = "njp.fileShelf"

    /// Off by default: it records what you copy (in memory only).
    static var clipboardHistory: Bool { bool(clipboardHistoryKey, default: false) }
    static var nowPlayingAlert: Bool { bool(nowPlayingAlertKey, default: true) }
    static var privacyAlert: Bool { bool(privacyAlertKey, default: true) }
}

extension NJPSettings {
    static let dictationEnabledKey = "njp.dictationEnabled"
    /// Off until the user turns it on: BlabberType may still be running with the same shortcut.
    static var dictationEnabled: Bool { bool(dictationEnabledKey, default: false) }
}
