import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test @MainActor func titleBarDoubleClickAdmissionHonorsApplicationRules() {
    let system = FakeWindowSystem()
    let window = system.windows[0]
    let controller = TitleBarDoubleClickController(
        coordinator: WindowCoordinator(system: system)
    )

    #expect(controller.allowsDoubleClickPlacement(for: window))

    var rules = ApplicationRuleSet()
    rules.set(.excludeFromBento, for: "com.example.Test")
    controller.applicationRules = rules
    #expect(controller.allowsDoubleClickPlacement(for: window))

    rules.set(.ignoreEverywhere, for: "com.example.Test")
    controller.applicationRules = rules
    #expect(!controller.allowsDoubleClickPlacement(for: window))
}

@Test(arguments: ["stop", "restart", "configuration"]) @MainActor
func queuedDoubleClickCannotWriteAfterMonitorRetirement(retirement: String) async throws {
    let system = FakeWindowSystem()
    let original = system.windows[0].frame
    let controller = TitleBarDoubleClickController(coordinator: WindowCoordinator(system: system))
    var callback: ((NSEvent) -> Void)?
    controller.addGlobalMonitor = { _, handler in callback = handler; return NSObject() }
    controller.removeEventMonitor = { _ in }
    controller.systemDoubleClickActionIsDisabled = { true }
    controller.pointerLocation = { BTPoint(x: original.midX, y: original.minY + 10) }
    controller.start()
    defer { controller.stop() }
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 1,
                                               windowNumber: 0, context: nil, eventNumber: 7, clickCount: 2, pressure: 0))
    #expect(callback != nil)
    callback?(event)
    if retirement == "configuration" {
        controller.isEnabled = false
        controller.isEnabled = true
    } else {
        controller.stop()
        if retirement == "restart" { controller.start() }
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(system.frameWriteCounts.isEmpty)
    #expect(system.windows[0].frame == original)
    if retirement != "stop" {
        #expect(callback != nil)
        callback?(event)
        for _ in 0..<20 { await Task.yield() }
        #expect(system.windows[0].frame == system.displays()[0].visibleFrame)
    }
}
