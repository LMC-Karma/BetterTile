import AppKit
@testable import BetterTileMacOS

/// Records controller frame requests independently of native panel relocation.
/// Content sizing and deferred layout still use AppKit. Ordering is simulated.
@MainActor class UnconstrainedTabbedTestPanel: TabbedStripPanel {
    static let referenceScreenFrame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    private(set) var requestedFrame: NSRect?
    private var applyingNativeFrame = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        withFrameRequest(frameRect) { super.setFrame(frameRect, display: flag) }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        withFrameRequest(frameRect) { super.setFrame(frameRect, display: flag, animate: animateFlag) }
    }

    private func withFrameRequest(_ frame: NSRect, apply: () -> Void) {
        let wasApplying = applyingNativeFrame
        if !wasApplying { requestedFrame = frame }
        applyingNativeFrame = true
        defer { applyingNativeFrame = wasApplying }
        apply()
    }

    /// Models a native relocation without recording another controller request.
    func simulateNativeRelocation() {
        let wasApplying = applyingNativeFrame
        applyingNativeFrame = true
        defer { applyingNativeFrame = wasApplying }
        super.setFrame(frame.offsetBy(dx: 137, dy: -91), display: false)
    }

    // Synthetic input uses the requested origin even if the native panel moved
    // between event creation and delivery. Native view and window sizes stay real.
    override func convertPoint(toScreen point: NSPoint) -> NSPoint {
        let converted = super.convertPoint(toScreen: point)
        guard let requestedFrame else { return converted }
        return NSPoint(x: converted.x + requestedFrame.minX - frame.minX,
                       y: converted.y + requestedFrame.minY - frame.minY)
    }

    override func convertPoint(fromScreen point: NSPoint) -> NSPoint {
        guard let requestedFrame else { return super.convertPoint(fromScreen: point) }
        return super.convertPoint(fromScreen: NSPoint(
            x: point.x + frame.minX - requestedFrame.minX,
            y: point.y + frame.minY - requestedFrame.minY))
    }

    var shown = false
    override var isVisible: Bool { shown }
    override var isKeyWindow: Bool { false }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) { shown = place != .out }
    override func makeKey() {}
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
