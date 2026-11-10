import AppKit
import SwiftUI
import BetterTileCore
import BetterTileMacOS

// The block below must stay byte-identical to the frozen copy in
// Tests/BetterTileMacOSTests/MenuGlassGlyphReference.swift. The glyph mask
// manifest hashes that copy; MainWindowActionGlyphTests checks this one.
// Frozen shipped WindowActionGlyph from BetterTileApp.swift; only its type name changes.
struct MenuGlassPanelGlyph: View {
    let action: WindowAction
    private static var images: [WindowAction: NSImage] = [:]

    /// A template image also works in AppKit-backed Picker menus, where a
    /// Canvas label cannot reliably supply an NSMenuItem image.
    static func image(for action: WindowAction) -> Image {
        if let cached = images[action] { return Image(nsImage: cached) }
        let renderer = ImageRenderer(content:
            LayoutWheelActionGlyph(action: action, tint: .black, fontSize: 20)
                .frame(width: 30, height: 26)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            return Image(systemName: action.layoutWheelSymbolName)
        }
        image.isTemplate = true
        images[action] = image
        return Image(nsImage: image)
    }

    var body: some View {
        Self.image(for: action)
            .frame(width: 30, height: 26)
            .accessibilityHidden(true)
    }
}


extension MenuGlassPanelGlyph {
    static func resetReference(for action: WindowAction) { images[action] = nil }
    static func cachedTemplate(for action: WindowAction) throws -> NSImage {
        guard let image = images[action] else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }
}
