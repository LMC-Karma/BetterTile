import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test(arguments: [false, true]) @MainActor
func unchangedWireframesPreserveTheirInFlightPresentation(initialReduceMotion: Bool) throws {
    var panels: [CountingWireframePanel] = []
    var reduceMotion = initialReduceMotion
    let controller = PlacementWireframeController(reduceMotion: { reduceMotion }) {
        let panel = CountingWireframePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: true)
        panels.append(panel)
        return panel
    }
    defer { controller.hide() }
    let id = WindowID(rawValue: "wireframe")
    var placement = Placement(windowID: id, frame: BTRect(x: 12000, y: 200, width: 600, height: 400))
    let origin = BTRect(x: 12500, y: 500, width: 400, height: 300)
    controller.show([placement], baselineFrames: [id: origin])
    let panel = try #require(panels.first)
    let frameWrites = panel.frameWrites, orders = panel.frontOrders, alphaWrites = panel.alphaWrites
    // No run-loop yield: every repeated presentation arrives while the first
    // animation is still in flight, including a changed origin for the same target.
    for _ in 0..<5 { controller.show([placement], baselineFrames: [id: BTRect(x: 12000, y: 0, width: 400, height: 300)]) }
    #expect(panels.count == 1)
    #expect(panel.frameWrites == frameWrites)
    #expect(panel.frontOrders == orders)
    #expect(panel.alphaWrites == alphaWrites)
    if !initialReduceMotion {
        reduceMotion = true
        controller.show([placement], baselineFrames: [id: origin])
        #expect(panel.frameWrites > frameWrites && panel.alphaWrites > alphaWrites)
        #expect(panel.frontOrders == orders)
        let settledWrites = panel.frameWrites
        controller.show([placement], baselineFrames: [id: origin])
        #expect(panel.frameWrites == settledWrites)
    }

    placement.frame.origin.x += 100
    controller.show([placement], baselineFrames: [id: origin])
    #expect(panels.count == 1)
    #expect(panel.frameWrites > frameWrites && panel.frontOrders > orders && panel.alphaWrites > alphaWrites)

    controller.show([])
    #expect(!panel.isVisible)
    controller.show([placement], baselineFrames: [id: origin])
    #expect(panels.count == 2 && panels[1].isVisible)
    controller.hide()
    #expect(!panels[1].isVisible)
    controller.show([placement], baselineFrames: [id: origin])
    #expect(panels.count == 3 && panels[2].isVisible)
}

@MainActor private final class CountingWireframePanel: NSPanel {
    var frameWrites = 0
    var frontOrders = 0
    var alphaWrites = 0
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        frameWrites += 1
        super.setFrame(frameRect, display: flag)
    }
    override func orderFrontRegardless() {
        frontOrders += 1
        super.orderFrontRegardless()
    }
    override var alphaValue: CGFloat { didSet { alphaWrites += 1 } }
}
