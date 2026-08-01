import BetterTileCore
import Carbon.HIToolbox

private let betterTileHotKeySignature: OSType = 0x4254_5343 // 'BTSC'

@MainActor
public final class GlobalShortcutMonitor {
    private var bindings: [ShortcutBinding] = []
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var isSuspended = false
    private var handler: (WindowAction) -> Void

    public init(handler: @escaping (WindowAction) -> Void) {
        self.handler = handler
    }

    public func setHandler(_ handler: @escaping (WindowAction) -> Void) {
        self.handler = handler
    }

    public func update(bindings: [ShortcutBinding]) {
        self.bindings = bindings
        guard !isSuspended else { return }
        registerHotKeys()
    }

    public func suspend() {
        isSuspended = true
        unregisterHotKeys()
    }

    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        registerHotKeys()
    }

    public func stop() {
        unregisterHotKeys()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    static func action(forHotKeyID id: UInt32) -> WindowAction? {
        guard id > 0 else { return nil }
        let index = Int(id - 1)
        guard WindowAction.allCases.indices.contains(index) else { return nil }
        return WindowAction.allCases[index]
    }

    private func registerHotKeys() {
        unregisterHotKeys()
        guard installEventHandlerIfNeeded() else { return }

        for (index, action) in WindowAction.allCases.enumerated() {
            guard let shortcut = bindings.first(where: { $0.action == action })?.shortcut else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers.carbonFlags,
                EventHotKeyID(signature: betterTileHotKeySignature, id: id),
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs[id] = ref
            }
        }
    }

    private func installEventHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            betterTileHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )
        guard status == noErr, let installedHandler else { return false }
        eventHandler = installedHandler
        return true
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    fileprivate func handleHotKey(id: UInt32) {
        guard hotKeyRefs[id] != nil, let action = Self.action(forHotKeyID: id) else { return }
        handler(action)
    }
}

private func betterTileHotKeyHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr, id.signature == betterTileHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
    let hotKeyID = id.id
    DispatchQueue.main.async {
        monitor.handleHotKey(id: hotKeyID)
    }
    return noErr
}

extension ShortcutModifiers {
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
