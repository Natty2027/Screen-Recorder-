import Carbon.HIToolbox

/// System-wide keyboard shortcuts that work even when another app is in front.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    private init() {}

    /// Registers a global shortcut. `modifiers` uses Carbon flags such as `cmdKey | optionKey`.
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5352_4543), id: id) // 'SREC'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &reference)
        if status == noErr {
            actions[id] = action
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.actions[id]?() }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
