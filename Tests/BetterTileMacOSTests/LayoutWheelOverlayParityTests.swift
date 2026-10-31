import AppKit
import Metal
import SwiftUI
import Testing
@_spi(LiquidWheelPrototype) @testable import BetterTileCore
@_spi(LiquidWheelPrototype) @testable import BetterTileMacOS

/// Forwards to the real adapter and records what the controller last presented.
@MainActor final class OverlayPresentationSpy: LayoutWheelPresenting {
    let adapter: LayoutWheelLiquidAdapter
    var last: LayoutWheelPresentation?
    /// A guarded check changes what the controller presents, to prove the comparison would notice.
    var mutate: ((inout LayoutWheelPresentation) -> Void)?
    init(_ adapter: LayoutWheelLiquidAdapter) { self.adapter = adapter }
    private func forwarded(_ presentation: LayoutWheelPresentation) -> LayoutWheelPresentation {
        var copy = presentation
        mutate?(&copy)
        return copy
    }
    var usesLiquidGeometry: Bool { adapter.usesLiquidGeometry }
    var presentationFailureHandler: (@MainActor () -> Void)? {
        get { adapter.presentationFailureHandler }
        set { adapter.presentationFailureHandler = newValue }
    }
    func prewarm(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) {
        adapter.prewarm(configuration: configuration, appearance: appearance)
    }
    func prepareToOpen(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) {
        adapter.prepareToOpen(configuration: configuration, appearance: appearance)
    }
    func beginGesture() { adapter.beginGesture() }
    func discardPreparation() { adapter.discardPreparation() }
    func open(_ presentation: LayoutWheelPresentation) { last = presentation; adapter.open(forwarded(presentation)) }
    func update(_ presentation: LayoutWheelPresentation) { last = presentation; adapter.update(forwarded(presentation)) }
    func showPlacements(_ placements: [Placement]) { adapter.showPlacements(placements) }
    func hidePlacements() { adapter.hidePlacements() }
    func close() { adapter.close() }
    func end(_ acknowledgment: LayoutWheelAcknowledgment) { adapter.end(acknowledgment) }
}

/// The real gesture, through the controller and the adapter, drawn offscreen.
@MainActor final class OverlayFlow {
    let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
    let spy: OverlayPresentationSpy
    let controller: LayoutWheelController
    var pointer = BTPoint(x: -29_200, y: -29_500)
    private final class Time { var value = 0.0 }
    private let clock = Time()
    var time: Double { get { clock.value } set { clock.value = newValue } }
    let anchor: BTPoint
    let content: LayoutWheelLiquidContent

    init(wheel: LayoutWheelConfiguration, appearance: OverlayAppearance = .init(), deferOpening: Bool = false) {
        spy = OverlayPresentationSpy(LayoutWheelLiquidAdapter(renderer: renderer))
        anchor = pointer
        content = LayoutWheelLiquidDefaults.content(configuration: wheel, currentMode: .tabbed)
        controller = LayoutWheelController(
            configuration: .init(overlayAppearance: appearance, layoutWheel: wheel), presenter: spy,
            now: { [clock] in clock.value }, pointerProvider: { .init(x: -29_200, y: -29_500) },
            addGlobalMonitor: { _, _ in NSObject() }, addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.captureHandler = { _ in
            .init(windowID: .init(rawValue: "w"), displayID: .init(rawValue: "d"),
                  visibleFrame: .init(x: -30_000, y: -30_000, width: 1600, height: 1000), layoutMode: .tabbed)
        }
        controller.previewHandler = { _, _ in .ready(placements: []) }
        controller.start()
        if !deferOpening { hold() }
    }

    private var generation = 0
    /// Holds the chord and lets the hold finish, which opens the wheel.
    func hold() {
        generation += 1
        controller.handleModifiers([.control, .option, .shift])
        controller.handleActivationDeadline(generation: generation)
    }
    /// Releases the chord. A wheel with nothing selected ends without a command.
    func release() { controller.handleModifiers([]) }

    private func middleClick(_ kind: LayoutWheelMiddleClickEventKind) {
        controller.handleMiddleClick(.init(kind: kind, position: anchor, button: 2, modifiers: [], timestamp: 0))
    }
    /// Starts a gesture with the middle button, with no hold and no earlier preparation.
    func middleDown() { middleClick(.down) }
    func middleUp() { middleClick(.up) }

    func move(_ vector: BTPoint) {
        controller.handlePointer(.init(x: anchor.x + vector.x, y: anchor.y + vector.y))
    }
    var presentation: LayoutWheelPresentation? { spy.last }
    func stop() { controller.stop() }
}

/// The Settings preview as the Settings page drives it: SwiftUI hosts `LayoutWheelLiquidPreview`, and the
/// page's own hover geometry turns a pointer vector into a selection and a fan. Nothing is copied from the overlay.
@MainActor final class PreviewFlow {
    let wheel: LayoutWheelConfiguration
    let appearance: OverlayAppearance
    private let hosting: NSHostingView<LayoutWheelLiquidPreview>
    private(set) var coordinator: LayoutWheelLiquidPreview.Coordinator?
    private var fan = LayoutWheelFanState()
    private var selection: LayoutWheelSelection?
    private var pointer: BTPoint?
    /// A guarded check changes what the page passes in, to prove the comparison would notice.
    var mutate: ((inout LayoutWheelConfiguration, inout LayoutWheelSelection?, inout LayoutMode?) -> Void)?
    var mode: LayoutMode? = .tabbed

    init(wheel: LayoutWheelConfiguration, appearance: OverlayAppearance = .init()) {
        self.wheel = wheel
        self.appearance = appearance
        var created: LayoutWheelLiquidPreview.Coordinator?
        LayoutWheelLiquidPreview.coordinatorCreatedForTesting = { created = $0 }
        defer { LayoutWheelLiquidPreview.coordinatorCreatedForTesting = nil }
        hosting = NSHostingView(rootView: LayoutWheelLiquidPreview(configuration: wheel, overlayAppearance: appearance,
            selection: nil, fan: .init(), pointer: nil, currentMode: .tabbed, playback: nil, modeChanged: { _ in }))
        let diameter = LayoutWheelPreviewGeometry(configuration: wheel, mode: .liquid).diameter
        hosting.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        hosting.layoutSubtreeIfNeeded()
        coordinator = created
    }

    /// The page's `update(_:)`: a hover over the preview.
    func hover(_ vector: BTPoint, at time: Double) {
        let geometry = LayoutWheelPreviewGeometry(configuration: wheel, mode: .liquid)
        selection = geometry.update(vector: vector, at: time, fan: &fan)
        pointer = vector
        render()
    }

    private func render() {
        var configuration = wheel, selection = selection, mode = mode
        mutate?(&configuration, &selection, &mode)
        hosting.rootView = LayoutWheelLiquidPreview(configuration: configuration, overlayAppearance: appearance,
            selection: selection, fan: fan, pointer: pointer, currentMode: mode, playback: nil, modeChanged: { _ in })
        hosting.layoutSubtreeIfNeeded()
    }

    var renderer: LayoutWheelLiquidPresenter? { coordinator?.renderer }
    func stop() {
        if let coordinator { LayoutWheelLiquidPreview.dismantleNSView(hosting, coordinator: coordinator) }
    }
}

@MainActor enum ParityRender {
    /// The largest per-channel difference, and the count of pixels that differ by more than `tolerance`.
    static func difference(_ a: CGImage, _ b: CGImage, tolerance: Int = 2) -> (maximum: Int, count: Int)? {
        guard a.width == b.width, a.height == b.height,
              let da = a.dataProvider?.data as Data?, let db = b.dataProvider?.data as Data? else { return nil }
        var maximum = 0, count = 0
        var index = 0
        let pixels = a.width * a.height
        while index < pixels {
            var worst = 0
            for channel in 0..<4 { worst = max(worst, abs(Int(da[index * 4 + channel]) - Int(db[index * 4 + channel]))) }
            maximum = max(maximum, worst)
            if worst > tolerance { count += 1 }
            index += 1
        }
        return (maximum, count)
    }
}

/// The real overlay gesture and the Settings live preview draw one wheel. The preview is the reference.
///
/// Both go through the same renderer, the same configuration function and the same scene builders. These
/// tests drive each path as it is driven in the app, draw it offscreen in the same state, at the same size
/// and scale, and compare the pixels, the content and the state.
@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelOverlayParityTests {
    enum Stage: String, CaseIterable, Sendable { case opened, outerHovered, optionAimed }

    struct Case: Sendable, CustomStringConvertible {
        var style: LayoutWheelStyle = .grouped
        var levels: LayoutWheelLevelCount = .two
        var appearance: LayoutWheelLiquidSettings.Appearance = .dark
        var highlight: LayoutWheelLiquidSettings.HighlightColour = .iceBlue
        var actionTint = false
        var glass = true
        var stage: Stage
        var description: String {
            "\(style) \(levels) \(appearance) \(highlight) actionTint=\(actionTint) glass=\(glass) \(stage)"
        }
    }

    nonisolated static let cases: [Case] = {
        var result: [Case] = []
        // Appearance and stage, in the Grouped wheel.
        for stage in Stage.allCases {
            for appearance in [LayoutWheelLiquidSettings.Appearance.dark, .light, .system] {
                result.append(.init(appearance: appearance, stage: stage))
            }
        }
        // Every highlight style, with and without Action tint.
        for highlight in LayoutWheelLiquidSettings.HighlightColour.allCases {
            for actionTint in [false, true] {
                for stage in [Stage.outerHovered, .optionAimed] {
                    result.append(.init(highlight: highlight, actionTint: actionTint, stage: stage))
                }
            }
        }
        // The default wheel (Custom, System appearance), One and Two Levels, and Grouped One Level.
        for (style, levels) in [(LayoutWheelStyle.custom, LayoutWheelLevelCount.two), (.custom, .one), (.grouped, .one)] {
            for stage in Stage.allCases where style == .grouped || stage != .optionAimed {
                result.append(.init(style: style, levels: levels, appearance: .system, stage: stage))
                result.append(.init(style: style, levels: levels, appearance: .system, actionTint: true, stage: stage))
            }
        }
        // The opaque fallback (liquid glass off).
        for (style, levels) in [(LayoutWheelStyle.custom, LayoutWheelLevelCount.two), (.grouped, .two)] {
            for stage in [Stage.opened, .outerHovered] {
                result.append(.init(style: style, levels: levels, appearance: .system, glass: false, stage: stage))
            }
        }
        return result
    }()

    private func wheel(_ item: Case) -> LayoutWheelConfiguration {
        var wheel = LayoutWheelConfiguration(style: item.style, levelCount: item.levels)
        wheel.appearance.liquid.appearance = item.appearance
        wheel.appearance.liquid.look.highlightColour = item.highlight
        wheel.appearance.liquid.look.actionTint = item.actionTint
        return wheel
    }

    private func overlayAppearance(_ item: Case) -> OverlayAppearance {
        var appearance = OverlayAppearance()
        appearance.useLiquidGlass = item.glass
        return appearance
    }

    /// Both paths, driven with the same pointer vectors and times.
    private func driveBoth(_ item: Case, overlay: OverlayFlow, preview: PreviewFlow) throws {
        let layout = overlay.content.layout
        let radius = try #require(layout.iconRadii.last)
        let angle = layout.slotAngle(LayoutWheelSector.top.rawValue)
        guard item.stage != .opened else { return }
        let onTop = BTPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        overlay.move(onTop)
        preview.hover(onTop, at: 0)
        guard item.stage == .optionAimed else { return }
        overlay.time = 0.25
        overlay.controller.handleFanDeadline()
        preview.hover(onTop, at: 0.25)
        let option = try #require(overlay.content.submenuLayout).positions(sector: .top, count: 4)[1]
        overlay.time = 0.26
        overlay.move(option)
        preview.hover(option, at: 0.26)
    }

    private struct Comparison {
        var differingPixels = 0
        var maximumDifference = 0
        var contentEqual = false
        var stateEqual = false
        var labelsAgree = false
        var isClean: Bool { differingPixels == 0 && contentEqual && stateEqual && labelsAgree }
    }

    private func compare(_ overlay: LayoutWheelLiquidPresenter, _ preview: LayoutWheelLiquidPresenter,
                         _ name: String) throws -> Comparison {
        overlay.settleForTesting(); preview.settleForTesting()
        var result = Comparison()
        result.contentEqual = overlay.contentForTesting == preview.contentForTesting
        // The overlay measures the pointer from a far-away anchor, so its vector can differ in the last digits.
        let sa = overlay.stateForTesting, sb = preview.stateForTesting
        let pointersMatch: Bool
        switch (sa.pointer, sb.pointer) {
        case (nil, nil): pointersMatch = true
        case let (pa?, pb?): pointersMatch = abs(pa.x - pb.x) < 1e-6 && abs(pa.y - pb.y) < 1e-6
        default: pointersMatch = false
        }
        result.stateEqual = pointersMatch && sa.selection == sb.selection && sa.openSector == sb.openSector
            && sa.aimedOption == sb.aimedOption
        let a = try #require(overlay.offscreenImageForTesting(), "overlay image \(name)")
        let b = try #require(preview.offscreenImageForTesting(), "preview image \(name)")
        #expect(a.width == b.width && a.height == b.height, "size \(name)")
        let difference = try #require(ParityRender.difference(a, b, tolerance: 1), "comparison \(name)")
        result.differingPixels = difference.count
        result.maximumDifference = difference.maximum
        // Both sides have a centre name, or neither does.
        switch (overlay.labelImageForTesting, preview.labelImageForTesting) {
        case (nil, nil): result.labelsAgree = true
        case let (la?, lb?): result.labelsAgree = (ParityRender.difference(la, lb, tolerance: 1)?.count ?? 1) == 0
        default: result.labelsAgree = false
        }
        return result
    }

    @Test(arguments: cases) func overlayAndPreviewDrawTheSamePixels(item: Case) throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let wheel = wheel(item)
        let overlay = OverlayFlow(wheel: wheel, appearance: overlayAppearance(item))
        defer { overlay.stop() }
        let preview = PreviewFlow(wheel: wheel, appearance: overlayAppearance(item))
        defer { preview.stop() }
        try driveBoth(item, overlay: overlay, preview: preview)
        #expect(overlay.controller.isOpen && overlay.spy.usesLiquidGeometry, "\(item): the overlay uses the liquid renderer")
        let previewRenderer = try #require(preview.renderer)
        let comparison = try compare(overlay.renderer, previewRenderer, item.description)
        #expect(comparison.differingPixels == 0,
                "\(item): \(comparison.differingPixels) pixels differ, by up to \(comparison.maximumDifference)/255")
        #expect(comparison.contentEqual, "\(item): the two sides built different content")
        #expect(comparison.stateEqual, "\(item): the two sides built different state")
        #expect(comparison.labelsAgree, "\(item): the centre name differs")
    }

    @Test func bothPathsReadTheSameConfigurationValues() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        for item in Self.cases {
            let wheel = wheel(item)
            let overlay = OverlayFlow(wheel: wheel, appearance: overlayAppearance(item))
            defer { overlay.stop() }
            let preview = PreviewFlow(wheel: wheel, appearance: overlayAppearance(item))
            defer { preview.stop() }
            let previewRenderer = try #require(preview.renderer)
            #expect(overlay.renderer.configurationValuesForTesting == previewRenderer.configurationValuesForTesting, "\(item)")
        }
    }

    // MARK: Guarded checks: the comparison notices a side that diverges

    private func divergent(_ change: (OverlayFlow, PreviewFlow) -> Void) throws -> Comparison {
        let item = Case(stage: .outerHovered)
        let wheel = wheel(item)
        let overlay = OverlayFlow(wheel: wheel)
        defer { overlay.stop() }
        let preview = PreviewFlow(wheel: wheel)
        defer { preview.stop() }
        change(overlay, preview)
        try driveBoth(item, overlay: overlay, preview: preview)
        return try compare(overlay.renderer, try #require(preview.renderer), "divergent")
    }

    @Test func theComparisonIsCleanWithoutAMutation() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        #expect(try divergent { _, _ in }.isClean)
    }

    @Test func theComparisonNoticesAnOverlayThatBuildsDifferentContent() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        // The overlay's scene marks a command unavailable that the preview draws as available.
        let result = try divergent { overlay, _ in
            overlay.spy.mutate = { $0.unavailableCommands.insert(.windowAction(.maximize)) }
        }
        #expect(!result.isClean && !result.contentEqual)
    }

    @Test func theComparisonNoticesAnOverlayThatBuildsDifferentState() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let result = try divergent { overlay, _ in
            overlay.spy.mutate = { $0.selection = .init(ring: .outer, sector: .bottom) }
        }
        #expect(!result.isClean && (!result.stateEqual || result.differingPixels > 0))
    }

    @Test func theComparisonNoticesAPreviewThatBuildsDifferentContent() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let result = try divergent { _, preview in preview.mode = .manual }
        #expect(!result.isClean)
    }

    @Test func theComparisonNoticesAPreviewThatBuildsDifferentState() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let result = try divergent { _, preview in
            preview.mutate = { _, selection, _ in selection = .init(ring: .outer, sector: .bottom) }
        }
        #expect(!result.isClean && (!result.stateEqual || result.differingPixels > 0))
    }

    @Test func bothPathsAimTheSubmenuTheSameWay() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let flow = OverlayFlow(wheel: wheel)
        defer { flow.stop() }
        let geometry = LayoutWheelPreviewGeometry(configuration: wheel, mode: .liquid)
        let layout = flow.content.layout
        let radius = try #require(layout.iconRadii.last)
        let angle = layout.slotAngle(LayoutWheelSector.top.rawValue)
        let onTop = BTPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        let options = try #require(flow.content.submenuLayout).positions(sector: .top, count: 4)
        let hub = BTPoint(x: 2, y: 2)
        let beyond = BTPoint(x: onTop.x * 2.6, y: onTop.y * 2.6)
        let script: [(String, BTPoint, Double)] = [
            ("ring", onTop, 0.0), ("hold", onTop, 0.25), ("option", options[1], 0.26),
            ("next option", options[2], 0.27), ("beyond the rim", beyond, 0.30), ("hub", hub, 0.35),
        ]
        var fan = LayoutWheelFanState()
        for (name, vector, at) in script {
            flow.time = at
            flow.move(vector)
            if at >= 0.2 { flow.controller.handleFanDeadline() }
            var selection = geometry.update(vector: vector, at: at, fan: &fan)
            // The preview re-aims at the hold deadline, as its timer does.
            if name == "hold" { selection = geometry.update(vector: vector, at: at, fan: &fan) }
            let presented = try #require(flow.presentation)
            #expect(presented.fan.openSector == fan.openSector, "\(name): open group")
            #expect(presented.fan.optionIndex == fan.optionIndex, "\(name): aimed option")
            #expect(presented.selection == selection, "\(name): selection")
        }
    }

    @Test func aFailedPreparationDoesNotLeaveTheOverlayOnTheFallback() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        wheel.appearance.liquid.look.actionTint = true
        let flow = OverlayFlow(wheel: wheel, deferOpening: true)
        defer { flow.stop() }
        // The first hold cannot build its atlas, so that gesture uses the panel.
        var failing = true
        let real = flow.renderer.makeAtlas
        flow.renderer.makeAtlas = { device, entries, scale in failing ? nil : real(device, entries, scale) }
        flow.hold()
        #expect(!flow.spy.usesLiquidGeometry, "the failed gesture falls back to the panel")
        flow.release()
        // Later gestures draw through the same renderer as the Settings preview.
        failing = false
        flow.hold()
        #expect(flow.controller.isOpen, "the second hold opens the wheel")
        #expect(flow.spy.usesLiquidGeometry, "the next gesture uses the liquid renderer again")
        let preview = PreviewFlow(wheel: wheel)
        defer { preview.stop() }
        let item = Case(actionTint: true, stage: .outerHovered)
        try driveBoth(item, overlay: flow, preview: preview)
        let comparison = try compare(flow.renderer, try #require(preview.renderer), "after a failed preparation")
        #expect(comparison.isClean)
    }

    @Test func aMiddleClickGestureAfterAFailedOneUsesTheLiquidRenderer() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        wheel.triggers.mouse = .middleClick
        wheel.triggers.keyboardEnabled = false
        let flow = OverlayFlow(wheel: wheel, deferOpening: true)
        defer { flow.stop() }
        var failing = true
        let real = flow.renderer.makeAtlas
        flow.renderer.makeAtlas = { device, entries, scale in failing ? nil : real(device, entries, scale) }
        // A mouse-only user: the first gesture cannot open the liquid wheel and uses the panel.
        flow.middleDown()
        #expect(flow.controller.isOpen && !flow.spy.usesLiquidGeometry)
        flow.middleUp()
        #expect(!flow.controller.isOpen)
        // No hold ever runs, so only the start of the next gesture can retry.
        failing = false
        flow.middleDown()
        #expect(flow.controller.isOpen)
        #expect(flow.spy.usesLiquidGeometry, "the next middle-click gesture uses the liquid renderer")
        #expect(flow.renderer.isOpen)
        flow.middleUp()
    }

    @Test func aCancelledHoldDoesNotLeaveItsFallbackForTheNextGesture() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        wheel.triggers.mouse = .middleClick
        let flow = OverlayFlow(wheel: wheel, deferOpening: true)
        defer { flow.stop() }
        var failing = true
        let real = flow.renderer.makeAtlas
        flow.renderer.makeAtlas = { device, entries, scale in failing ? nil : real(device, entries, scale) }
        // A keyboard hold fails to prepare and is cancelled before the wheel opens.
        flow.controller.handleModifiers([.control, .option, .shift])
        #expect(flow.controller.isPendingActivation && !flow.spy.usesLiquidGeometry)
        flow.controller.cancelPendingActivation()
        flow.release()
        failing = false
        flow.middleDown()
        #expect(flow.controller.isOpen && flow.spy.usesLiquidGeometry)
        flow.middleUp()
    }
}
