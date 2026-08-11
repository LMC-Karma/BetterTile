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
