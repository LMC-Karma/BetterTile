import AppKit
@testable import BetterTileMacOS

/// Keeps native content layout, but neither orders a window nor lets a display
/// change relocate a controller's synthetic offscreen frame. Frame and content
/// sizes still come from AppKit; this fixture does not manufacture expected geometry.
@MainActor class UnconstrainedTabbedTestPanel: TabbedStripPanel {
    static let referenceScreenFrame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    var shown = false
    override var isVisible: Bool { shown }
    override var isKeyWindow: Bool { false }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) { shown = place != .out }
    override func makeKey() {}
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
