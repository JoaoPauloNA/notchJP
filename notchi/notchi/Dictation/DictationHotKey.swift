import AppKit
import Carbon

/// Registers the dictation shortcut and forwards press and release to the model (hold to talk).
@MainActor
final class DictationHotKey {
    private weak var model: DictationModel?
    private let registration = DictationShortcutRegistration()
    private var handler: EventHandlerRef?

    func install(model: DictationModel) {
        self.model = model
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else { return OSStatus(eventNotHandledErr) }
            // Other shortcuts of the app (the panel toggle) must reach their own handler.
            guard identifier.signature == DictationShortcutRegistration.signature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<DictationHotKey>.fromOpaque(context).takeUnretainedValue()
            let received = identifier
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                guard owner.registration.matches(received) else { return }
                if pressed { owner.model?.shortcutPressed() } else { owner.model?.shortcutReleased() }
            }
            return noErr
        }, events.count, &events, pointer, &handler)
        guard installed == noErr else { model.shortcutStatus = "Atalho indisponível · use o botão Gravar"; return }
        model.checkShortcut = { [weak self] shortcut in
            guard let self else { throw DictationShortcutError.unavailable }
            try self.registration.check(shortcut)
        }
        model.changeShortcut = { [weak self, weak model] shortcut in
            guard let self, let model else { throw DictationShortcutError.unavailable }
            try self.registration.replace(with: shortcut) { try model.persistShortcut(shortcut) }
            model.shortcutStatus = shortcut.displayName
        }
        do {
            try registration.replace(with: model.settings.shortcut, persist: { })
            model.shortcutStatus = model.settings.shortcut.displayName
        } catch {
            model.shortcutStatus = "Atalho indisponível · use o botão Gravar"
            model.error = "\(error.localizedDescription) Escolha outro em Ajustes > Ditado."
        }
    }

    func uninstall() {
        model?.cancel()
        registration.stop()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
