import BetterTileCore
import SwiftUI

/// The ring radii shared by drawing and hit testing.
///
/// The view draws from these values and the runtime panel hit tests with
/// `geometry`, so a pointer always selects the sector it is drawn over.
public struct LayoutWheelMetrics: Sendable {
    public let geometry: LayoutWheelGeometry
    public let outerRingOuterRadius: Double
    public let oneLevelInnerRingOuterRadius: Double

    /// Extra room for the selected slice's lift and shadow. The panel must be
    /// larger than the logical wheel or those effects can be clipped at its
    /// invisible square boundary.
    public static let presentationPadding = 18.0

    public init?(
        hubRadius: Double,
        innerRingOuterRadius: Double,
        outerRingInnerRadius: Double,
        outerRingOuterRadius: Double,
        oneLevelInnerRingOuterRadius: Double? = nil
    ) {
        guard let geometry = LayoutWheelGeometry(
            hubRadius: hubRadius,
            innerRingOuterRadius: innerRingOuterRadius,
            outerRingInnerRadius: outerRingInnerRadius
        ), outerRingOuterRadius > outerRingInnerRadius else { return nil }
        let oneLevelRadius = oneLevelInnerRingOuterRadius ?? innerRingOuterRadius + 16
        guard oneLevelRadius > hubRadius else { return nil }

        self.geometry = geometry
        self.outerRingOuterRadius = outerRingOuterRadius
        self.oneLevelInnerRingOuterRadius = oneLevelRadius
    }

    public static let standard = LayoutWheelMetrics(
        hubRadius: 23,
        innerRingOuterRadius: 68,
        outerRingInnerRadius: 76,
        outerRingOuterRadius: 110,
        oneLevelInnerRingOuterRadius: 84
    )!

    /// The drawn size. One Level omits the outer ring instead of leaving a gap.
    public func diameter(for levelCount: LayoutWheelLevelCount) -> Double {
        switch levelCount {
        case .one: oneLevelInnerRingOuterRadius * 2
        case .two: outerRingOuterRadius * 2
        }
    }

    public func presentationHeight(for levelCount: LayoutWheelLevelCount) -> Double {
        presentationDiameter(for: levelCount)
    }

    public func presentationDiameter(for levelCount: LayoutWheelLevelCount) -> Double {
        diameter(for: levelCount) + Self.presentationPadding * 2
    }

    public func scaled(by requestedScale: Double) -> LayoutWheelMetrics {
        let scale = requestedScale.isFinite
            ? min(
                max(requestedScale, LayoutWheelConfiguration.minimumScale),
                LayoutWheelConfiguration.maximumScale
            )
            : LayoutWheelConfiguration.defaultScale
        return LayoutWheelMetrics(
            hubRadius: geometry.hubRadius * scale,
            innerRingOuterRadius: geometry.innerRingOuterRadius * scale,
            outerRingInnerRadius: geometry.outerRingInnerRadius * scale,
            outerRingOuterRadius: outerRingOuterRadius * scale,
            oneLevelInnerRingOuterRadius: oneLevelInnerRingOuterRadius * scale
        )!
    }

    public func geometry(for levelCount: LayoutWheelLevelCount) -> LayoutWheelGeometry {
        switch levelCount {
        case .one:
            return LayoutWheelGeometry(
                hubRadius: geometry.hubRadius,
                innerRingOuterRadius: oneLevelInnerRingOuterRadius,
                outerRingInnerRadius: max(
                    geometry.outerRingInnerRadius,
                    oneLevelInnerRingOuterRadius + 1
                )
            )!
        case .two:
            return geometry
        }
    }

    public func innerRadius(for ring: LayoutWheelRing) -> Double {
        switch ring {
        case .inner: geometry.hubRadius
        case .outer: geometry.outerRingInnerRadius
        }
    }

    public func outerRadius(
        for ring: LayoutWheelRing,
        levelCount: LayoutWheelLevelCount = .two
    ) -> Double {
        switch ring {
        case .inner:
            levelCount == .one ? oneLevelInnerRingOuterRadius : geometry.innerRingOuterRadius
        case .outer: outerRingOuterRadius
        }
    }

    func iconRadius(
        for ring: LayoutWheelRing,
        levelCount: LayoutWheelLevelCount = .two
    ) -> Double {
        (innerRadius(for: ring) + outerRadius(for: ring, levelCount: levelCount)) / 2
    }
}

/// What one sector shows: a concise label, an SF Symbol, and its state.
public struct LayoutWheelSlot: Equatable, Sendable {
    public var label: String
    public var symbolName: String
    public var isEmpty: Bool
    public var isAvailable: Bool

    public init(label: String, symbolName: String, isEmpty: Bool, isAvailable: Bool) {
        self.label = label
        self.symbolName = symbolName
        self.isEmpty = isEmpty
        self.isAvailable = isAvailable
    }

    public static let empty = Self(
        label: "Empty",
        symbolName: "circle.dotted",
        isEmpty: true,
        isAvailable: false
    )

    /// Legacy Custom Zone assignments render as Empty. The command remains
    /// decodable so older saved configurations migrate without a broken slot.
    public init(
        command: LayoutWheelCommand?,
        isAvailable: Bool = true
    ) {
        switch command {
        case .none:
            self = .empty
        case let .windowAction(action):
            self.init(
                label: action.title,
                symbolName: action.layoutWheelSymbolName,
                isEmpty: false,
                isAvailable: isAvailable
            )
        case .customZone:
            self = .empty
        case .repairBento:
            self.init(
                label: "Repair Bento",
                symbolName: "arrow.triangle.2.circlepath",
                isEmpty: false,
                isAvailable: isAvailable
            )
        }
    }

    /// The spoken description: position first, then the assigned command, then
    /// availability. VoiceOver users navigate the wheel by direction.
    public func accessibilityLabel(
        for selection: LayoutWheelSelection,
        levelCount: LayoutWheelLevelCount
    ) -> String {
        var parts = [selection.sector.displayName]
        if levelCount == .two {
            parts.append(selection.ring == .inner ? "inner ring" : "outer ring")
        }
        parts.append(label)
        if !isEmpty, !isAvailable {
            parts.append("unavailable")
        }
        return parts.joined(separator: ", ")
    }
}

public extension LayoutWheelSector {
    var displayName: String {
        switch self {
        case .top: "Top"
        case .topRight: "Top right"
        case .right: "Right"
        case .bottomRight: "Bottom right"
        case .bottom: "Bottom"
        case .bottomLeft: "Bottom left"
        case .left: "Left"
        case .topLeft: "Top left"
        }
    }

    /// The drawn centre angle. Top is -90 degrees and angles increase
    /// clockwise because SwiftUI's y axis points down, which matches the
    /// clockwise ordering `LayoutWheelGeometry` hit tests.
    var drawnCenterAngle: Angle { .degrees(-90 + 45 * Double(rawValue)) }
}

public extension WindowAction {
    /// One symbol for each action, shared by the wheel and any future picker.
    var layoutWheelSymbolName: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .leftThird: "rectangle.leadingthird.inset.filled"
        case .centerThird: "rectangle.center.inset.filled"
        case .rightThird: "rectangle.trailingthird.inset.filled"
        case .leftTwoThirds: "rectangle.lefthalf.inset.filled"
        case .rightTwoThirds: "rectangle.righthalf.inset.filled"
        case .topLeftQuarter: "rectangle.inset.topleft.filled"
        case .topRightQuarter: "rectangle.inset.topright.filled"
        case .bottomLeftQuarter: "rectangle.inset.bottomleft.filled"
        case .bottomRightQuarter: "rectangle.inset.bottomright.filled"
        case .topLeftSixth, .topCenterSixth, .topRightSixth,
             .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth:
            "square.grid.3x2.fill"
        case .maximize: "arrow.up.left.and.arrow.down.right"
        // Both this spelling and `rectangle.inset.filled.center` resolve on
        // macOS 26. Use the canonical deployment-target name here; the view
        // keeps a diagram fallback for older SF Symbols catalogs.
        case .almostMaximize: "inset.filled.center.rectangle"
        case .center: "dot.square.fill"
        case .centerResize: "arrow.down.forward.and.arrow.up.backward"
        case .previousDisplay: "arrow.left.square"
        case .nextDisplay: "arrow.right.square"
        case .moveLeft: "arrow.left"
        case .moveRight: "arrow.right"
        case .moveUp: "arrow.up"
        case .moveDown: "arrow.down"
        case .growWidth: "arrow.left.and.right"
        case .shrinkWidth: "arrow.right.and.line.vertical.and.arrow.left"
        case .growHeight: "arrow.up.and.down"
        case .shrinkHeight: "arrow.down.and.line.horizontal.and.arrow.up"
        case .restore: "arrow.uturn.backward"
        }
    }
}

/// Groups the assignable commands so the inspector menu stays readable.
public struct LayoutWheelActionGroup: Sendable {
    public let title: String
    public let actions: [WindowAction]

    public static let all: [Self] = [
        Self(title: "Halves", actions: [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        Self(title: "Thirds", actions: [
            .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
        ]),
        Self(title: "Quarters", actions: [
            .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
        ]),
        Self(title: "Sixths", actions: [
            .topLeftSixth, .topCenterSixth, .topRightSixth,
            .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
        ]),
        Self(title: "Whole Display", actions: [
            .maximize, .almostMaximize, .center, .centerResize,
        ]),
        Self(title: "Displays", actions: [.previousDisplay, .nextDisplay]),
        Self(title: "Move", actions: [.moveLeft, .moveRight, .moveUp, .moveDown]),
        Self(title: "Resize", actions: [
            .growWidth, .shrinkWidth, .growHeight, .shrinkHeight,
        ]),
        Self(title: "History", actions: [.restore]),
    ]

    /// Every action stays reachable from the inspector, so a command can never
    /// become unassignable by being left out of a group.
    public static var groupedActions: [WindowAction] { all.flatMap(\.actions) }
}

/// The Layout Wheel renderer used by both Settings and the runtime panel.
///
/// The caller supplies wheel state. Passing `onSelect` makes sectors editable
/// controls for Settings; the runtime panel omits it and drives `selection`
/// from the pointer.
public struct LayoutWheelView: View {
    private let configuration: LayoutWheelConfiguration
    private let selection: LayoutWheelSelection?
    private let unavailableCommands: Set<LayoutWheelCommand>
    private let metrics: LayoutWheelMetrics
    private let onSelect: ((LayoutWheelSelection) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focusedSelection: LayoutWheelSelection?

    public init(
        configuration: LayoutWheelConfiguration,
        selection: LayoutWheelSelection? = nil,
        unavailableCommands: Set<LayoutWheelCommand> = [],
        metrics: LayoutWheelMetrics = .standard,
        onSelect: ((LayoutWheelSelection) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.selection = selection
        self.unavailableCommands = unavailableCommands
        self.metrics = metrics
        self.onSelect = onSelect
    }

    private var effectiveMetrics: LayoutWheelMetrics {
        metrics.scaled(by: configuration.scale)
    }

    private var diameter: Double {
        effectiveMetrics.diameter(for: configuration.levelCount)
    }

    private var presentationDiameter: Double {
        effectiveMetrics.presentationDiameter(for: configuration.levelCount)
    }

    private var rings: [LayoutWheelRing] { configuration.activeRings }

    private var isHighContrast: Bool { contrast == .increased }

    public var body: some View {
        wheel
        .frame(width: presentationDiameter, height: presentationDiameter)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selection)
    }

    private var wheel: some View {
        ZStack {
            backdrop
            ForEach(rings, id: \.self) { ring in
                ForEach(LayoutWheelSector.allCases, id: \.self) { sector in
                    sectorView(LayoutWheelSelection(ring: ring, sector: sector))
                }
            }
            hub
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layout Wheel")
    }

    @ViewBuilder
    private var backdrop: some View {
        if reduceTransparency {
            Circle().fill(Color(nsColor: .windowBackgroundColor))
        } else {
            Circle().fill(.clear).glassEffect(.regular, in: .circle)
        }
    }

    // MARK: - Sectors

    private func slot(for selection: LayoutWheelSelection) -> LayoutWheelSlot {
        let command = configuration.command(at: selection)
        let isAvailable = command.map { !unavailableCommands.contains($0) } ?? false
        return LayoutWheelSlot(
            command: command,
            isAvailable: isAvailable
        )
    }

    private func shape(for selection: LayoutWheelSelection) -> LayoutWheelSectorShape {
        LayoutWheelSectorShape(
            innerRadius: visualInnerRadius(for: selection.ring),
            outerRadius: visualOuterRadius(for: selection.ring),
            centerAngle: selection.sector.drawnCenterAngle
        )
    }

    /// The wheel keeps its logical radii for selection, while the outer ring
    /// is drawn inward to make the visible inter-ring gap 5pt.
    private func visualInnerRadius(for ring: LayoutWheelRing) -> Double {
        switch ring {
        case .inner: effectiveMetrics.innerRadius(for: ring)
        case .outer:
            min(
                effectiveMetrics.geometry.outerRingInnerRadius,
                effectiveMetrics.geometry.innerRingOuterRadius + 5
            )
        }
    }

    private func visualOuterRadius(for ring: LayoutWheelRing) -> Double {
        effectiveMetrics.outerRadius(for: ring, levelCount: configuration.levelCount)
    }

    private func hitShape(for selection: LayoutWheelSelection) -> LayoutWheelSectorShape {
        LayoutWheelSectorShape(
            innerRadius: effectiveMetrics.innerRadius(for: selection.ring),
            outerRadius: effectiveMetrics.outerRadius(for: selection.ring, levelCount: configuration.levelCount),
            centerAngle: selection.sector.drawnCenterAngle,
            visualGap: 0,
            cornerRadius: 0
        )
    }

    @ViewBuilder
    private func sectorView(_ selection: LayoutWheelSelection) -> some View {
        let slot = slot(for: selection)
        let shape = shape(for: selection)
        let hitShape = hitShape(for: selection)
        let isSelected = self.selection == selection
        let isFocused = focusedSelection == selection

        ZStack {
            shape.fill(fill(slot: slot, isSelected: isSelected))
            shape.stroke(
                stroke(slot: slot, isSelected: isSelected, isFocused: isFocused),
                style: strokeStyle(slot: slot, isSelected: isSelected, isFocused: isFocused)
            )
            sectorIcon(slot, selection: selection, isSelected: isSelected)
        }
        .scaleEffect(isSelected && !reduceMotion ? 1.045 : 1)
        .shadow(
            color: isSelected ? .black.opacity(reduceMotion ? 0.12 : 0.24) : .clear,
            radius: isSelected ? 7 : 0,
            y: isSelected ? 3 : 0
        )
        .zIndex(isSelected ? 1 : 0)
        .contentShape(hitShape)
        .modifier(SectorControl(
            selection: selection,
            isEditable: onSelect != nil,
            focus: $focusedSelection,
            action: onSelect
        ))
        .accessibilityLabel(
            slot.accessibilityLabel(for: selection, levelCount: configuration.levelCount)
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func sectorIcon(
        _ slot: LayoutWheelSlot,
        selection: LayoutWheelSelection,
        isSelected: Bool
    ) -> some View {
        let radius = effectiveMetrics.iconRadius(
            for: selection.ring,
            levelCount: configuration.levelCount
        )
        let angle = selection.sector.drawnCenterAngle.radians
        let center = diameter / 2
        let iconSize: CGFloat = selection.ring == .outer ? 35 : 31
        let iconPointSize: CGFloat = selection.ring == .outer ? 18 : 16

        return LayoutWheelIcon(
            slot: slot,
            tint: labelColor(slot: slot, isSelected: isSelected),
            fontSize: iconPointSize
        )
        .frame(width: iconSize, height: iconSize)
        .position(x: center + cos(angle) * radius, y: center + sin(angle) * radius)
    }

    // MARK: - State styling

    /// Selected fills, unavailable and Empty stay unfilled. Stroke weight and
    /// dash pattern carry the same distinction without relying on colour.
    private func fill(slot: LayoutWheelSlot, isSelected: Bool) -> some ShapeStyle {
        guard isSelected, slot.isAvailable else {
            return AnyShapeStyle(Color.primary.opacity(isHighContrast ? 0.10 : 0.06))
        }
        return AnyShapeStyle(Color.accentColor.opacity(isHighContrast ? 1 : 0.85))
    }

    private func stroke(
        slot: LayoutWheelSlot,
        isSelected: Bool,
        isFocused: Bool
    ) -> Color {
        if isSelected || isFocused { return .accentColor }
        if slot.isEmpty || !slot.isAvailable {
            return .secondary.opacity(isHighContrast ? 0.7 : 0.45)
        }
        return .primary.opacity(isHighContrast ? 0.45 : 0.18)
    }

    private func strokeStyle(
        slot: LayoutWheelSlot,
        isSelected: Bool,
        isFocused: Bool
    ) -> StrokeStyle {
        guard isSelected || isFocused else {
            return StrokeStyle(lineWidth: 1)
        }
        if slot.isEmpty {
            return StrokeStyle(lineWidth: 3, dash: [1.5, 4])
        }
        if !slot.isAvailable {
            return StrokeStyle(lineWidth: 3, dash: [5, 4])
        }
        return StrokeStyle(lineWidth: 3)
    }

    private func labelColor(slot: LayoutWheelSlot, isSelected: Bool) -> Color {
        if isSelected, slot.isAvailable {
            return .white
        }
        if slot.isEmpty || !slot.isAvailable {
            return .secondary
        }
        return .primary
    }

    // MARK: - Hub

    private var hub: some View {
        ZStack {
            if reduceTransparency {
                Circle().fill(Color(nsColor: .controlBackgroundColor))
            } else {
                Circle().fill(.clear).glassEffect(.regular, in: .circle)
            }
            Circle().stroke(
                selection == nil ? Color.accentColor : .primary.opacity(0.2),
                lineWidth: selection == nil ? 3 : 1
            )
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(selection == nil ? Color.accentColor : .secondary)
        }
        .frame(
            width: effectiveMetrics.geometry.hubRadius * 2,
            height: effectiveMetrics.geometry.hubRadius * 2
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cancel")
        .accessibilityAddTraits(selection == nil ? [.isSelected] : [])
    }
}

/// Makes a sector a focusable control only when Settings supplies an editor.
/// The runtime panel keeps plain shapes so the panel never takes key focus.
private struct SectorControl: ViewModifier {
    let selection: LayoutWheelSelection
    let isEditable: Bool
    var focus: FocusState<LayoutWheelSelection?>.Binding
    let action: ((LayoutWheelSelection) -> Void)?

    func body(content: Content) -> some View {
        if isEditable, let action {
            Button { action(selection) } label: { content }
                .buttonStyle(.plain)
                .focused(focus, equals: selection)
        } else {
            content
        }
    }
}

/// Uses the native symbol for ordinary actions, and a compact custom diagram
/// where the symbol alone does not communicate the selected partition clearly.
private struct LayoutWheelIcon: View {
    let slot: LayoutWheelSlot
    let tint: Color
    let fontSize: CGFloat

    private var descriptor: LayoutWheelGlyphDescriptor? {
        switch slot.symbolName {
        case "rectangle.leadingthird.inset.filled":
            return .partition(columns: 3, selected: [0])
        case "rectangle.center.inset.filled":
            return .partition(columns: 3, selected: [1])
        case "rectangle.trailingthird.inset.filled":
            return .partition(columns: 3, selected: [2])
        case "rectangle.lefthalf.inset.filled":
            return .partition(columns: 3, selected: [0, 1])
        case "rectangle.righthalf.inset.filled":
            return .partition(columns: 3, selected: [1, 2])
        case "square.grid.3x2.fill":
            let name = slot.label.lowercased()
            var selected = name.contains("bottom") ? 3 : 0
            if name.contains("center") { selected += 1 }
            if name.contains("right") { selected += 2 }
            return .grid(columns: 3, rows: 2, selected: [selected])
        default:
            return nil
        }
    }

    @ViewBuilder
    var body: some View {
        if let descriptor {
            LayoutWheelGlyph(descriptor: descriptor, tint: tint)
                .scaleEffect(0.86)
        } else if slot.symbolName == "inset.filled.center.rectangle",
                  NSImage(systemSymbolName: slot.symbolName, accessibilityDescription: nil) == nil {
            LayoutWheelGlyph(descriptor: .inset, tint: tint)
        } else {
            Image(systemName: slot.symbolName)
                .font(.system(size: fontSize, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint)
        }
    }
}

private enum LayoutWheelGlyphDescriptor: Equatable {
    case partition(columns: Int, selected: Set<Int>)
    case grid(columns: Int, rows: Int, selected: Set<Int>)
    case inset
}

private struct LayoutWheelGlyph: View {
    let descriptor: LayoutWheelGlyphDescriptor
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let outer = LayoutWheelGlyphLayout.outerRect(in: size)
            context.stroke(
                Path(roundedRect: outer, cornerRadius: 3.5),
                with: .color(tint),
                lineWidth: 1.25
            )

            switch descriptor {
            case let .partition(columns, selected):
                let content = LayoutWheelGlyphLayout.contentRect(in: outer)
                let cells = LayoutWheelGlyphLayout.gridRects(
                    columns: columns,
                    rows: 1,
                    in: content
                )
                for (index, cell) in cells.enumerated() {
                    if selected.contains(index) { continue }
                    context.stroke(
                        Path(roundedRect: cell, cornerRadius: 1.8),
                        with: .color(.white.opacity(0.95)),
                        lineWidth: 1
                    )
                }
                if let first = selected.min(),
                   let last = selected.max(),
                   selected == Set(first ... last),
                   cells.indices.contains(first),
                   cells.indices.contains(last) {
                    let selectedRect = cells[first].union(cells[last])
                    context.fill(
                        Path(roundedRect: selectedRect, cornerRadius: 2.5),
                        with: .color(.white)
                    )
                }
            case let .grid(columns, rows, selected):
                let content = LayoutWheelGlyphLayout.contentRect(in: outer)
                let cells = LayoutWheelGlyphLayout.gridRects(
                    columns: columns,
                    rows: rows,
                    in: content
                )
                for (index, cell) in cells.enumerated() {
                    let path = Path(roundedRect: cell, cornerRadius: 1.8)
                    if selected.contains(index) {
                        context.fill(path, with: .color(.white))
                    }
                    context.stroke(path, with: .color(.white.opacity(0.95)), lineWidth: 1)
                }
            case .inset:
                let inset = outer.insetBy(dx: outer.width * 0.22, dy: outer.height * 0.22)
                context.fill(
                    Path(roundedRect: inset, cornerRadius: 3),
                    with: .color(tint.opacity(0.9))
                )
            }
        }
    }
}

/// Shared point geometry for the reference-style partition glyphs. Keeping
/// this separate from SwiftUI layout ensures every cell is centred in the same
/// landscape frame instead of inheriting a nested square proposal.
struct LayoutWheelGlyphLayout {
    static let aspectRatio = 1.35
    static let columnGap: CGFloat = 2.5
    static let rowGap: CGFloat = 2.5

    static func outerRect(in size: CGSize) -> CGRect {
        let width = min(max(1, size.width - 2), max(1, (size.height - 2) * aspectRatio))
        let height = width / aspectRatio
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    static func contentRect(in outer: CGRect) -> CGRect {
        outer.insetBy(dx: outer.width * 0.10, dy: outer.height * 0.13)
    }

    static func gridRects(columns: Int, rows: Int, in rect: CGRect) -> [CGRect] {
        guard columns > 0, rows > 0 else { return [] }
        let totalColumnGap = columnGap * CGFloat(columns - 1)
        let totalRowGap = rowGap * CGFloat(rows - 1)
        let cellWidth = (rect.width - totalColumnGap) / CGFloat(columns)
        let cellHeight = (rect.height - totalRowGap) / CGFloat(rows)
        return (0 ..< rows).flatMap { row in
            (0 ..< columns).map { column in
                CGRect(
                    x: rect.minX + CGFloat(column) * (cellWidth + columnGap),
                    y: rect.minY + CGFloat(row) * (cellHeight + rowGap),
                    width: cellWidth,
                    height: cellHeight
                )
            }
        }
    }
}

/// One annular wedge. The point-based gap keeps neighbouring sectors visually
/// separate by the same distance at both radii without changing where
/// `LayoutWheelGeometry` places the boundary.
struct LayoutWheelSectorShape: Shape {
    static let sectorWidth = Angle.degrees(45)
    static let defaultVisualGap = 5.0
    static let defaultCornerRadius = 3.0

    var innerRadius: Double
    var outerRadius: Double
    var centerAngle: Angle
    var visualGap = Self.defaultVisualGap
    var cornerRadius = Self.defaultCornerRadius

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let half = Self.sectorWidth.radians / 2
        let centerRadians = centerAngle.radians
        let outerStart = centerRadians - half + visualGap / (2 * max(outerRadius, 1))
        let outerEnd = centerRadians + half - visualGap / (2 * max(outerRadius, 1))
        let innerStart = centerRadians - half + visualGap / (2 * max(innerRadius, 1))
        let innerEnd = centerRadians + half - visualGap / (2 * max(innerRadius, 1))
        let depth = min(cornerRadius, max(0, (outerRadius - innerRadius) * 0.3))
        let outerTrim = depth / max(outerRadius, 1)
        let innerTrim = depth / max(innerRadius, 1)

        func point(radius: Double, angle: Double) -> CGPoint {
            CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        }

        func inset(_ point: CGPoint, toward target: CGPoint, by distance: Double) -> CGPoint {
            let dx = target.x - point.x
            let dy = target.y - point.y
            let length = hypot(dx, dy)
            guard length > 0 else { return point }
            let amount = min(distance / length, 0.5)
            return CGPoint(x: point.x + dx * amount, y: point.y + dy * amount)
        }

        let outerStartPoint = point(radius: outerRadius, angle: outerStart)
        let outerEndPoint = point(radius: outerRadius, angle: outerEnd)
        let innerStartPoint = point(radius: innerRadius, angle: innerStart)
        let innerEndPoint = point(radius: innerRadius, angle: innerEnd)

        var path = Path()
        path.move(to: inset(outerStartPoint, toward: innerStartPoint, by: depth))
        path.addQuadCurve(
            to: point(radius: outerRadius, angle: outerStart + outerTrim),
            control: outerStartPoint
        )
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: .radians(outerStart + outerTrim),
            endAngle: .radians(outerEnd - outerTrim),
            clockwise: false
        )
        path.addQuadCurve(
            to: inset(outerEndPoint, toward: innerEndPoint, by: depth),
            control: outerEndPoint
        )
        path.addLine(to: inset(innerEndPoint, toward: outerEndPoint, by: depth))
        path.addQuadCurve(
            to: point(radius: innerRadius, angle: innerEnd - innerTrim),
            control: innerEndPoint
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: .radians(innerEnd - innerTrim),
            endAngle: .radians(innerStart + innerTrim),
            clockwise: true
        )
        path.addQuadCurve(
            to: inset(innerStartPoint, toward: outerStartPoint, by: depth),
            control: innerStartPoint
        )
        path.addLine(to: inset(outerStartPoint, toward: innerStartPoint, by: depth))
        path.closeSubpath()
        return path
    }
}

#Preview("Two Levels") {
    LayoutWheelView(
        configuration: LayoutWheelConfiguration(),
        selection: LayoutWheelSelection(ring: .outer, sector: .right)
    )
    .padding(24)
}

#Preview("One Level") {
    LayoutWheelView(
        configuration: LayoutWheelConfiguration(levelCount: .one),
        selection: LayoutWheelSelection(ring: .inner, sector: .topLeft)
    )
    .padding(24)
}
