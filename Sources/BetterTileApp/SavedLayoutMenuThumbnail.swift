// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import SwiftUI

/// Geometry for the layout pictures in the menu bar panel's Saved Layouts picker.
enum SavedLayoutMenuThumbnailMetrics {
    /// The picture keeps the 4:3 shape of the Settings picture. The row grows from 53 pt to fit it.
    static let size = CGSize(width: 56, height: 42)
    static let rowVerticalPadding: CGFloat = 7
    static let rowHeight = size.height + rowVerticalPadding * 2
    static let padding = SettingsSpacing.s1
    static var canvasSize: CGSize { CGSize(width: size.width - padding * 2, height: size.height - padding * 2) }
    /// Half of the gap between neighbouring panes, as in the Settings picture.
    static let paneInset: CGFloat = 2
    static let iconFraction: CGFloat = 0.7
    static let minimumIcon = SettingsSpacing.s2
    static let maximumIcon = SettingsSpacing.s5
    /// The smallest space between an icon and its pane edge.
    static let iconMargin: CGFloat = 1.5

    struct Pane: Equatable {
        var frame: CGRect
        var slot: String?
    }

    struct IconPlacement: Equatable {
        var rect: CGRect
        var preference: AppPreference
    }

    /// Pane frames in a canvas of `size`. Same pane order and gap as the Settings picture.
    static func panes(of document: SavedLayoutDocument, in size: CGSize) -> [Pane] {
        let leaves = document.layout.map { SavedLayoutCanvas.leaves($0) } ?? []
        let rects = leaves.map { leaf in
            (leaf.rect, SavedLayoutCanvas.slotIDs(in: leaf.node, document: document).first)
        } + (document.windows + document.floats).map { ($0.rect, Optional($0.slot)) }
        return rects.map { rect, slot in
            Pane(frame: CGRect(x: rect.x * size.width + paneInset, y: rect.y * size.height + paneInset,
                               width: max(1, rect.width * size.width - paneInset * 2),
                               height: max(1, rect.height * size.height - paneInset * 2)),
                 slot: slot)
        }
    }

    /// A centred square about 70% of the pane's shorter side, from 8 to 20 pt. Nil when even 8 pt does not fit.
    static func iconRect(in pane: CGRect) -> CGRect? {
        let shorter = min(pane.width, pane.height)
        let edge = min(min(maximumIcon, max(minimumIcon, shorter * iconFraction)), shorter - iconMargin * 2)
        guard edge >= minimumIcon else { return nil }
        return CGRect(x: pane.midX - edge / 2, y: pane.midY - edge / 2, width: edge, height: edge)
    }

    /// Each pane with its icon, in drawing order. A later pane paints over an earlier pane and its icon.
    static func drawings(of document: SavedLayoutDocument, in size: CGSize) -> [(pane: Pane, icon: IconPlacement?)] {
        panes(of: document, in: size).map { pane in
            guard let slot = pane.slot, let preference = document.slots.first(where: { $0.id == slot })?.prefer.first,
                  let rect = iconRect(in: pane.frame) else { return (pane, nil) }
            return (pane, IconPlacement(rect: rect, preference: preference))
        }
    }

    /// One icon for each pane whose first preference fits, in pane order.
    static func iconPlacements(of document: SavedLayoutDocument, in size: CGSize) -> [IconPlacement] {
        drawings(of: document, in: size).compactMap(\.icon)
    }
}

/// Small app icons for the menu picker. A least-recently-used cache of at most 64 icons.
///
/// An entry's key is the app's bundle URL, the bundle's modification date and the light or dark
/// appearance. Each lookup asks LaunchServices for the URL again, as the Settings picture does, so an
/// updated app gets a new icon and an uninstalled app loses its entry. Each image keeps only small
/// bitmaps, not the full icon set.
@MainActor final class SavedLayoutMenuIconCache {
    static let shared = SavedLayoutMenuIconCache()
    static let defaultCapacity = 64
    /// 16 and 32 px use the app's own small icon art. 20 and 40 px match the largest icon at 1x and 2x.
    static let pixelSizes = [16, 20, 32, 40]

    struct Key: Hashable {
        var bundleID: String
        var url: URL
        var modified: Date?
        var dark: Bool
    }

    let capacity: Int
    private let locate: @MainActor (String) -> URL?
    private let modificationDate: @MainActor (URL) -> Date?
    private let load: @MainActor (URL) -> NSImage?
    private var images: [Key: NSImage] = [:]
    /// Keys from least to most recently used.
    private var order: [Key] = []

    var count: Int { images.count }

    init(capacity: Int = defaultCapacity,
         locate: @escaping @MainActor (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
         modificationDate: @escaping @MainActor (URL) -> Date? = { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate },
         load: @escaping @MainActor (URL) -> NSImage? = { NSWorkspace.shared.icon(forFile: $0.path) }) {
        self.capacity = max(1, capacity)
        self.locate = locate
        self.modificationDate = modificationDate
        self.load = load
    }

    /// Nil when no app with this bundle ID is installed. A miss leaves no entry, so a later install shows its icon.
    func icon(for bundleID: String, dark: Bool) -> NSImage? {
        guard let url = locate(bundleID) else {
            remove { $0.bundleID == bundleID }
            return nil
        }
        let key = Key(bundleID: bundleID, url: url, modified: modificationDate(url), dark: dark)
        if let image = images[key] {
            order.removeAll { $0 == key }; order.append(key)
            return image
        }
        // An older version of the same app in the same appearance is stale.
        remove { $0.bundleID == bundleID && $0.dark == dark }
        guard let source = load(url) else { return nil }
        let image = Self.smallCopy(of: source, dark: dark)
        images[key] = image; order.append(key)
        while order.count > capacity { images[order.removeFirst()] = nil }
        return image
    }

    private func remove(where match: (Key) -> Bool) {
        order.removeAll(where: match)
        images = images.filter { !match($0.key) }
    }

    /// Draws the icon in the given appearance, so an icon with dark art keeps it.
    static func smallCopy(of source: NSImage, dark: Bool = false) -> NSImage {
        let points = SavedLayoutMenuThumbnailMetrics.maximumIcon
        let image = NSImage(size: NSSize(width: points, height: points))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        for pixels in pixelSizes {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            // Set the point size first: the context scales point drawing to the bitmap's pixels from it.
            bitmap.size = image.size
            guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.imageInterpolation = .high
                source.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            }
            image.addRepresentation(bitmap)
        }
        return image
    }
}

extension EnvironmentValues {
    /// The icon cache for menu pictures. Nil uses the shared cache. Tests supply their own.
    @Entry var savedLayoutMenuIcons: SavedLayoutMenuIconCache? = nil
}

/// The menu style of `SavedLayoutThumbnail`: every pane with a preference shows its icon when it fits.
struct SavedLayoutMenuThumbnail: View {
    let document: SavedLayoutDocument
    @Environment(\.savedLayoutMenuIcons) private var suppliedIcons
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let cache = suppliedIcons ?? .shared
        let dark = colorScheme == .dark
        // Only the icons the picture draws: first preferences of panes large enough for an icon.
        let drawn = Set(SavedLayoutMenuThumbnailMetrics.iconPlacements(of: document, in: SavedLayoutMenuThumbnailMetrics.canvasSize)
            .compactMap { placement -> String? in if case let .app(id) = placement.preference { id } else { nil } })
        let appIcons = Dictionary(uniqueKeysWithValues: drawn.compactMap { id in cache.icon(for: id, dark: dark).map { (id, $0) } })
        Canvas { context, size in
            for (pane, placement) in SavedLayoutMenuThumbnailMetrics.drawings(of: document, in: size) {
                context.fill(Path(roundedRect: pane.frame, cornerRadius: SavedLayoutMetrics.chipRadius),
                             with: .color(.secondary.opacity(0.45)))
                guard let placement else { continue }
                let icon: NSImage? = switch placement.preference {
                case let .app(bundle): appIcons[bundle]
                case .group: NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
                }
                if let icon { context.draw(Image(nsImage: icon).interpolation(.high), in: placement.rect) }
            }
        }
        .padding(SavedLayoutMenuThumbnailMetrics.padding)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: SavedLayoutMetrics.stageRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}
