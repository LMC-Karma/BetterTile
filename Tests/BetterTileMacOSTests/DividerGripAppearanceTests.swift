import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileMacOS

@Suite(.macOSTestApplication, .macOSUI) @MainActor struct DividerGripAppearanceTests {
    private func lens(useLiquidGlass: Bool, strength: Double = 0.5) -> DividerLensPreviewView? {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: DividerGrip(axis: .vertical, length: 200, thickness: 6, active: false,
                                                       overlayAppearance: .init(useLiquidGlass: useLiquidGlass, strength: strength)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 60, height: 220)
        for _ in 0..<3 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) } // real-time: advances hosted SwiftUI layout to create the native grip layers
        func find(_ v: NSView) -> DividerLensPreviewView? {
            (v as? DividerLensPreviewView) ?? v.subviews.lazy.compactMap(find).first
        }
        let found = find(view)
        // Keep the window alive until the caller is done with the view.
        objc_setAssociatedObject(found as Any, "window", window, .OBJC_ASSOCIATION_RETAIN)
        return found
    }

    /// The canvas grip must honour the Liquid Glass setting the same way the Window Layout preview does:
    /// glass draws the lens layers, off draws the frost view.
    @Test func theCanvasGripFollowsTheLiquidGlassSetting() throws {
        let on = try #require(lens(useLiquidGlass: true))
        let off = try #require(lens(useLiquidGlass: false))
        #expect(on.handleView.overlayAppearance.useLiquidGlass)
        #expect(!off.handleView.overlayAppearance.useLiquidGlass)
        #expect(on.handleView.showsGlass == on.handleView.lensLayers.isAvailable)
        #expect(!off.handleView.showsGlass)
        #expect(off.handleView.showsFrost)
        #expect(!on.handleView.showsFrost || !on.handleView.lensLayers.isAvailable)
        #expect(on.handleView.renderedThickness == off.handleView.renderedThickness + 4)
    }
}
