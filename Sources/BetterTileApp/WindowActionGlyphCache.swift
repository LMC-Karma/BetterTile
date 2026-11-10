import AppKit
import BetterTileCore
import BetterTileMacOS

/// Bundled action glyphs, wrapped as the same template image that the
/// SwiftUI renderer used to produce: 2x black coverage at 30×26 points.
/// Each call site tints it, so highlighted menu rows, disabled controls and
/// the glass menu panel keep their own foreground.
@MainActor enum WindowActionGlyphCache {
    /// Internal so tests can draw a reference image through the same sites.
    static var templates: [WindowAction: NSImage] = [:]

    /// Missing bundled artwork returns nil, and the caller shows the symbol.
    static func template(for action: WindowAction) -> NSImage? {
        if let cached = templates[action] { return cached }
        // Both appearances store identical coverage; the template is tinted later.
        guard let coverage = GlyphMaskStore.image(set: .menuGlass, id: action.rawValue,
                                                  pointSize: 20, scale: 2, appearance: .light) else { return nil }
        let image = NSImage(cgImage: coverage, size: NSSize(width: 30, height: 26))
        image.isTemplate = true
        templates[action] = image
        return image
    }
}
