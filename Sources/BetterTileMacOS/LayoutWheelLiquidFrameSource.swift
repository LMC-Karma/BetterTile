import AppKit
import QuartzCore

/// Supplies a drawable that is ready to render. The model and all layer
/// changes stay on the main actor; acquiring a drawable never blocks it.
@MainActor protocol LayoutWheelLiquidFrameSource: AnyObject {
    var isRunning: Bool { get }
    func start(layer: CAMetalLayer, framesPerSecond: Int,
               frame: @escaping (Double, any CAMetalDrawable) -> Void)
    func stop()
}

@MainActor final class LayoutWheelLiquidDisplayLink: NSObject, LayoutWheelLiquidFrameSource,
                                                        @preconcurrency CAMetalDisplayLinkDelegate {
    private(set) var link: CAMetalDisplayLink?
    private var frame: ((Double, any CAMetalDrawable) -> Void)?
    var isRunning: Bool { link != nil }

    func start(layer: CAMetalLayer, framesPerSecond: Int,
               frame: @escaping (Double, any CAMetalDrawable) -> Void) {
        guard link == nil else { return }
        self.frame = frame
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        // Leave a refresh for the blur and label transaction to reach the
        // compositor alongside the body, including a busy main run-loop turn.
        link.preferredFrameLatency = 2
        let rate = Float(max(30, min(120, framesPerSecond)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        self.link = link
        // Common includes tracking modes. All delegate calls use this run loop.
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.delegate = nil
        link?.invalidate()
        link = nil
        frame = nil
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        deliver(from: link, at: update.targetTimestamp, drawable: update.drawable)
    }

    /// A callback queued by a stopped link cannot reach a later run.
    func deliver(from link: CAMetalDisplayLink, at time: Double, drawable: any CAMetalDrawable) {
        guard link === self.link else { return }
        frame?(time, drawable)
    }

    isolated deinit { link?.invalidate() }
}
