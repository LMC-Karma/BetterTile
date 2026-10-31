import AppKit
import Testing
@testable import BetterTileApp

@Test(.appTestApplication) @MainActor func applicationWindowsUseNormalStackingOnTheActiveSpace() {
    _ = NSApplication.shared
    let window = OffscreenTestWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
    ApplicationWindowPresentation.configure(window)
    #expect(window.level == .normal)
    #expect(!window.hidesOnDeactivate)
    #expect(window.collectionBehavior.contains(.moveToActiveSpace))
    #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
}
