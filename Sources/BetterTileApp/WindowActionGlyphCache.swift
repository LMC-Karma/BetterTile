import AppKit
import BetterTileCore
import BetterTileMacOS

/// The shared store owns decoded bitmap reuse and its memory limit.
@MainActor enum WindowActionGlyphCache {
    enum Context: Equatable, Sendable { case primary, glass }

    /// Primary returns final-colour pixels; glass returns black template coverage.
    static func image(for action: WindowAction, scale: CGFloat, appearance: GlyphMaskStore.Appearance,
                      context: Context = .primary) -> CGImage? {
        GlyphMaskStore.image(set: context == .glass ? .menuGlass : .menuActions,
                            id: action.rawValue, pointSize: 20,
                            scale: Double(scale), appearance: appearance)
    }

    /// Glass callers retain the menu's existing foreground style and template tint.
    static func nsImage(for action: WindowAction, scale: CGFloat, appearance: GlyphMaskStore.Appearance,
                        context: Context = .primary) -> NSImage? {
        guard let bitmap = image(for: action, scale: scale, appearance: appearance, context: context) else { return nil }
        let image = NSImage(cgImage: bitmap, size: NSSize(width: 30, height: 26))
        image.isTemplate = context == .glass
        return image
    }
}
