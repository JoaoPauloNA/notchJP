import Carbon.HIToolbox
import Foundation

@MainActor final class HomeSceneShortcuts {
    nonisolated static let signature: OSType = 0x4e4a5053
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    private var ids: [UInt32: String] = [:]
    private let action: (String) -> Void
    init(action: @escaping (String) -> Void) { self.action = action }
    static func shortcut(slot: Int) -> GlobalShortcut? {
        let codes: [UInt32] = [18,19,20,21,23,22,26,28,25]
        guard (1...9).contains(slot) else { return nil }
        return GlobalShortcut(keyCode: codes[slot - 1], modifiers: UInt32(controlKey | optionKey | cmdKey))
    }
    func reload(_ scenes: [HomeScene]) -> [String] {
        stop()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
                  key.signature == HomeSceneShortcuts.signature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HomeSceneShortcuts>.fromOpaque(context).takeUnretainedValue()
            let id = key.id
            Task { @MainActor [weak owner] in
                guard let owner, let scene = owner.ids[id] else { return }
                owner.action(scene)
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return ["Não foi possível ativar os atalhos das cenas."] }
        var failures: [String] = []
        for (index, scene) in scenes.enumerated() {
            guard let raw = scene.shortcut else { continue }
            guard let key = GlobalShortcut(rawValue: raw), (1...9).contains(where: { Self.shortcut(slot: $0) == key }) else {
                failures.append("Atalho inválido para " + scene.name); continue
            }
            var reference: EventHotKeyRef?
            let id = UInt32(index + 1)
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            if status == noErr, let reference { refs.append(reference); ids[id] = scene.id }
            else { failures.append("Atalho de \(scene.name) indisponível; escolha outro nos ajustes da cena.") }
        }
        return failures
    }
    func stop() {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []; ids = [:]
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
