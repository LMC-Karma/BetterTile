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

    /// One icon for each pane whose first preference fits, in pane order.
    static func iconPlacements(of document: SavedLayoutDocument, in size: CGSize) -> [IconPlacement] {
        panes(of: document, in: size).compactMap { pane in
            guard let slot = pane.slot, let preference = document.slots.first(where: { $0.id == slot })?.prefer.first,
                  let rect = iconRect(in: pane.frame) else { return nil }
            return IconPlacement(rect: rect, preference: preference)
        }
    }
}

/// Small app icons for the menu picker, cached per bundle ID.
/// Each image keeps only small bitmaps, not the full icon set.
@MainActor final class SavedLayoutMenuIconCache {
    static let shared = SavedLayoutMenuIconCache()
    /// 16 and 32 px use the app's own small icon art. 20 and 40 px match the largest icon at 1x and 2x.
    static let pixelSizes = [16, 20, 32, 40]

    private let resolve: @MainActor (String) -> NSImage?
    private var images: [String: NSImage] = [:]

    init(resolve: @escaping @MainActor (String) -> NSImage? = { id in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }) {
        self.resolve = resolve
    }

    /// Nil when no app with this bundle ID is installed. A miss is not cached, so a later install shows its icon.
    func icon(for bundleID: String) -> NSImage? {
        if let image = images[bundleID] { return image }
        guard let source = resolve(bundleID) else { return nil }
        let image = Self.smallCopy(of: source)
        images[bundleID] = image
        return image
    }

    static func smallCopy(of source: NSImage) -> NSImage {
        let points = SavedLayoutMenuThumbnailMetrics.maximumIcon
        let image = NSImage(size: NSSize(width: points, height: points))
        for pixels in pixelSizes {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            // Set the point size first: the context scales point drawing to the bitmap's pixels from it.
            bitmap.size = image.size
            guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            source.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        return image
    }
}

/// The menu style of `SavedLayoutThumbnail`: every pane with a preference shows its icon when it fits.
struct SavedLayoutMenuThumbnail: View {
    let document: SavedLayoutDocument
    var icons: SavedLayoutMenuIconCache = .shared

    var body: some View {
        let appIcons = Dictionary(uniqueKeysWithValues: Set(document.slots.flatMap { $0.prefer.compactMap { preference -> String? in
            if case let .app(id) = preference { id } else { nil }
        } }).compactMap { id in icons.icon(for: id).map { (id, $0) } })
        Canvas { context, size in
            for pane in SavedLayoutMenuThumbnailMetrics.panes(of: document, in: size) {
                context.fill(Path(roundedRect: pane.frame, cornerRadius: SavedLayoutMetrics.chipRadius),
                             with: .color(.secondary.opacity(0.45)))
            }
            for placement in SavedLayoutMenuThumbnailMetrics.iconPlacements(of: document, in: size) {
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
