import Carbon.HIToolbox
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test(.macOSTestApplication) func carbonModifierFlagsMatchConfiguredShortcutModifiers() {
    let allModifiers: ShortcutModifiers = [.control, .option, .shift, .command]

    #expect(ShortcutModifiers.control.carbonFlags == UInt32(controlKey))
    #expect(ShortcutModifiers.option.carbonFlags == UInt32(optionKey))
    #expect(
        allModifiers.carbonFlags
            == UInt32(controlKey | optionKey | shiftKey | cmdKey)
    )
}

@Test(.macOSTestApplication) @MainActor func hotKeyIDsRoundTripEveryWindowAction() {
    for (index, action) in WindowAction.allCases.enumerated() {
        #expect(GlobalShortcutMonitor.action(forHotKeyID: UInt32(index + 1)) == action)
    }
    #expect(GlobalShortcutMonitor.action(forHotKeyID: 0) == nil)
    #expect(GlobalShortcutMonitor.action(forHotKeyID: UInt32(WindowAction.allCases.count + 1)) == nil)
}

@Test(.macOSTestApplication) @MainActor func shortcutMasterSwitchStaysIndependentFromRecordingSuspension() {
    let monitor = GlobalShortcutMonitor { _ in }
    defer { monitor.stop() }

    #expect(monitor.canRegister)
    monitor.suspend()
    #expect(!monitor.canRegister)

    monitor.isEnabled = false
    monitor.resume()
    #expect(!monitor.canRegister)

    monitor.suspend()
    monitor.isEnabled = true
    #expect(!monitor.canRegister)
    monitor.resume()
    #expect(monitor.canRegister)
}

@Test(.macOSTestApplication) @MainActor func namedHotKeysDispatchOnceAndRetiredIDsNeverTargetAnotherLayout() {
    let monitor = GlobalShortcutMonitor { _ in }
    var allocated: [String: UInt32] = [:]
    var latestIDs: [UInt32] = []
    monitor.registerHotKey = { _, _, id, ref in
        latestIDs.append(id.id); ref = EventHotKeyRef(bitPattern: Int(id.id)); return noErr
    }
    monitor.unregisterHotKey = { _ in }
    defer { monitor.stop() }
    var calls: [String] = []
    monitor.namedHandler = { calls.append($0) }
    let key = KeyboardShortcut(keyCode: 18, modifiers: [.control, .option], keyLabel: "1")
    monitor.update(bindings: [], named: ["first.json": key])
    allocated["first"] = latestIDs.last
    monitor.handleHotKey(id: latestIDs.last!)
    #expect(calls == ["first.json"])
    monitor.update(bindings: [], named: ["second.json": key])
    let second = latestIDs.last!
    #expect(second > allocated["first"]!)
    monitor.handleHotKey(id: allocated["first"]!)
    #expect(calls == ["first.json"])
    monitor.handleHotKey(id: second)
    #expect(calls == ["first.json", "second.json"])
    monitor.suspend(); monitor.handleHotKey(id: second)
    #expect(calls.count == 2)
    monitor.resume(); monitor.handleHotKey(id: latestIDs.last!)
    #expect(calls.count == 3)
    monitor.isEnabled = false; monitor.handleHotKey(id: latestIDs.last!)
    #expect(calls.count == 3)
}

@Test(.macOSTestApplication) @MainActor func namedHotKeyRegistrationFailureIsReportedWithoutDispatch() {
    let monitor = GlobalShortcutMonitor { _ in }
    var id: UInt32 = 0
    monitor.registerHotKey = { _, _, key, _ in id = key.id; return OSStatus(eventHotKeyExistsErr) }
    monitor.unregisterHotKey = { _ in }
    defer { monitor.stop() }
    var calls = 0; monitor.namedHandler = { _ in calls += 1 }
    monitor.update(bindings: [], named: ["one.json": .init(keyCode: 18, modifiers: [.control, .option], keyLabel: "1")])
    #expect(monitor.failedNamedBindings == ["one.json"])
    monitor.handleHotKey(id: id)
    #expect(calls == 0)
}
