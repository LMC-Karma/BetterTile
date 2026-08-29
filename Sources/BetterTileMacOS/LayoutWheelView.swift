import BetterTileCore
import SwiftUI

/// The ring radii shared by drawing and hit testing.
///
/// The view draws from these values and the runtime panel hit tests with
/// `geometry`, so a pointer always selects the sector it is drawn over.
public struct LayoutWheelMetrics: Sendable {
    public let geometry: LayoutWheelGeometry
    public let outerRingOuterRadius: Double

    public init?(
        hubRadius: Double,
        innerRingOuterRadius: Double,
        outerRingInnerRadius: Double,
        outerRingOuterRadius: Double
    ) {
        guard let geometry = LayoutWheelGeometry(
            hubRadius: hubRadius,
            innerRingOuterRadius: innerRingOuterRadius,
            outerRingInnerRadius: outerRingInnerRadius
        ), outerRingOuterRadius > outerRingInnerRadius else { return nil }

        self.geometry = geometry
        self.outerRingOuterRadius = outerRingOuterRadius
    }

    public static let standard = LayoutWheelMetrics(
        hubRadius: 30,
        innerRingOuterRadius: 86,
        outerRingInnerRadius: 96,
        outerRingOuterRadius: 150
    )!

    /// The drawn size. One Level omits the outer ring instead of leaving a gap.
    public func diameter(for levelCount: LayoutWheelLevelCount) -> Double {
        switch levelCount {
        case .one: geometry.innerRingOuterRadius * 2
        case .two: outerRingOuterRadius * 2
        }
    }

    public func presentationHeight(for levelCount: LayoutWheelLevelCount) -> Double {
        diameter(for: levelCount)
    }

    public func innerRadius(for ring: LayoutWheelRing) -> Double {
        switch ring {
        case .inner: geometry.hubRadius
        case .outer: geometry.outerRingInnerRadius
        }
    }

    public func outerRadius(for ring: LayoutWheelRing) -> Double {
        switch ring {
        case .inner: geometry.innerRingOuterRadius
        case .outer: outerRingOuterRadius
        }
    }

    func iconRadius(for ring: LayoutWheelRing) -> Double {
        (innerRadius(for: ring) + outerRadius(for: ring)) / 2
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

    /// A deleted Custom Zone renders as Empty, matching configuration
    /// normalization, so a stale identifier never shows a broken sector.
    public init(
        command: LayoutWheelCommand?,
        customZones: [UUID: String],
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
        case let .customZone(id):
            guard let name = customZones[id] else {
                self = .empty
                return
            }
            self.init(
                label: name,
                symbolName: "square.dashed",
                isEmpty: false,
                isAvailable: isAvailable
            )
        case .repairBento:
            self.init(
                label: "Repair Bento",
                symbolName: "wand.and.rays",
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
        case .almostMaximize: "rectangle.inset.filled"
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
    private let customZones: [UUID: String]
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
        customZones: [CustomZone] = [],
        selection: LayoutWheelSelection? = nil,
        unavailableCommands: Set<LayoutWheelCommand> = [],
        metrics: LayoutWheelMetrics = .standard,
        onSelect: ((LayoutWheelSelection) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.customZones = Dictionary(
            customZones.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        self.selection = selection
        self.unavailableCommands = unavailableCommands
        self.metrics = metrics
        self.onSelect = onSelect
    }

    private var diameter: Double { metrics.diameter(for: configuration.levelCount) }

    private var rings: [LayoutWheelRing] { configuration.activeRings }

    private var isHighContrast: Bool { contrast == .increased }

    public var body: some View {
        wheel
        .frame(width: diameter, height: metrics.presentationHeight(for: configuration.levelCount))
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
            customZones: customZones,
            isAvailable: isAvailable
        )
    }

    private func shape(for selection: LayoutWheelSelection) -> LayoutWheelSectorShape {
        LayoutWheelSectorShape(
            innerRadius: metrics.innerRadius(for: selection.ring),
            outerRadius: metrics.outerRadius(for: selection.ring),
            centerAngle: selection.sector.drawnCenterAngle
        )
    }

    @ViewBuilder
    private func sectorView(_ selection: LayoutWheelSelection) -> some View {
        let slot = slot(for: selection)
        let shape = shape(for: selection)
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
        .contentShape(shape)
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
        let radius = metrics.iconRadius(for: selection.ring)
        let angle = selection.sector.drawnCenterAngle.radians
        let center = diameter / 2

        return Image(systemName: slot.symbolName)
            .font(.system(size: 16, weight: .semibold))
            .symbolRenderingMode(.monochrome)
        .foregroundStyle(labelStyle(slot: slot, isSelected: isSelected))
        .frame(width: 32, height: 32)
        .scaleEffect(isSelected && !reduceMotion ? 1.06 : 1)
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
        if isSelected && !slot.isAvailable { return .secondary }
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
        if slot.isEmpty {
            return StrokeStyle(lineWidth: isFocused ? 3 : 1.5, dash: [1.5, 4])
        }
        if !slot.isAvailable {
            return StrokeStyle(lineWidth: isFocused ? 3 : 1.5, dash: [5, 4])
        }
        return StrokeStyle(lineWidth: isSelected || isFocused ? 3 : 1)
    }

    private func labelStyle(slot: LayoutWheelSlot, isSelected: Bool) -> some ShapeStyle {
        if isSelected, slot.isAvailable {
            return AnyShapeStyle(Color.white)
        }
        if slot.isEmpty || !slot.isAvailable {
            return AnyShapeStyle(Color.secondary)
        }
        return AnyShapeStyle(Color.primary)
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
            width: metrics.geometry.hubRadius * 2,
            height: metrics.geometry.hubRadius * 2
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

/// One annular wedge. A small angular gap keeps neighbouring sectors visually
/// separate without changing where `LayoutWheelGeometry` places the boundary.
struct LayoutWheelSectorShape: Shape {
    static let sectorWidth = Angle.degrees(45)
    static let gap = Angle.degrees(1.2)

    var innerRadius: Double
    var outerRadius: Double
    var centerAngle: Angle

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let half = Self.sectorWidth / 2
        let start = centerAngle - half + Self.gap
        let end = centerAngle + half - Self.gap

        var path = Path()
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: start,
            endAngle: end,
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: end,
            endAngle: start,
            clockwise: true
        )
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
