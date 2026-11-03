import AppKit
import BetterTileCore
import SwiftUI

/// Opposite winding preserves the well as a true hole in native glass.
struct LayoutWheelBodyShape: Shape {
    var innerRadius: Double
    var outerRadius: Double
    var wellOffset: CGSize = .zero

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: .zero,
                    endAngle: .degrees(360), clockwise: false)
        path.closeSubpath()
        let well = CGPoint(x: center.x + wellOffset.width, y: center.y + wellOffset.height)
        path.move(to: CGPoint(x: well.x + innerRadius, y: well.y))
        path.addArc(center: well, radius: innerRadius, startAngle: .zero,
                    endAngle: .degrees(-360), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// A drawn step contour, never another glass body or an input region.
private struct LayoutWheelStepShape: Shape {
    let radius: Double
    let angle: Double
    let bulge: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<128 {
            let a = Double(index) * 2 * .pi / 128
            let r = radius + bulge * pow(max(0, cos(a - angle)), 12)
            let point = CGPoint(x: rect.midX + cos(a) * r, y: rect.midY + sin(a) * r)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Offscreen contrast tests replace native glass with a flat colour. Native
/// glass cannot be rendered offscreen, and `ImageRenderer` only approximates
/// it. Production never sets this value.
struct LayoutWheelGlassStandIn {
    var body: Color
    var well: Color
}
private struct LayoutWheelGlassStandInKey: EnvironmentKey {
    static let defaultValue: LayoutWheelGlassStandIn? = nil
}
extension EnvironmentValues {
    var layoutWheelGlassStandIn: LayoutWheelGlassStandIn? {
        get { self[LayoutWheelGlassStandInKey.self] }
        set { self[LayoutWheelGlassStandInKey.self] = newValue }
    }
}

/// Native glass and decoration only. This view cannot select or dispatch.
struct LayoutWheelGlassView: View {
    let input: LayoutWheelSceneInput
    var motion = LayoutWheelMotion()
    /// Tests can override strength without changing saved appearance.
    var strength: Double? = nil
    private var effectiveStrength: Double { strength ?? 0.30 }
    /// Plate opacity at strength 0, for the body and for the well. Tests sweep them.
    var plateFloor = LayoutWheelGlassTreatment.plateFloor
    var wellPlateFloor = LayoutWheelGlassTreatment.wellPlateFloor
    var reduceMotion = false
    var reduceTransparency = false
    var increasedContrast = false
    var cancelling = false
    var pulse = 0.0
    var labelPresentation: LayoutWheelLabelPresentation?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutWheelGlassStandIn) private var standIn
    @Namespace private var glassNamespace

    private var drawn: LayoutWheelDrawnMetrics { .init(input) }
    private var treatment: LayoutWheelGlassTreatment {
        .init(useLiquidGlass: input.appearance.useLiquidGlass && !cancelling,
              reduceTransparency: reduceTransparency, increasedContrast: increasedContrast)
    }
    /// The system appearance, which the presenter sets on the panel apart from
    /// BetterTile's Settings override. Ink follows it, not the backdrop: native
    /// glass never flips foreground, and measuring the backdrop would need
    /// Screen Recording. Contrast comes from the plate below.
    private var dark: Bool {
        switch input.configuration.appearance.surfacePreset {
        case .liquidGlass: colorScheme == .dark
        case .light: false
        case .dark: true
        }
    }
    private var ink: Color { dark ? .white.opacity(0.94) : .black.opacity(0.86) }
    private var solid: Color { Color(white: dark ? 0.18 : 0.96) }
    private var glass: Glass { .regular }
    /// Same recipe as the glass popups: the window background in this
    /// appearance over native glass. Floor 0.20, so 0.26 at 30 percent and
    /// 0.40 at 100.
    private var plateColor: Color {
        input.configuration.appearance.surfacePreset == .liquidGlass
            ? Color(nsColor: .windowBackgroundColor) : Color(white: dark ? 0.14 : 0.96)
    }
    private var plate: Color {
        plateColor.opacity(LayoutWheelGlassTreatment.plateOpacity(strength: effectiveStrength, floor: plateFloor))
    }
    /// The well's own plate. Its glass reads lighter than the ring.
    private var wellPlate: Color {
        plateColor.opacity(
            LayoutWheelGlassTreatment.wellPlateOpacity(strength: effectiveStrength, floor: wellPlateFloor))
    }
    private var center: CGPoint { .init(x: input.diameter / 2, y: input.diameter / 2) }
    private var hoverStrength: Double {
        // The existing spring targets 0.35 for every inner selection,
        // including Custom One's only ring. Normalize presentation only.
        input.selection?.ring == .inner ? motion.strength.value / 0.35 : motion.strength.value
    }
    var lean: BTPoint {
        drawn.lean(angle: motion.angle.value, strength: motion.lean.value, reduceMotion: reduceMotion)
    }
    private var innerHover: Bool { input.selection?.ring == .inner && drawn.levelCount == .two }
    var bulge: Double {
        drawn.bulge(fanOpen: input.fan.openSector != nil, inner: innerHover,
                    strength: hoverStrength,
                    reduceMotion: reduceMotion)
    }
    private var bodyShape: LayoutWheelBodyShape {
        .init(innerRadius: drawn.wellRadius, outerRadius: drawn.outerRadius,
              wellOffset: .init(width: -lean.x, height: -lean.y))
    }

    var body: some View {
        ZStack {
            bodyAndDecoration.offset(x: lean.x, y: lean.y)
            well
            ringForeground.offset(x: lean.x, y: lean.y)
        }
        .frame(width: input.diameter, height: input.diameter)
        .allowsHitTesting(false)
    }

    private var bodyAndDecoration: some View {
        ZStack {
            if treatment.useGlass {
                GlassEffectContainer(spacing: 14 * drawn.scale) {
                    ZStack {
                        Group {
                            if let standIn { bodyShape.fill(standIn.body) }
                            else { Color.clear.glassEffect(glass, in: bodyShape) }
                        }
                            .overlay(bodyShape.fill(plate))
                            .glassEffectID("body", in: glassNamespace)
                        if !innerHover && bulge > 0.01 {
                            let radius = 22 * drawn.scale
                            let point = drawn.point(radius: drawn.outerRadius - radius + bulge,
                                                    angle: motion.angle.value)
                            Circle().fill(.clear).frame(width: radius * 2, height: radius * 2)
                                .glassEffect(glass, in: Circle())
                                .glassEffectID("bulge", in: glassNamespace)
                                .position(x: center.x + point.x, y: center.y + point.y)
                        }
                    }
                }
                lighting
            } else {
                bodyShape.fill(solid)
                bodyShape.stroke(ink.opacity(0.22), lineWidth: 1)
            }
            separators
            step
        }
        .frame(width: input.diameter, height: input.diameter)
    }

    /// Draw above the fixed well and its overhang. An independent container
    /// keeps the accent lenses separate from both the body and the joined tag;
    /// effect identities alone do not prevent nearby glass shapes blending.
    private var ringForeground: some View {
        ZStack {
            if treatment.useGlass {
                GlassEffectContainer(spacing: 0) { lenses }
            } else {
                lenses
            }
            ringIcons
            chevrons
            // Fan geometry follows each sector's angles and spring. Droplet
            // sizing and morph identities describe each option.
            fanOptions
        }
        .frame(width: input.diameter, height: input.diameter)
    }

    private var lighting: some View {
        ZStack {
            bodyShape.stroke(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.04), .black.opacity(0.18)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: drawn.edgeWidth)
            Circle().stroke(.black.opacity(0.22), lineWidth: 3 * drawn.scale)
                .blur(radius: 2 * drawn.scale)
                .frame(width: drawn.wellRadius * 2, height: drawn.wellRadius * 2)
                .offset(x: -lean.x, y: -lean.y)
        }
    }

    @ViewBuilder private var step: some View {
        if let radius = drawn.stepRadius {
            let shape = LayoutWheelStepShape(radius: radius, angle: motion.angle.value,
                                             bulge: innerHover ? bulge : 0)
            if treatment.useGlass {
                shape.stroke(.black.opacity(0.22), lineWidth: 2 * drawn.scale)
                    .blur(radius: 1.5 * drawn.scale).offset(y: 1.5 * drawn.scale)
                shape.stroke(LinearGradient(colors: [.white.opacity(0.32), .black.opacity(0.13)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            } else {
                shape.stroke(ink.opacity(0.18), lineWidth: 1)
            }
        }
    }

    private var separators: some View {
        Canvas { context, _ in
            let opacity = treatment.separatorOpacity(dark: dark, fanOpen: input.fan.openSector != nil)
            for segment in drawn.separators {
                let start = CGPoint(x: center.x + segment.start.x, y: center.y + segment.start.y)
                let end = CGPoint(x: center.x + segment.end.x, y: center.y + segment.end.y)
                let fade = min(0.49, drawn.separatorFade / (segment.endRadius - segment.startRadius))
                var path = Path(); path.move(to: start); path.addLine(to: end)
                let separatorInk: Color = dark ? .white : .black
                context.stroke(path, with: .linearGradient(Gradient(stops: [
                    .init(color: .clear, location: 0), .init(color: separatorInk.opacity(opacity), location: fade),
                    .init(color: separatorInk.opacity(opacity), location: 1 - fade), .init(color: .clear, location: 1)
                ]), startPoint: start, endPoint: end), lineWidth: drawn.separatorWidth)
            }
        }
    }

    private var ringIcons: some View {
        ZStack {
            ForEach(input.configuration.activeRings, id: \.self) { ring in
                ForEach(LayoutWheelSector.allCases, id: \.self) { sector in
                    let selection = LayoutWheelSelection(ring: ring, sector: sector)
                    let id = LayoutWheelItemID.sector(selection)
                    let slot = input.slot(id)
                    let hover = motion.highlights[id]?.value ?? 0
                    let point = drawn.iconPoint(selection, symbol: slot.symbolName, hover: hover)
                    LayoutWheelIcon(slot: slot, tint: ink, fontSize: drawn.symbolSize(ring))
                        .frame(width: drawn.iconFrameSize(ring), height: drawn.iconFrameSize(ring))
                        .scaleEffect(1 + 0.08 * hover)
                        .opacity(iconOpacity(slot: slot, selection: selection))
                        .position(x: center.x + point.x, y: center.y + point.y)
                }
            }
        }
        .frame(width: input.diameter, height: input.diameter)
    }

    func iconOpacity(slot: LayoutWheelSlot, selection: LayoutWheelSelection) -> Double {
        let dimmed = input.fan.openSector != nil && !(selection.ring == input.configuration.groupRing && selection.sector == input.fan.openSector)
        return (slot.isAvailable ? 1 : 0.35) * (dimmed ? 0.42 : 1)
    }

    private var chevrons: some View {
        ZStack {
            if input.configuration.style == .grouped {
                ForEach(LayoutWheelSector.allCases, id: \.self) { sector in
                    let group = input.configuration.group(at: sector)
                    if !group.options.isEmpty && input.fan.openSector != sector {
                        let selection = LayoutWheelSelection(ring: input.configuration.groupRing, sector: sector)
                        let slot = input.slot(.sector(selection))
                        let point = drawn.chevronPoint(sector)
                        Image(systemName: "chevron.right")
                            .font(.system(size: drawn.chevronSize, weight: .semibold))
                            .foregroundStyle(ink)
                            .rotationEffect(.radians(sector.drawnCenterAngle.radians))
                            .opacity((slot.isAvailable ? 1 : 0.5) * (input.fan.openSector == nil ? 1 : 0.42))
                            .position(x: center.x + point.x, y: center.y + point.y)
                    }
                }
            }
        }
    }

    func lensRadius(_ selection: LayoutWheelSelection) -> Double {
        drawn.lensRadius(selection, lean: lean)
    }

    private var lenses: some View {
        ZStack {
            ForEach(input.configuration.activeRings, id: \.self) { ring in
                ForEach(LayoutWheelSector.allCases, id: \.self) { sector in
                    let selection = LayoutWheelSelection(ring: ring, sector: sector)
                    let id = LayoutWheelItemID.sector(selection)
                    let progress = max(0, min(1, motion.highlights[id]?.value ?? 0))
                    if progress > 0.001 {
                        let radius = lensRadius(selection)
                        let point = drawn.iconPoint(selection)
                        let available = input.slot(id).isAvailable
                        let color = available ? Color.accentColor : Color.gray
                        Circle().fill(treatment.useGlass ? color.opacity(0.06) : color)
                            .frame(width: radius * 2, height: radius * 2)
                            .modifier(WheelCircleGlass(enabled: treatment.useGlass, glass: .regular.tint(color.opacity(0.5))))
                            .overlay(Circle().stroke(.white.opacity(0.3 + 0.12 * pulse), lineWidth: drawn.lensOutlineWidth))
                            .opacity(progress)
                            .position(x: center.x + point.x, y: center.y + point.y)
                    }
                }
            }
        }
    }

    private var well: some View {
        let presentation = labelPresentation ?? LayoutWheelLabelPresentation(input)
        let space = presentation.space
        let content = input.centreContent
        let label = presentation.label
        let shape = presentation.shape
        return GlassEffectContainer(spacing: 0) {
            ZStack {
                if let label {
                    LayoutWheelLabelText(label: label)
                        .foregroundStyle(ink)
                        .opacity(content?.available == false ? 0.6 : 1)
                    if content?.available == false {
                        Image(systemName: "slash.circle")
                            .font(.system(size: space.markSize, weight: .semibold))
                            .foregroundStyle(ink.opacity(0.8))
                            .frame(width: space.markSize, height: space.markSize)
                            .offset(y: space.markFrame.midY)
                    }
                } else {
                    VStack(spacing: 3 * drawn.scale) {
                        Image(systemName: "xmark")
                            .font(.system(size: max(9, 8.8 * drawn.scale), weight: .semibold))
                        Text("Cancel")
                            .font(.system(size: max(9, 9.5 * drawn.scale), weight: .medium))
                    }
                    .foregroundStyle(ink)
                }
            }
            .frame(width: presentation.size.width, height: presentation.size.height)
            // Native glass captures this view's content. Keep every ink layer
            // inside the modified view rather than beside a glass-filled shape.
            .background(treatment.useGlass ? wellPlate : Color(white: dark ? 0.12 : 0.91), in: shape)
            .modifier(WheelWellGlass(enabled: treatment.useGlass, glass: glass,
                                     shape: shape, standIn: standIn?.well))
            .overlay(shape.stroke(ink.opacity(treatment.useGlass ? 0.16 : 0.22), lineWidth: 1).clipShape(shape))
            .glassEffectID("well", in: glassNamespace)
        }
    }

    private var fanOptions: some View {
        ZStack {
            ForEach(LayoutWheelSector.allCases, id: \.self) { sector in
                let reveal = max(0, motion.reveals[sector.rawValue].value)
                if reveal > 0.001 && input.configuration.style == .grouped {
                    ForEach(Array(input.configuration.group(at: sector).options.indices), id: \.self) { index in
                        fanOption(sector, index: index, reveal: reveal)
                    }
                }
            }
        }
    }

    private func fanOption(_ sector: LayoutWheelSector, index: Int, reveal: Double) -> some View {
        let id = LayoutWheelItemID.option(sector, index)
        let slot = input.slot(id)
        let selected = motion.highlights[id]?.value ?? 0
        let target = input.metrics.fanGeometry(for: input.configuration).point(sector: sector, option: index)
        let origin = drawn.iconPoint(.init(ring: input.configuration.groupRing, sector: sector))
        let progress = reduceMotion ? 1 : reveal
        let point = BTPoint(x: origin.x + (target.x - origin.x) * progress,
                            y: origin.y + (target.y - origin.y) * progress)
        return LayoutWheelIcon(slot: slot, tint: ink, fontSize: 18 * drawn.scale)
            .frame(width: 35 * drawn.scale, height: 35 * drawn.scale)
            .frame(width: 48 * drawn.scale, height: 48 * drawn.scale)
            .background(treatment.useGlass ? (selected > 0.5 ? Color.clear : plate)
                                           : (selected > 0.5 ? Color.accentColor : solid), in: Circle())
            .modifier(WheelCircleGlass(enabled: treatment.useGlass,
                glass: selected > 0.5 ? .regular.tint(Color.accentColor.opacity(0.5)) : glass, standIn: standIn?.body))
            .scaleEffect(1 + 0.1 * selected)
            .opacity(min(1, reveal) * (slot.isAvailable ? 1 : 0.35))
            .position(x: center.x + point.x, y: center.y + point.y)
    }
}

/// One outline gives the overhang the same native glass and plate as the well.
/// Recess lighting remains on the circular well in the body decoration.
struct LayoutWheelWellShape: Shape {
    var tagSize: CGSize?
    private(set) var cachedOutline: Path?
    private var cachedSize = CGSize.zero

    init(tagSize: CGSize?) {
        self.tagSize = tagSize
    }

    func cached(in size: CGSize) -> Self {
        var copy = self
        copy.cachedOutline = path(in: CGRect(origin: .zero, size: size))
        copy.cachedSize = size
        return copy
    }

    func path(in rect: CGRect) -> Path {
        if let cachedOutline, cachedSize.width > 0, cachedSize.height > 0 {
            return cachedOutline.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: rect.width / cachedSize.width, y: rect.height / cachedSize.height))
        }
        let diameter = min(rect.width, rect.height)
        let well = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                          width: diameter, height: diameter)
        let circle = Path(ellipseIn: well)
        guard let tagSize else { return circle }
        let tag = CGRect(x: rect.midX - tagSize.width / 2, y: rect.midY - tagSize.height / 2,
                         width: tagSize.width, height: tagSize.height)
        return circle.union(Path(roundedRect: tag, cornerRadius: tagSize.height / 2))
    }
}

/// One immutable preparation per semantic input. Animation frames reuse the
/// first-ring ink boxes, measured lines and joined glass outline.
@MainActor final class LayoutWheelLabelPresentation {
    #if BETTERTILE_TEST_HOOKS
    /// Lets offscreen tests detect preparation accidentally moved into a frame.
    private(set) static var preparationCount = 0
    #endif
    let space: LayoutWheelLabelSpace
    let label: LayoutWheelCentreLabel?
    let tagSize: CGSize?
    let size: CGSize
    let shape: LayoutWheelWellShape

    init(_ input: LayoutWheelSceneInput) {
        #if BETTERTILE_TEST_HOOKS
        Self.preparationCount += 1
        #endif
        let space = LayoutWheelLabelSpace(input)
        let label = input.centreContent.map {
            LayoutWheelCentreLabel(name: $0.name, mainAction: $0.mainAction, space: space)
        }
        let tagSize = label.flatMap { label in
            label.usesTag ? CGSize(
                width: min(label.width + 2 * space.horizontalPadding,
                           space.tagWidthLimit(height: label.height + 2 * space.verticalPadding)),
                height: label.height + 2 * space.verticalPadding) : nil
        }
        let size = CGSize(width: max(space.wellRadius * 2, tagSize?.width ?? 0), height: space.wellRadius * 2)
        self.space = space; self.label = label; self.tagSize = tagSize; self.size = size
        shape = LayoutWheelWellShape(tagSize: tagSize).cached(in: size)
    }
}

/// Fixed, measured lines prevent SwiftUI from choosing a different wrap or
/// compressing a line after the fit pass. The font is the measured NSFont.
struct LayoutWheelLabelText: View {
    let label: LayoutWheelCentreLabel
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(label.lines.enumerated()), id: \.offset) { _, line in
                Text(line.text).font(Font(line.font))
                    .fixedSize()
                    .frame(height: line.height)
            }
        }
    }
}

private struct WheelWellGlass: ViewModifier {
    let enabled: Bool
    let glass: Glass
    let shape: LayoutWheelWellShape
    var standIn: Color?
    @ViewBuilder func body(content: Content) -> some View {
        if enabled, let standIn { content.background(shape.fill(standIn)) }
        else if enabled { content.glassEffect(glass, in: shape) }
        else { content }
    }
}

private struct WheelCircleGlass: ViewModifier {
    let enabled: Bool
    let glass: Glass
    var standIn: Color?
    @ViewBuilder func body(content: Content) -> some View {
        if enabled, let standIn { content.background(Circle().fill(standIn)) }
        else if enabled { content.glassEffect(glass, in: Circle()) }
        else { content }
    }
}

/// The system display options the wheel follows. Tests inject their own.
struct LayoutWheelDisplayOptions: Equatable, Sendable {
    var reduceMotion: Bool
    var reduceTransparency: Bool
    var increaseContrast: Bool
    @MainActor static var system: Self {
        let workspace = NSWorkspace.shared
        return .init(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                     reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                     increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
    }
}

/// Owns the existing event-driven cosmetic clock. The hosted SwiftUI tree has
/// no independent animation or timeline, and is removed at close.
@MainActor final class LayoutWheelGlassRenderer: NSView {
    private(set) var hosting: NSHostingView<LayoutWheelGlassView>?
    private(set) var input: LayoutWheelSceneInput?
    private(set) var labelPresentation: LayoutWheelLabelPresentation?
    private(set) var motion = LayoutWheelMotion()
    private(set) var exitPresentation: LayoutWheelExitPresentation?
    private(set) var renderedFrameCount = 0
    private let clock: any LayoutWheelFrameClock
    /// Read when a caller passes no explicit option and on every system change.
    var displayOptions: @MainActor () -> LayoutWheelDisplayOptions = { .system }
    private var running = false
    private var generation = 0
    private var lastTimestamp: Double?
    private var completion: (() -> Void)?
    private(set) var reduceMotion = false
    private(set) var reduceTransparency = false
    private(set) var increasedContrast = false
    var isClockRunning: Bool { clock.isRunning }
    var usesGlass: Bool {
        guard let input else { return false }
        return LayoutWheelGlassTreatment(useLiquidGlass: input.appearance.useLiquidGlass,
            reduceTransparency: reduceTransparency, increasedContrast: increasedContrast).useGlass
            && exitPresentation?.acknowledgment != .cancel
    }
    var exitScale: Double {
        guard let input, let exitPresentation else { return 1 }
        let drawn = LayoutWheelDrawnMetrics(input)
        return 1 - exitPresentation.collapse * (1 - drawn.wellRadius / drawn.outerRadius)
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { .init(width: input?.diameter ?? 0, height: input?.diameter ?? 0) }

    init(clock: any LayoutWheelFrameClock = LayoutWheelDisplayClock()) {
        self.clock = clock
        super.init(frame: .zero)
        wantsLayer = true
        // Apply the commit alpha once after glass, decorations and ink compose.
        layer?.allowsGroupOpacity = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { clock.stop() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ next: LayoutWheelSceneInput, reduceMotion: Bool? = nil,
                   reduceTransparency: Bool? = nil, increasedContrast: Bool? = nil, newOpen: Bool = false) {
        guard running || newOpen || input == nil else { return }
        let system = displayOptions()
        let rm = reduceMotion ?? system.reduceMotion
        if !newOpen, exitPresentation != nil {
            if rm { completeExit() }
            return
        }
        let rt = reduceTransparency ?? system.reduceTransparency
        let ic = increasedContrast ?? system.increaseContrast
        guard newOpen || !running || input != next || self.reduceMotion != rm
                || self.reduceTransparency != rt || self.increasedContrast != ic else { return }
        if newOpen || !running {
            stop(); running = true; motion = .init(); exitPresentation = nil
        }
        if input != next || labelPresentation == nil {
            labelPresentation = LayoutWheelLabelPresentation(next)
        }
        input = next; self.reduceMotion = rm; self.reduceTransparency = rt; self.increasedContrast = ic
        frame.size = intrinsicContentSize
        invalidateIntrinsicContentSize()
        motion.retarget(selection: next.selection, fan: next.fan, geometry: next.metrics.fanGeometry(for: next.configuration),
                        reduceMotion: rm, suppressLean: labelPresentation?.label?.usesTag == true,
                        openParent: next.fan.openSector.map { .init(ring: next.configuration.groupRing, sector: $0) })
        render(); schedule()
    }

    func stop() {
        running = false; generation += 1; clock.stop(); lastTimestamp = nil; completion = nil
        hosting?.removeFromSuperview(); hosting = nil
    }

    func beginExit(_ acknowledgment: LayoutWheelAcknowledgment, completion: @escaping () -> Void) {
        guard running, input != nil, exitPresentation == nil else { return }
        generation += 1; clock.stop(); lastTimestamp = nil
        exitPresentation = .init(acknowledgment: acknowledgment)
        self.completion = completion
        motion.snap()
        if reduceMotion { completeExit() } else { render(); schedule() }
    }

    private func schedule() {
        if !running || reduceMotion || (exitPresentation.map(\.isComplete) ?? motion.isAtRest) {
            clock.stop(); lastTimestamp = nil
        } else if !clock.isRunning {
            generation += 1
            let captured = generation
            clock.start(on: self) { [weak self] time in
                guard let self, self.generation == captured, self.running, time.isFinite else { return }
                let dt = self.lastTimestamp.map { time - $0 } ?? 1 / 60
                guard dt > 0 else { return }
                self.lastTimestamp = time
                if self.exitPresentation != nil { self.exitPresentation?.advance(dt) }
                else { self.motion.advance(dt) }
                if self.exitPresentation?.isComplete == true { self.completeExit() }
                else { self.render(); self.schedule() }
            }
        }
    }

    private func render() {
        guard let input else { return }
        renderedFrameCount += 1
        let view = LayoutWheelGlassView(input: input, motion: motion, reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency, increasedContrast: increasedContrast,
            cancelling: exitPresentation?.acknowledgment == .cancel, pulse: exitPresentation?.pulse ?? 0,
            labelPresentation: labelPresentation)
        if let hosting { hosting.rootView = view }
        else {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = bounds; hosting.autoresizingMask = [.width, .height]
            self.hosting = hosting; addSubview(hosting)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.opacity = Float(exitPresentation?.opacity ?? 1)
        // The native material is replaced by opaque shapes before any cancel
        // transform. No stationary backdrop remains outside the shrinking body.
        hosting?.wantsLayer = true
        hosting?.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        hosting?.layer?.position = CGPoint(x: bounds.midX, y: bounds.midY)
        hosting?.layer?.transform = CATransform3DMakeScale(exitScale, exitScale, 1)
        CATransaction.commit()
    }

    private func completeExit() {
        guard exitPresentation != nil else { return }
        let duration = exitPresentation?.duration ?? 0
        exitPresentation?.advance(duration)
        let callback = completion
        stop(); layer?.opacity = 0
        callback?()
    }
    @objc private func displayOptionsChanged() { if running, let input { configure(input) } }
}

struct LayoutWheelNativeSurface: NSViewRepresentable {
    let input: LayoutWheelSceneInput
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool
    var retainedRenderer: LayoutWheelGlassRenderer?
    func makeNSView(context: Context) -> LayoutWheelGlassRenderer { retainedRenderer ?? LayoutWheelGlassRenderer() }
    func updateNSView(_ view: LayoutWheelGlassRenderer, context: Context) {
        view.configure(input, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency,
                       increasedContrast: increasedContrast)
    }
    static func dismantleNSView(_ view: LayoutWheelGlassRenderer, coordinator: ()) { view.stop() }
}
