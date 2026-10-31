import AppKit
import Metal
import Testing
@_spi(LiquidWheelPrototype) @testable import BetterTileCore
@_spi(LiquidWheelPrototype) @testable import BetterTileMacOS

/// Nothing the liquid wheel creates outlives it: no retain cycle through the
/// display link's target, the frame closures, the GPU completion handlers or
/// the panel.
@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelLiquidLifetimeTests {
    private final class Sentinel: Sendable {}
    private let content = LayoutWheelLiquidContent(configuration: .init(style: .grouped), levelCount: .two,
                                                   submenuStyle: .cluster)
    private let offscreen = BTPoint(x: -20_000, y: -20_000)

    /// Waits for every command buffer already committed, so completion
    /// handlers have run and released what they captured.
    private func drainGPU() {
        guard let queue = LayoutWheelLiquidPipeline.current?.queue, let buffer = queue.makeCommandBuffer() else { return }
        buffer.commit()
        buffer.waitUntilCompleted()
        // Commit the implicit layer transaction, as the end of a run-loop turn would.
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    /// One full gesture: open, aim a group, open its cluster, aim an option, cancel.
    private func gesture(_ presenter: LayoutWheelLiquidPresenter, clock: WheelTestClock) {
        #expect(presenter.open(content, center: offscreen))
        let layout = content.submenuLayout!
        var submenu = LayoutWheelSubmenuState()
        let ring = content.layout.iconRadii[1]
        let point = BTPoint(x: 0, y: -ring)
        submenu.update(vector: point, at: 0, geometry: content.wheelGeometry, layout: layout)
        submenu.update(vector: point, at: 0.25, geometry: content.wheelGeometry, layout: layout)
        let option = layout.positions(sector: .top, count: LayoutWheelGroup.at(.top).options.count)[0]
        submenu.update(vector: option, at: 0.3, geometry: content.wheelGeometry, layout: layout)
        presenter.update(.init(submenu: submenu, pointer: option))
        for _ in 0..<6 { clock.frame(hz: 30) }
        presenter.end(.cancel)
        var frames = 0
        while clock.isRunning, frames < 60 { clock.frame(hz: 30); frames += 1 }
    }

    @Test func presenterLayerPanelAndClosuresAreReleased() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        weak var weakPresenter: LayoutWheelLiquidPresenter?
        weak var weakLayer: CAMetalLayer?
        weak var weakPanel: NSPanel?
        weak var weakClock: WheelTestClock?
        weak var weakSentinel: Sentinel?
        autoreleasepool {
            let clock = WheelTestClock()
            let presenter = LayoutWheelLiquidPresenter(clock: clock)
            let sentinel = Sentinel()
            presenter.frameObserver = { _, _ in _ = sentinel }
            presenter.gpuObserver = { _ in _ = sentinel }
            presenter.onClosed = { _ = sentinel }
            for _ in 0..<3 { gesture(presenter, clock: clock) }
            #expect(!presenter.isOpen && !clock.isRunning)
            weakPresenter = presenter; weakLayer = presenter.metalLayerForTesting
            weakPanel = presenter.panelForTesting; weakClock = clock; weakSentinel = sentinel
        }
        drainGPU()
        #expect(weakPresenter == nil)
        #expect(weakLayer == nil)
        #expect(weakPanel == nil)
        #expect(weakClock == nil)
        #expect(weakSentinel == nil)
    }

    @Test func releasingAnOpenWheelStopsItsDisplayLink() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        weak var weakPresenter: LayoutWheelLiquidPresenter?
        weak var weakSource: LayoutWheelLiquidDisplayLink?
        weak var weakLink: CAMetalDisplayLink?
        autoreleasepool {
            let source = LayoutWheelLiquidDisplayLink()
            let presenter = LayoutWheelLiquidPresenter(frameSource: source)
            presenter.panelForTesting.animationBehavior = .none
            #expect(presenter.open(content, center: offscreen))
            #expect(source.isRunning)
            weakPresenter = presenter; weakSource = source; weakLink = source.link
        }
        drainGPU()
        #expect(weakPresenter == nil)
        #expect(weakSource == nil)
        #expect(weakLink == nil)
    }
}
