import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

private let zoneID = UUID()
private let zones: [UUID: String] = [zoneID: "Reading"]

/// A missing symbol renders as a blank sector at runtime and never fails a
/// build, so the whole mapping is resolved against the installed SF Symbols.
@Test func everyWheelSymbolResolvesOnThisSystem() {
    var names = WindowAction.allCases.map(\.layoutWheelSymbolName)
    names.append(LayoutWheelSlot.empty.symbolName)
    names.append(LayoutWheelSlot(command: .repairBento, customZones: [:]).symbolName)
    names.append(LayoutWheelSlot(command: .customZone(zoneID), customZones: zones).symbolName)

    for name in names {
        #expect(
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
            "SF Symbol \(name) is unavailable"
        )
    }
}

@Test func slotsDeriveLabelsFromCommands() {
    let action = LayoutWheelSlot(command: .windowAction(.topRightQuarter), customZones: [:])
    #expect(action.label == "Top Right Quarter")
    #expect(!action.isEmpty)
    #expect(action.isAvailable)

    let zone = LayoutWheelSlot(command: .customZone(zoneID), customZones: zones)
    #expect(zone.label == "Reading")
    #expect(!zone.isEmpty)

    let repair = LayoutWheelSlot(command: .repairBento, customZones: [:], isAvailable: false)
    #expect(repair.label == "Repair Bento")
    #expect(!repair.isAvailable)
}

/// Settings normalization already clears deleted zones, but the renderer can be
/// handed state mid-edit, so a stale identifier has to read as Empty too.
@Test func deletedCustomZoneAndNoAssignmentBothRenderAsEmpty() {
    let deleted = LayoutWheelSlot(command: .customZone(UUID()), customZones: zones)
    let unassigned = LayoutWheelSlot(command: nil, customZones: zones)

    #expect(deleted == .empty)
    #expect(unassigned == .empty)
    #expect(deleted.isEmpty)
    #expect(!deleted.isAvailable)
}

@Test func accessibilityLabelsCarryPositionCommandAndAvailability() {
    let slot = LayoutWheelSlot(command: .windowAction(.leftHalf), customZones: [:])
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

    let unavailable = LayoutWheelSlot(command: .repairBento, customZones: [:], isAvailable: false)
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

    #expect(metrics.diameter(for: .one) == metrics.geometry.innerRingOuterRadius * 2)
    #expect(metrics.diameter(for: .two) == metrics.outerRingOuterRadius * 2)
    // The Settings window is at least 820 x 560; the wheel plus its caption has
    // to fit inside that with the sidebar and padding.
    #expect(metrics.diameter(for: .two) <= 400)
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
            customZones: [CustomZone(id: zoneID, name: "Reading", rect: .init(x: 0, y: 0, width: 1, height: 1))],
            selection: LayoutWheelSelection(ring: .inner, sector: .top),
            unavailableCommands: [.repairBento],
            onSelect: { _ in }
        )
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let diameter = LayoutWheelMetrics.standard.diameter(for: levelCount)

        #expect(size.width >= diameter)
        // The caption sits under the wheel, so height exceeds the diameter.
        #expect(size.height > diameter)
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

/// The Settings inspector builds its menu from these groups. An action left out
/// of every group could never be assigned to a sector, and nothing else would
/// report it, so the grouping has to stay exhaustive and free of duplicates.
@Test func everyWindowActionStaysAssignableFromExactlyOneGroup() {
    let grouped = LayoutWheelActionGroup.groupedActions

    #expect(Set(grouped) == Set(WindowAction.allCases))
    #expect(grouped.count == WindowAction.allCases.count)
    #expect(!LayoutWheelActionGroup.all.contains { $0.actions.isEmpty })
}

/// Labels are placed at the middle of a ring, so a box wider than the band or
/// the sector chord would spill outside the wheel in some directions.
@Test func labelBoxesStayInsideEveryRing() {
    let metrics = LayoutWheelMetrics.standard

    for ring in LayoutWheelRing.allCases {
        let size = metrics.labelSize(for: ring)
        let radius = metrics.labelRadius(for: ring)
        let band = metrics.outerRadius(for: ring) - metrics.innerRadius(for: ring)
        let chord = 2 * radius * sin(Double.pi / 8)

        #expect(size > 0)
        #expect(size <= band)
        #expect(size <= chord)
        // The radial extent has to stay between the ring's own edges.
        #expect(radius - size / 2 >= metrics.innerRadius(for: ring))
        #expect(radius + size / 2 <= metrics.outerRadius(for: ring))
    }
}
