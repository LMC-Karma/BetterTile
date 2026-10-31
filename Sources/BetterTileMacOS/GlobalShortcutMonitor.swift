import BetterTileCore
import Carbon.HIToolbox

private let betterTileHotKeySignature: OSType = 0x4254_5343 // 'BTSC'

@MainActor
public final class GlobalShortcutMonitor {
    private var bindings: [ShortcutBinding] = []
    private var namedBindings: [String: KeyboardShortcut] = [:]
    private var namedIDs: [UInt32: String] = [:]
    private var nextNamedID = UInt32(WindowAction.allCases.count + 1)
    var registerHotKey: (UInt32, UInt32, EventHotKeyID, inout EventHotKeyRef?) -> OSStatus = { code, flags, id, ref in
        RegisterEventHotKey(code, flags, id, GetEventDispatcherTarget(), 0, &ref)
    }
    var unregisterHotKey: (EventHotKeyRef) -> Void = { UnregisterEventHotKey($0) }
    public var namedHandler: (String) -> Void = { _ in }
    public private(set) var failedNamedBindings: Set<String> = []
    public var namedRegistrationChanged: (Set<String>) -> Void = { _ in }
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    /// Transient: set while the user is recording a replacement shortcut.
    private var isSuspended = false
    /// The user's master switch. Independent of `isSuspended` so recording a
    /// shortcut cannot silently turn the feature back on, or off.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if canRegister { registerHotKeys() } else { unregisterHotKeys() }
        }
    }
    /// Bindings are retained whichever way both switches are set, so turning
    /// shortcuts back on restores exactly what was configured.
    var canRegister: Bool { isEnabled && !isSuspended }
    private var handler: (WindowAction) -> Void

    public init(handler: @escaping (WindowAction) -> Void) {
        self.handler = handler
    }

    // Carbon retains the handler with an unretained pointer to this monitor.
    // Retire it before that address can be reused by another monitor.
    isolated deinit { stop() }

    public func setHandler(_ handler: @escaping (WindowAction) -> Void) {
        self.handler = handler
    }

    public func update(bindings: [ShortcutBinding], named: [String: KeyboardShortcut] = [:]) {
        namedIDs = namedIDs.filter { _, file in
            guard let old = namedBindings[file], let new = named[file] else { return false }
            return old.keyCode == new.keyCode && old.modifiers == new.modifiers
        }
        namedBindings = named
        self.bindings = bindings
        guard canRegister else { return }
        registerHotKeys()
    }

    public func suspend() {
        isSuspended = true
        unregisterHotKeys()
    }

    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        guard canRegister else { return }
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
        failedNamedBindings = []
        defer { namedRegistrationChanged(failedNamedBindings) }
        guard installEventHandlerIfNeeded() else {
            failedNamedBindings = Set(namedBindings.keys)
            return
        }
        for file in namedBindings.keys.sorted() {
            let id: UInt32
            if let existing = namedIDs.first(where: { $0.value == file })?.key { id = existing }
            else { id = nextNamedID; nextNamedID += 1 }
            namedIDs[id] = file
            var ref: EventHotKeyRef?
            let key = namedBindings[file]!
            let status = registerHotKey(key.keyCode, key.modifiers.carbonFlags,
                EventHotKeyID(signature: betterTileHotKeySignature, id: id), &ref)
            if status == noErr, let ref { hotKeyRefs[id] = ref }
            else { failedNamedBindings.insert(file) }
        }
        for (index, action) in WindowAction.allCases.enumerated() {
            guard let shortcut = bindings.first(where: { $0.action == action })?.shortcut else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = registerHotKey(shortcut.keyCode, shortcut.modifiers.carbonFlags,
                EventHotKeyID(signature: betterTileHotKeySignature, id: id), &ref)
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
            unregisterHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    func handleHotKey(id: UInt32) {
        guard hotKeyRefs[id] != nil else { return }
        if let file = namedIDs[id] { namedHandler(file) }
        else if let action = Self.action(forHotKeyID: id) { handler(action) }
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
