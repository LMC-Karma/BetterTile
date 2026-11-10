import AppKit
import SwiftUI
import BetterTileCore
import BetterTileMacOS

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

@MainActor enum MenuGlassGlyphReference {
    static func render(action: WindowAction, scale: Double, dark: Bool) throws -> CGImage {
        let previous = NSApp.appearance
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        defer { NSApp.appearance = previous }
        var result: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            // Invoke the original producer from its actual View.body context.
            // Test-only invalidation makes every sample render fresh artwork.
            MenuGlassPanelGlyph.resetReference(for: action)
            let renderer = ImageRenderer(content: MenuGlassPanelGlyph(action: action)
                .foregroundStyle(.black).environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.displayScale, scale))
            renderer.scale = scale
            guard let displayed = renderer.cgImage else { return }
            if scale == 2 {
                guard let image = try? MenuGlassPanelGlyph.cachedTemplate(for: action) else { return }
                var rect = NSRect(x: 0, y: 0, width: 30, height: 26)
                result = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            } else {
                result = displayed
            }
        }
        guard let result else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}
