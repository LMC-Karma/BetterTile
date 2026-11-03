import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor private final class LiveTriagePresenter: LayoutWheelPresenting {
    var latest: LayoutWheelPresentation?
    func open(_ presentation: LayoutWheelPresentation) { latest = presentation }
    func update(_ presentation: LayoutWheelPresentation) { latest = presentation }
    func showPlacements(_ placements: [Placement]) {}
    func hidePlacements() {}
    func close() {}
}

@MainActor private final class LiveTriageWheel {
    let presenter = LiveTriagePresenter()
    var pointer: BTPoint
    var time = 100.0
    var commits: [LayoutWheelCommand] = []
    let origin: BTPoint
    var controller: LayoutWheelController!

    init(style: LayoutWheelStyle, origin: BTPoint = BTPoint(x: 700, y: 400), hasWindow: Bool = true) {
        self.origin = origin
        pointer = origin
        controller = LayoutWheelController(
            configuration: .init(layoutWheel: .init(style: style, levelCount: .two)),
            presenter: presenter, now: { [unowned self] in time },
            pointerProvider: { [unowned self] in pointer },
            addGlobalMonitor: { _, _ in NSObject() },
            addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.captureHandler = { _ in
            LayoutWheelTarget(windowID: hasWindow ? WindowID(rawValue: "fixture") : nil,
                displayID: DisplayID(rawValue: "display"),
                visibleFrame: BTRect(x: 0, y: 30, width: 1920, height: 971), layoutMode: .bento)
        }
        controller.previewHandler = { _, _ in .ready(placements: []) }
        controller.commitHandler = { [unowned self] command, _ in commits.append(command) }
        controller.start()
        controller.handleModifiers([.control, .option, .shift])
        controller.handleActivationDeadline(generation: 1)
    }

    func move(_ vector: BTPoint, at elapsed: Double) {
        time = 100 + elapsed
        pointer = BTPoint(x: origin.x + vector.x, y: origin.y + vector.y)
        controller.handlePointer(pointer)
    }
}

// Reconstruct the helper's recorded path, not an OS event trace: 24 linear
// samples from (700,400) to (661,361), then a repeated endpoint. The failed
// live run recorded 133.162 ms between movement and release. Deliberately stop
// delivery at sample 11 while the pointer itself has reached the endpoint.
@Test(.macOSTestApplication, arguments: [LayoutWheelStyle.custom, .grouped]) @MainActor
func wheelLiveTriageReleaseOvertakesTopLeftPointerSamples(style: LayoutWheelStyle) {
    let wheel = LiveTriageWheel(style: style)
    defer { wheel.controller.stop() }
    for step in 1...11 {
        wheel.move(BTPoint(x: -39 * Double(step) / 24, y: -39 * Double(step) / 24),
                   at: Double(step) * 0.003)
    }
    // Sample 11 is 25.28 pt from the centre. It is inside the 32 pt well
    // for both styles; the 23 pt Custom hub selected this sample.
    #expect(wheel.presenter.latest?.selection == nil)
    wheel.pointer = BTPoint(x: 661, y: 361)
    wheel.time = 100.133162
    wheel.controller.handleModifiers([.control, .option])
    wheel.controller.handleModifiers([])
    // Both styles resample the final pointer at release, so the
    // overtaken Custom flick commits the sector under the final pointer.
    let expected: [LayoutWheelCommand] = [.windowAction(.topLeftQuarter)]
    #expect(wheel.commits == expected)
    // A queued movement after release cannot commit again or reopen.
    wheel.controller.handlePointer(wheel.pointer)
    #expect(!wheel.controller.isOpen)
    #expect(wheel.commits.count == expected.count)
}

@Test(.macOSTestApplication, arguments: [0.133162, 0.1371, 0.2696]) @MainActor
func wheelLiveTriageCompleteTopLeftPathCommits(elapsed: Double) {
    for style in [LayoutWheelStyle.custom, .grouped] {
        let wheel = LiveTriageWheel(style: style)
        defer { wheel.controller.stop() }
        for step in 1...24 {
            wheel.move(BTPoint(x: -39 * Double(step) / 24, y: -39 * Double(step) / 24),
                       at: Double(step) * 0.003)
        }
        wheel.time = 100 + elapsed
        wheel.controller.handleModifiers([])
        #expect(wheel.commits == [.windowAction(.topLeftQuarter)])
    }
}

@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func wheelLiveTriageModeDwellAtDividerCoordinate(hasWindow: Bool) {
    for x in [700.0, 960.0] {
        let wheel = LiveTriageWheel(style: .grouped, origin: BTPoint(x: x, y: 500), hasWindow: hasWindow)
        defer { wheel.controller.stop() }
        wheel.move(BTPoint(x: 88, y: 88), at: 0)
        wheel.time = 100.199
        wheel.controller.handleFanDeadline()
        #expect(wheel.presenter.latest?.fan.openSector == nil)
        wheel.time = 100.2
        wheel.controller.handleFanDeadline()
        #expect(wheel.presenter.latest?.fan.openSector == .bottomRight)
        wheel.controller.handleModifiers([])
        #expect(wheel.commits.isEmpty) // Mode has no quick action.
    }
}

@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func wheelLiveTriageInnerSectorBoundaryNeverDropsSelection(retaining: Bool) {
    let wheel = LiveTriageWheel(style: .grouped)
    defer { wheel.controller.stop() }
    if retaining { wheel.move(BTPoint(x: -55, y: 0), at: 0) }
    // Left / Top Left boundary. Hysteresis may retain Left, but never nil.
    for (index, delta) in [0.0, 0.01, 0.05, 0.11].enumerated() {
        let angle = -3 * Double.pi / 8 + delta
        wheel.move(BTPoint(x: sin(angle) * 55, y: -cos(angle) * 55), at: Double(index) * 0.02)
        #expect(wheel.presenter.latest?.selection?.ring == .inner)
        #expect(wheel.presenter.latest?.selection?.sector == (retaining && delta < 0.1 ? .left : .topLeft))
    }
    wheel.controller.handleModifiers([])
    #expect(wheel.commits == [.windowAction(.topLeftQuarter)])
}

@Test(.macOSTestApplication) @MainActor func wheelLiveTriageFinalPointerCancelsInHubAndKeepsKeyboardChoice() {
    let wheel = LiveTriageWheel(style: .grouped)
    defer { wheel.controller.stop() }
    wheel.move(BTPoint(x: -39, y: -39), at: 0.1)
    wheel.pointer = wheel.origin // Final move not delivered yet.
    wheel.controller.handleModifiers([])
    #expect(wheel.commits.isEmpty)

    wheel.controller.handleModifiers([]) // The remaining modifier-up rearms activation.
    wheel.controller.handleModifiers([.control, .option, .shift])
    wheel.controller.handleActivationDeadline(generation: 2)
    wheel.controller.handleKey(.nextSector)
    wheel.controller.handleModifiers([]) // Stationary pointer must not undo key selection.
    #expect(wheel.commits == [.windowAction(.topHalf)])
}
