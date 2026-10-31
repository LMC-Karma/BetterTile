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
    static let selectedScale = 1.045

    /// Only shadow space can leave the screen. Reserve the selected slice's
    /// growth and its stroke, without clamping the whole transparent panel.
    func overflowPadding(for levelCount: LayoutWheelLevelCount) -> Double {
        max(0, Self.presentationPadding - diameter(for: levelCount) / 2 * (Self.selectedScale - 1) - 1)
    }

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
        hubRadius: 32,
        innerRingOuterRadius: 68,
        outerRingInnerRadius: 76,
        outerRingOuterRadius: 110,
        oneLevelInnerRingOuterRadius: 84
    )!

    public static let grouped = LayoutWheelMetrics(
        hubRadius: 32, innerRingOuterRadius: 88, outerRingInnerRadius: 94, outerRingOuterRadius: 154
    )!

    public var fanGeometry: LayoutWheelFanGeometry {
        let scale = outerRingOuterRadius / 154
        return LayoutWheelFanGeometry(wheel: geometry, innerRadius: outerRingOuterRadius + 10 * scale,
                                      outerRadius: outerRingOuterRadius + 76 * scale)
    }

    public func fanGeometry(for configuration: LayoutWheelConfiguration) -> LayoutWheelFanGeometry {
        let scale = outerRingOuterRadius / 154
        let radius = outerRadius(for: configuration.groupRing, levelCount: configuration.effectiveLevelCount)
        return LayoutWheelFanGeometry(wheel: geometry(for: configuration.effectiveLevelCount),
            innerRadius: radius + 10 * scale, outerRadius: radius + 76 * scale, configuration: configuration)
    }

    public var groupedPresentationDiameter: Double { fanGeometry.outerRadius * 2 + Self.presentationPadding * 2 }

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

/// What one sector shows: a concise label, an SF Symbol or layout and mode icon, and its state.
public struct LayoutWheelSlot: Equatable, Sendable {
    public var label: String
    public var symbolName: String
    /// The layout or mode icon to draw instead of `symbolName`.
    public var glyph: LayoutGlyph?
    var windowAction: WindowAction?
    public var isEmpty: Bool
    public var isAvailable: Bool

    public init(label: String, symbolName: String, glyph: LayoutGlyph? = nil, isEmpty: Bool, isAvailable: Bool) {
        self.label = label
        self.symbolName = symbolName
        self.glyph = glyph
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
            windowAction = action
        case .customZone:
            self = .empty
        case let .setMode(mode):
            self.init(label: mode.title, symbolName: "slider.horizontal.3", glyph: .mode(mode),
                      isEmpty: false, isAvailable: isAvailable)
        case let .chooseLayout(preset):
            self.init(label: preset.title, symbolName: "rectangle.split.2x2", glyph: .layout(preset),
                      isEmpty: false, isAvailable: isAvailable)
        case .savedLayouts:
            self.init(label: "Saved Layouts", symbolName: "rectangle.stack", isEmpty: false, isAvailable: isAvailable)
        case let .savedLayout(_, name):
            self.init(label: name, symbolName: "rectangle.split.2x2", isEmpty: false, isAvailable: isAvailable)
        case .moreSavedLayouts, .moreLayoutChoices:
            self.init(label: "More…", symbolName: "ellipsis", isEmpty: false, isAvailable: isAvailable)
        case .repairBento:
            self.init(
                label: "Repair Layout",
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
        case .nextTab: "chevron.right"
        case .previousTab: "chevron.left"
        case .moveTabLeft: "arrow.left.to.line"
        case .moveTabRight: "arrow.right.to.line"
        case .moveTabToNextPane: "rectangle.righthalf.inset.filled.arrow.right"
        case .moveTabToPreviousPane: "rectangle.lefthalf.inset.filled.arrow.left"
        case .showTabBar: "rectangle.topthird.inset.filled"
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
        Self(title: "Tabs", actions: WindowAction.tabCommands),
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
    private let overlayAppearance: OverlayAppearance
    private let selection: LayoutWheelSelection?
    private let unavailableCommands: Set<LayoutWheelCommand>
    private let metrics: LayoutWheelMetrics
    private let fan: LayoutWheelFanState
    private let layoutAvailable: Bool
    private let currentMode: LayoutMode?
    private let reservesFanSpace: Bool
    private let onSelect: ((LayoutWheelSelection) -> Void)?

    var retainedRenderer: LayoutWheelGlassRenderer?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focusedSelection: LayoutWheelSelection?

    public init(
        configuration: LayoutWheelConfiguration,
        overlayAppearance: OverlayAppearance = .init(),
        selection: LayoutWheelSelection? = nil,
        unavailableCommands: Set<LayoutWheelCommand> = [],
        metrics: LayoutWheelMetrics = .standard,
        fan: LayoutWheelFanState = .init(),
        layoutAvailable: Bool = true,
        currentMode: LayoutMode? = nil,
        reservesFanSpace: Bool = true,
        onSelect: ((LayoutWheelSelection) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.overlayAppearance = overlayAppearance
        self.selection = selection
        self.unavailableCommands = unavailableCommands
        self.metrics = metrics
        self.fan = fan
        self.layoutAvailable = layoutAvailable
        self.currentMode = currentMode
        self.reservesFanSpace = reservesFanSpace
        self.onSelect = onSelect
    }

    private var effectiveMetrics: LayoutWheelMetrics {
        (configuration.style == .grouped ? .grouped : metrics).scaled(by: configuration.scale)
    }

    private var diameter: Double {
        effectiveMetrics.diameter(for: configuration.effectiveLevelCount)
    }

    private var presentationDiameter: Double {
        configuration.style == .grouped && reservesFanSpace
            ? effectiveMetrics.groupedPresentationDiameter
            : effectiveMetrics.presentationDiameter(for: configuration.effectiveLevelCount)
    }

    private var sceneInput: LayoutWheelSceneInput {
        .init(configuration: configuration, appearance: overlayAppearance, selection: selection,
              unavailableCommands: unavailableCommands, fan: fan, layoutAvailable: layoutAvailable,
              currentMode: currentMode, reservesFanSpace: reservesFanSpace, customMetrics: metrics)
    }

    public var body: some View {
        ZStack {
            LayoutWheelNativeSurface(input: sceneInput, reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased,
                retainedRenderer: retainedRenderer)
                .allowsHitTesting(false).accessibilityHidden(true)
            ZStack {
                ForEach(configuration.activeRings, id: \.self) { ring in
                    ForEach(LayoutWheelSector.allCases, id: \.self) { sector in
                        sectorControl(.init(ring: ring, sector: sector))
                    }
                }
                Circle().fill(.clear)
                    .frame(width: effectiveMetrics.geometry.hubRadius * 2,
                           height: effectiveMetrics.geometry.hubRadius * 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Cancel")
                    .accessibilityAddTraits(selection == nil ? [.isSelected] : [])
            }
            .frame(width: diameter, height: diameter)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Layout Wheel")
        }
        .frame(width: presentationDiameter, height: presentationDiameter)
    }

    /// Existing Settings controls stay over stable, unanimated hit shapes.
    private func sectorControl(_ selection: LayoutWheelSelection) -> some View {
        let slot = sceneInput.slot(.sector(selection))
        let shape = LayoutWheelSectorShape(
            innerRadius: effectiveMetrics.innerRadius(for: selection.ring),
            outerRadius: effectiveMetrics.outerRadius(for: selection.ring, levelCount: configuration.effectiveLevelCount),
            centerAngle: selection.sector.drawnCenterAngle, visualGap: 0, cornerRadius: 0)
        return shape.fill(.clear)
            .overlay(shape.stroke(focusedSelection == selection ? Color.accentColor : .clear, lineWidth: 3))
            .contentShape(shape)
            .modifier(SectorControl(selection: selection, isEditable: onSelect != nil,
                focus: $focusedSelection, action: onSelect))
            .accessibilityLabel(slot.accessibilityLabel(for: selection, levelCount: configuration.effectiveLevelCount))
            .accessibilityAddTraits(self.selection == selection ? [.isSelected] : [])
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
struct LayoutWheelIcon: View {
    let slot: LayoutWheelSlot
    let tint: Color
    let fontSize: CGFloat
    var compact = false
    var weight: LayoutGlyphWeight = .semibold

    var partitionGlyph: WindowActionPartitionGlyph? {
        slot.windowAction.flatMap { WindowActionPartitionGlyph.actions[$0] }
    }

    @ViewBuilder
    var body: some View {
        if let glyph = slot.glyph {
            LayoutGlyphView(glyph, size: CGFloat(LayoutGlyph.canvasSize(besideSymbolSize: Double(fontSize))),
                            weight: .semibold)
                .foregroundStyle(tint)
        } else if let partitionGlyph {
            let image = partitionGlyph.templateImage(pointSize: fontSize, weight: weight)
            // Paint through the template's alpha mask. Direct NSImage tinting
            // converts semantic and translucent ink differently in Dark mode.
            Rectangle().fill(.foreground)
                .foregroundStyle(tint)
                .frame(width: image.size.width, height: image.size.height)
                .mask(Image(nsImage: image).renderingMode(.template).foregroundStyle(.white))
        } else if slot.symbolName == "rectangle.split.3x2" {
            LayoutWheelGlyph(descriptor: .grid(columns: 3, rows: 2, selected: []), tint: tint, compact: compact)
                .scaleEffect(compact ? 1 : 0.86)
        } else if slot.symbolName == "inset.filled.center.rectangle",
                  NSImage(systemSymbolName: slot.symbolName, accessibilityDescription: nil) == nil {
            LayoutWheelGlyph(descriptor: .inset, tint: tint)
        } else {
            Image(systemName: slot.symbolName)
                .font(.system(size: fontSize, weight: weight == .regular ? .regular : .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint)
        }
    }
}

/// Action glyph shared by the Layout Wheel and application-owned action
/// pickers. The tint is explicit so the same geometry reads on light and dark
/// surfaces.
public struct LayoutWheelActionGlyph: View {
    private let action: WindowAction
    private let tint: Color
    private let fontSize: CGFloat
    private let weight: LayoutGlyphWeight

    public init(action: WindowAction, tint: Color = .primary, fontSize: CGFloat = 12,
                weight: LayoutGlyphWeight = .semibold) {
        self.action = action
        self.tint = tint
        self.fontSize = fontSize
        self.weight = weight
    }

    public var body: some View {
        LayoutWheelIcon(
            slot: LayoutWheelSlot(command: .windowAction(action)),
            tint: tint,
            fontSize: fontSize,
            compact: true,
            weight: weight
        )
    }
}

private enum LayoutWheelGlyphDescriptor: Equatable {
    case grid(columns: Int, rows: Int, selected: Set<Int>)
    case inset
}

private struct LayoutWheelGlyph: View {
    let descriptor: LayoutWheelGlyphDescriptor
    let tint: Color
    var compact = false

    var body: some View {
        Canvas { context, size in
            let outer = LayoutWheelGlyphLayout.outerRect(in: size)
            let scale = compact ? min(1, outer.width / 36) : 1
            context.stroke(
                Path(roundedRect: outer, cornerRadius: 3.5 * scale),
                with: .color(tint),
                lineWidth: 1.25 * scale
            )

            switch descriptor {
            case let .grid(columns, rows, selected):
                let content = LayoutWheelGlyphLayout.contentRect(in: outer)
                let cells = LayoutWheelGlyphLayout.gridRects(
                    columns: columns,
                    rows: rows,
                    in: content,
                    gapScale: scale
                )
                for (index, cell) in cells.enumerated() {
                    let path = Path(roundedRect: cell, cornerRadius: 1.8 * scale)
                    if selected.contains(index) {
                        context.fill(path, with: .color(tint))
                    }
                    context.stroke(path, with: .color(tint.opacity(0.95)), lineWidth: scale)
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

    static func gridRects(columns: Int, rows: Int, in rect: CGRect, gapScale: CGFloat = 1) -> [CGRect] {
        guard columns > 0, rows > 0 else { return [] }
        let columnGap = Self.columnGap * gapScale
        let rowGap = Self.rowGap * gapScale
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
    var width = Self.sectorWidth

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let half = width.radians / 2
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
