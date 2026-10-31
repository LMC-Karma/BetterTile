import AppKit
import Metal
import Testing
@_spi(LiquidWheelPrototype) @testable import BetterTileCore
@_spi(LiquidWheelPrototype) @testable import BetterTileMacOS

/// Only tests acquire a drawable synchronously. Product frames come from
/// CAMetalDisplayLink; this adapter keeps deterministic model-time tests.
@MainActor private final class WheelLiquidTestFrameSource: LayoutWheelLiquidFrameSource {
    let clock: any LayoutWheelFrameClock
    private let view = NSView()
    init(clock: any LayoutWheelFrameClock) { self.clock = clock }
    var isRunning: Bool { clock.isRunning }
    func start(layer: CAMetalLayer, framesPerSecond: Int,
               frame: @escaping (Double, any CAMetalDrawable) -> Void) {
        clock.start(on: view) { time in
            autoreleasepool {
                if let drawable = layer.nextDrawable() { frame(time, drawable) }
            }
        }
    }
    func stop() { clock.stop() }
}

extension LayoutWheelLiquidPresenter {
    convenience init(clock: any LayoutWheelFrameClock) {
        self.init(frameSource: WheelLiquidTestFrameSource(clock: clock))
        panelForTesting.animationBehavior = .none
    }
}

@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelLiquidFrameSourceTests {
    private func layer() -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.drawableSize = CGSize(width: 2, height: 2)
        return layer
    }

    @Test func stoppedAndReplacedLinksCannotDeliverCallbacks() throws {
        let source = LayoutWheelLiquidDisplayLink()
        let layer = layer()
        let drawable = try #require(layer.nextDrawable())
        var callbacks = 0
        source.start(layer: layer, framesPerSecond: 60) { _, _ in callbacks += 1 }
        let first = try #require(source.link)
        source.deliver(from: first, at: 1, drawable: drawable)
        #expect(callbacks == 1)
        source.stop()
        #expect(!source.isRunning && source.link == nil)
        #expect(first.delegate == nil)
        source.deliver(from: first, at: 2, drawable: drawable)
        #expect(callbacks == 1)
        source.start(layer: layer, framesPerSecond: 60) { _, _ in callbacks += 1 }
        let second = try #require(source.link)
        #expect(second !== first)
        source.deliver(from: first, at: 3, drawable: drawable)
        #expect(callbacks == 1)
        source.deliver(from: second, at: 4, drawable: drawable)
        #expect(callbacks == 2)
        source.stop()
    }

    @Test func presenterStopsTheMetalSourceAtRestAndOnClose() throws {
        let source = LayoutWheelLiquidDisplayLink()
        let presenter = LayoutWheelLiquidPresenter(frameSource: source)
        presenter.panelForTesting.animationBehavior = .none
        presenter.reduceMotion = true
        let content = LayoutWheelLiquidContent(configuration: .init(style: .grouped), levelCount: .two)
        #expect(presenter.open(content, center: BTPoint(x: -20_000, y: -20_000)))
        let layer = try #require(presenter.metalLayerForTesting)
        let first = try #require(source.link)
        // The system forbids nextDrawable on a layer attached to a metal
        // display link. Supply offscreen drawables from a separate test layer.
        let drawingLayer = self.layer()
        drawingLayer.drawableSize = layer.drawableSize
        drawingLayer.presentsWithTransaction = true
        var time = 1.0
        for _ in 0..<40 where source.isRunning {
            try autoreleasepool {
                let drawable = try #require(drawingLayer.nextDrawable())
                source.deliver(from: first, at: time, drawable: drawable)
            }
            time += 1 / 60
        }
        #expect(presenter.currentModel?.isAtRest == true)
        #expect(!source.isRunning && first.delegate == nil)
        let resting = presenter.renderedFrameCount
        try autoreleasepool {
            let drawable = try #require(drawingLayer.nextDrawable())
            source.deliver(from: first, at: time, drawable: drawable)
        }
        #expect(presenter.renderedFrameCount == resting)
        presenter.update(.init(selection: .init(ring: .inner, sector: .right)))
        let second = try #require(source.link)
        #expect(second !== first)
        presenter.close()
        #expect(!source.isRunning && source.link == nil && second.delegate == nil)
        #expect(presenter.drawableSizeForTesting == CGSize(width: 1, height: 1))
    }

    @Test func stopReleasesTheLinkCallbackAndLayer() throws {
        final class Sentinel {}
        let source = LayoutWheelLiquidDisplayLink()
        weak var weakLink: CAMetalDisplayLink?
        weak var weakSentinel: Sentinel?
        weak var weakLayer: CAMetalLayer?
        autoreleasepool {
            let layer = layer()
            let sentinel = Sentinel()
            source.start(layer: layer, framesPerSecond: 60) { _, _ in _ = sentinel }
            weakLink = source.link; weakLayer = layer; weakSentinel = sentinel
            #expect(source.isRunning)
            source.stop()
        }
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        #expect(weakLink == nil && weakSentinel == nil && weakLayer == nil)
    }
}
