import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// A missing symbol renders as a blank sector at runtime and never fails a
/// build, so the whole mapping is resolved against the installed SF Symbols.
@Test func everyWheelSymbolResolvesOnThisSystem() {
    var names = WindowAction.allCases.map(\.layoutWheelSymbolName)
    names.append(LayoutWheelSlot.empty.symbolName)
    names.append(LayoutWheelSlot(command: .repairBento).symbolName)
    names.append(LayoutWheelSlot(command: .customZone(UUID())).symbolName)

    for name in names {
        let resolves = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        // This glyph is part of the macOS 26 design target but is absent from
        // older test hosts. LayoutWheelIcon supplies a deterministic diagram
        // fallback, so the app remains legible when the native glyph is absent.
        #expect(resolves || name == "inset.filled.center.rectangle",
                "SF Symbol \(name) is unavailable")
    }
}

@Test func slotsDeriveLabelsFromCommands() {
    let action = LayoutWheelSlot(command: .windowAction(.topRightQuarter))
    #expect(action.label == "Top Right Quarter")
    #expect(!action.isEmpty)
    #expect(action.isAvailable)

    let repair = LayoutWheelSlot(command: .repairBento, isAvailable: false)
    #expect(repair.label == "Repair Bento")
    #expect(!repair.isAvailable)
}

@Test func approvedSpecialActionSymbolsStayConsistent() {
    #expect(WindowAction.almostMaximize.layoutWheelSymbolName == "inset.filled.center.rectangle")
    #expect(LayoutWheelSlot(command: .repairBento).symbolName
        == "arrow.triangle.2.circlepath")
}

/// Settings normalization already clears deleted zones, but the renderer can be
/// handed state mid-edit, so a stale identifier has to read as Empty too.
@Test func legacyCustomZoneAndNoAssignmentBothRenderAsEmpty() {
    let deleted = LayoutWheelSlot(command: .customZone(UUID()))
    let unassigned = LayoutWheelSlot(command: nil)

    #expect(deleted == .empty)
    #expect(unassigned == .empty)
    #expect(deleted.isEmpty)
    #expect(!deleted.isAvailable)
}

@Test func accessibilityLabelsCarryPositionCommandAndAvailability() {
    let slot = LayoutWheelSlot(command: .windowAction(.leftHalf))
    let outerLeft = LayoutWheelSelection(ring: .outer, sector: .left)

    #expect(slot.accessibilityLabel(for: outerLeft, levelCount: .two)
        == "Left, outer ring, Left Half")
    #expect(slot.accessibilityLabel(
        for: LayoutWheelSelection(ring: .inner, sector: .bottomRight),
        levelCount: .two
    ) == "Bottom right, inner ring, Left Half")

    // One Level hides the outer ring, so naming a ring would be noise.
    #expect(slot.accessibilityLabel(
        for: LayoutWheelSelection(ring: .inner, sector: .top),
        levelCount: .one
    ) == "Top, Left Half")

    let unavailable = LayoutWheelSlot(command: .repairBento, isAvailable: false)
    #expect(unavailable.accessibilityLabel(for: outerLeft, levelCount: .two)
        == "Left, outer ring, Repair Bento, unavailable")

    // Empty is already spoken as Empty; "unavailable" would only repeat it.
    #expect(LayoutWheelSlot.empty.accessibilityLabel(for: outerLeft, levelCount: .two)
        == "Left, outer ring, Empty")
}

/// Drawing and hit testing must not drift apart. Every drawn band midpoint has
/// to hit test to the ring it is drawn in, and the gaps must stay unselectable.
@Test func drawnBandsAgreeWithHitTesting() {
    let metrics = LayoutWheelMetrics.standard
    let geometry = metrics.geometry

    for ring in LayoutWheelRing.allCases {
        let midpoint = (metrics.innerRadius(for: ring) + metrics.outerRadius(for: ring)) / 2
        let selection = geometry.selection(
            for: BTPoint(x: 0, y: -midpoint),
            levelCount: .two
        )
        #expect(selection == LayoutWheelSelection(ring: ring, sector: .top))
    }

    let deadBand = (geometry.innerRingOuterRadius + geometry.outerRingInnerRadius) / 2
    #expect(geometry.selection(for: BTPoint(x: 0, y: -deadBand), levelCount: .two) == nil)
    #expect(geometry.selection(
        for: BTPoint(x: 0, y: -geometry.hubRadius / 2),
        levelCount: .two
    ) == nil)
}

/// The drawn centre angles have to name the same sectors the pure geometry
/// picks, or a pointer would select a neighbour of the sector under it.
@Test func drawnCenterAnglesMatchGeometrySectors() {
    let metrics = LayoutWheelMetrics.standard
    let radius = (metrics.geometry.hubRadius + metrics.geometry.innerRingOuterRadius) / 2

    for sector in LayoutWheelSector.allCases {
        let angle = sector.drawnCenterAngle.radians
        let vector = BTPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        #expect(metrics.geometry.selection(for: vector, levelCount: .one)?.sector == sector)
    }
}

/// One Level draws only the inner ring, so the panel and the Settings host must
/// not reserve the two-level size.
@Test func oneLevelDrawsTheInnerRingOnly() {
    let metrics = LayoutWheelMetrics.standard

    #expect(metrics.diameter(for: .one) == metrics.oneLevelInnerRingOuterRadius * 2)
    #expect(metrics.diameter(for: .one) > metrics.geometry.innerRingOuterRadius * 2)
    #expect(metrics.diameter(for: .two) == metrics.outerRingOuterRadius * 2)
    #expect(metrics.diameter(for: .two) == 220)
    #expect(metrics.presentationDiameter(for: .two) > metrics.diameter(for: .two))
}

@Test func metricsRejectOverlappingRadii() {
    #expect(LayoutWheelMetrics(
        hubRadius: 36,
        innerRingOuterRadius: 104,
        outerRingInnerRadius: 116,
        outerRingOuterRadius: 116
    ) == nil)
    #expect(LayoutWheelMetrics(
        hubRadius: 36,
        innerRingOuterRadius: 104,
        outerRingInnerRadius: 100,
        outerRingOuterRadius: 172
    ) == nil)
}

/// Step 4 requires one renderer for two very different hosts. Measuring it in a
/// hosting view proves it lays out at its drawn size in both, and that neither
/// level clips inside the 820 x 560 minimum Settings window.
@Test @MainActor func theRendererFitsSettingsAndATransparentPanel() {
    for levelCount in LayoutWheelLevelCount.allCases {
        let view = LayoutWheelView(
            configuration: LayoutWheelConfiguration(levelCount: levelCount),
            selection: LayoutWheelSelection(ring: .inner, sector: .top),
            unavailableCommands: [.repairBento],
            onSelect: { _ in }
        )
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let diameter = LayoutWheelMetrics.standard.diameter(for: levelCount)

        #expect(size.width >= diameter)
        #expect(abs(size.height - LayoutWheelMetrics.standard.presentationDiameter(for: levelCount)) < 0.01)
        #expect(size.width <= 560)
        #expect(size.height <= 460)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        #expect(panel.contentView === hosting)
        #expect(hosting.frame.width >= diameter)
        #expect(hosting.frame.height >= diameter)
    }
}

@Test func scaledMetricsKeepDrawingAndHitTestingTogether() {
    let metrics = LayoutWheelMetrics.standard.scaled(by: 1.2)

    #expect(abs(metrics.diameter(for: .two) - 264) < 0.01)
    #expect(abs(metrics.geometry(for: .two).innerRingOuterRadius - 81.6) < 0.01)
    #expect(abs(metrics.geometry(for: .one).innerRingOuterRadius - 100.8) < 0.01)
}

@Test func referenceGlyphGeometryIsCenteredAndLandscape() {
    let outer = LayoutWheelGlyphLayout.outerRect(in: CGSize(width: 35, height: 35))
    #expect(abs(outer.midX - 17.5) < 0.01)
    #expect(abs(outer.midY - 17.5) < 0.01)
    #expect(abs(outer.width / outer.height - 1.35) < 0.01)

    let sixths = LayoutWheelGlyphLayout.gridRects(
        columns: 3,
        rows: 2,
        in: LayoutWheelGlyphLayout.contentRect(in: outer)
    )
    #expect(sixths.count == 6)
    #expect(abs(sixths[0].midY - sixths[1].midY) < 0.01)
    #expect(abs(sixths[0].midX - sixths[3].midX) < 0.01)
    #expect(abs(sixths[0].union(sixths[2]).midX - outer.midX) < 0.01)
}

/// The Settings inspector builds its menu from these groups. An action left out
/// of every group could never be assigned to a sector, and nothing else would
/// report it, so the grouping has to stay exhaustive and free of duplicates.
@Test func everyWindowActionStaysAssignableFromExactlyOneGroup() {
    let grouped = LayoutWheelActionGroup.groupedActions

    #expect(Set(grouped) == Set(WindowAction.allCases))
    #expect(grouped.count == WindowAction.allCases.count)
    #expect(!LayoutWheelActionGroup.all.contains { $0.actions.isEmpty })
}

/// Icons stay centred in their bands so the compact wheel keeps a clear visual
/// hierarchy without labels.
@Test func iconCentersStayInsideEveryRing() {
    let metrics = LayoutWheelMetrics.standard

    for ring in LayoutWheelRing.allCases {
        let radius = metrics.iconRadius(for: ring)
        #expect(radius > metrics.innerRadius(for: ring))
        #expect(radius < metrics.outerRadius(for: ring))
    }
}
