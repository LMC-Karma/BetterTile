import AppKit
import Foundation
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

// Seeded property tests for Layout Wheel gesture and selection semantics.
// Set LAYOUT_WHEEL_FUZZ_SEED and LAYOUT_WHEEL_FUZZ_CASES to explore further.

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ lower: Double, _ upper: Double) -> Double { lower + (upper - lower) * unit() }
    mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
    mutating func chance(_ probability: Double) -> Bool { unit() < probability }
}

@MainActor private final class FuzzPresenter: LayoutWheelPresenting {
    var usesLiquidGeometry = false
    var presentations: [LayoutWheelPresentation] = []
    func open(_ presentation: LayoutWheelPresentation) { presentations = [presentation] }
    func update(_ presentation: LayoutWheelPresentation) { presentations.append(presentation) }
    func showPlacements(_ placements: [Placement]) {}
    func hidePlacements() {}
    func close() {}
}

@MainActor private final class FuzzMiddleClickMonitor: LayoutWheelMiddleClickMonitoring {
    var eventHandler: ((LayoutWheelMiddleClickEvent) -> Void)?
    var failureHandler: ((String?) -> Void)?
    var isRunning = false
    var trigger = LayoutWheelTriggers.Mouse.middleClick
    var acceptsNewGesture = true
    func start() -> Bool { isRunning = true; return true }
    func stop() { isRunning = false }
}

private let fuzzTrigger: ShortcutModifiers = [.control, .option, .shift]

private enum FuzzEnd: CustomStringConvertible {
    case modifierRelease(partial: Bool)
    case escape
    case commitKey
    case middleUp

    var description: String {
        switch self {
        case let .modifierRelease(partial): partial ? "partialModifierRelease" : "modifierRelease"
        case .escape: "escape"
        case .commitKey: "commitKey"
        case .middleUp: "middleUp"
        }
    }
}

private enum FuzzStep: CustomStringConvertible {
    /// A pointer vector relative to the drawn centre; `delivered` false models a
    /// sample still queued when the gesture ends.
    case move(BTPoint, delivered: Bool)
    case rest(TimeInterval)

    var description: String {
        switch self {
        case let .move(point, delivered):
            String(format: ".move(BTPoint(x: %.3f, y: %.3f), delivered: \(delivered))", point.x, point.y)
        case let .rest(duration): String(format: ".rest(%.3f)", duration)
        }
    }
}

private struct FuzzCase: CustomStringConvertible {
    var style: LayoutWheelStyle
    var levels: LayoutWheelLevelCount
    var scale: Double
    var middleClick: Bool
    var anchor: BTPoint
    var steps: [FuzzStep]
    var end: FuzzEnd

    var description: String {
        "style=\(style) levels=\(levels) scale=\(scale) middleClick=\(middleClick) "
            + "anchor=(\(anchor.x), \(anchor.y)) end=\(end)\nsteps=[\n"
            + steps.map { "  \($0)" }.joined(separator: ",\n") + "\n]"
    }
}

private struct FuzzOutcome {
    var dispatched: [(LayoutWheelCommand, LayoutWheelTarget)] = []
    var violations: [String] = []
}

@MainActor private final class FuzzClock { var time = 1000.0 }
@MainActor private final class FuzzPointer { var position = BTPoint(x: 0, y: 0) }

private func metrics(style: LayoutWheelStyle, scale: Double) -> LayoutWheelMetrics {
    (style == .grouped ? LayoutWheelMetrics.grouped : .standard).scaled(by: scale)
}

/// Pointer vectors aimed at the places where selection rules change.
private func randomVector(_ rng: inout SplitMix64, metrics: LayoutWheelMetrics, style: LayoutWheelStyle) -> BTPoint {
    let g = metrics.geometry
    let fan = metrics.fanGeometry
    let radii: [Double] = [
        rng.range(0, g.hubRadius),
        g.hubRadius + rng.range(-3, 3),
        rng.range(g.hubRadius, g.innerRingOuterRadius),
        g.innerRingOuterRadius + rng.range(-7, 7),
        rng.range(g.innerRingOuterRadius, g.outerRingInnerRadius),
        g.outerRingInnerRadius + rng.range(-7, 7),
        rng.range(g.outerRingInnerRadius, metrics.outerRingOuterRadius),
        metrics.oneLevelInnerRingOuterRadius + rng.range(-7, 7),
        metrics.outerRingOuterRadius + rng.range(-7, 7),
        rng.range(fan.innerRadius - 6, fan.outerRadius + 6),
        fan.innerRadius + rng.range(-7, 12),
        rng.range(fan.outerRadius, fan.outerRadius + 400),
    ]
    let radius = max(0, radii[rng.int(radii.count)])
    let sector = Double(rng.int(8))
    let angle: Double
    switch rng.int(5) {
    case 0: angle = rng.range(-Double.pi, Double.pi)
    case 1: angle = (sector + 0.5) * .pi / 4 + rng.range(-0.08, 0.08) // sector edge
    case 2: angle = sector * .pi / 4 + rng.range(-0.05, 0.05) // sector centre
    case 3:
        let s = LayoutWheelSector(rawValue: rng.int(8))!
        let count = LayoutWheelGroup.at(s).options.count
        if count == 0 { angle = sector * .pi / 4; break }
        let option = rng.int(count)
        let edge = rng.chance(0.5) ? fan.optionAngle / 2 * (rng.chance(0.5) ? 1 : -1) : 0
        angle = fan.angle(sector: s, option: option) + edge + rng.range(-0.06, 0.06)
    default: angle = sector * .pi / 4 + .pi + rng.range(-0.3, 0.3) // hub crossings
    }
    return BTPoint(x: sin(angle) * radius, y: -cos(angle) * radius)
}

private func randomCase(_ rng: inout SplitMix64) -> FuzzCase {
    let style: LayoutWheelStyle = rng.chance(0.5) ? .custom : .grouped
    let levels: LayoutWheelLevelCount = rng.chance(0.5) ? .one : .two
    let scale = [0.8, 1.0, 1.3, rng.range(0.8, 1.3)][rng.int(4)]
    let m = metrics(style: style, scale: scale)
    let frame = BTRect(x: 0, y: 0, width: 1600, height: 1000)
    let anchor: BTPoint = rng.chance(0.3)
        ? BTPoint(x: [rng.range(0, 40), rng.range(1560, 1600)][rng.int(2)], y: rng.range(0, 1000))
        : BTPoint(x: rng.range(200, 1400), y: rng.range(200, 800))
    _ = frame
    var steps: [FuzzStep] = []
    var current = BTPoint(x: 0, y: 0)
    for _ in 0..<(1 + rng.int(5)) {
        let target = randomVector(&rng, metrics: m, style: style)
        let samples = 1 + rng.int(rng.chance(0.3) ? 2 : 25)
        let jitter = rng.chance(0.5) ? 0 : rng.range(0, 4)
        for index in 1...samples {
            let t = Double(index) / Double(samples)
            let point = BTPoint(
                x: current.x + (target.x - current.x) * t + rng.range(-jitter, jitter),
                y: current.y + (target.y - current.y) * t + rng.range(-jitter, jitter)
            )
            steps.append(.move(point, delivered: true))
            if rng.chance(0.05) { steps.append(.rest(rng.range(0, 0.6))) }
        }
        current = target
        if rng.chance(0.6) {
            steps.append(.rest([0, 0.199, 0.2, 0.201, rng.range(0, 0.6)][rng.int(5)]))
            if rng.chance(0.4) {
                // Resting hand tremor below and around hysteresis.
                let tremor = rng.range(0, 7)
                let angle = rng.range(0, 2 * .pi)
                steps.append(.move(BTPoint(x: current.x + cos(angle) * tremor, y: current.y + sin(angle) * tremor),
                                   delivered: true))
                steps.append(.rest(rng.range(0, 0.3)))
            }
        }
    }
    if rng.chance(0.25), case .move = steps.last {
        // The release overtakes one or more queued samples.
        let target = randomVector(&rng, metrics: m, style: style)
        steps.append(.move(target, delivered: false))
    }
    let ends: [FuzzEnd] = [.modifierRelease(partial: false), .modifierRelease(partial: true), .escape, .commitKey,
                           .middleUp]
    let end = ends[rng.int(ends.count)]
    return FuzzCase(style: style, levels: levels, scale: scale, middleClick: { if case .middleUp = end { true } else { false } }(),
                    anchor: anchor, steps: steps, end: end)
}

@MainActor private func run(_ fuzz: FuzzCase, liquid: Bool = false) -> FuzzOutcome {
    var outcome = FuzzOutcome()
    let wheel = LayoutWheelConfiguration(style: fuzz.style, levelCount: fuzz.levels,
                                         keyboardTriggerEnabled: !fuzz.middleClick,
                                         middleClickTriggerEnabled: fuzz.middleClick, scale: fuzz.scale)
    let presenter = FuzzPresenter()
    presenter.usesLiquidGeometry = liquid
    let clock = FuzzClock()
    let pointer = FuzzPointer()
    pointer.position = fuzz.anchor
    let middle = FuzzMiddleClickMonitor()
    let controller = LayoutWheelController(
        configuration: BetterTileConfiguration(layoutWheel: wheel), presenter: presenter,
        now: { clock.time }, pointerProvider: { pointer.position },
        addGlobalMonitor: { _, _ in NSObject() }, addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in },
        middleClickMonitor: middle
    )
    let captured = LayoutWheelTarget(windowID: WindowID(rawValue: "fuzz-\(UUID().uuidString)"),
                                     displayID: DisplayID(rawValue: "fuzz-display"),
                                     visibleFrame: BTRect(x: 0, y: 0, width: 1600, height: 1000))
    var captureCount = 0
    controller.captureHandler = { _ in captureCount += 1; return captured }
    controller.previewHandler = { _, _ in .ready(placements: []) }
    var dispatched: [(LayoutWheelCommand, LayoutWheelTarget)] = []
    controller.commitHandler = { dispatched.append(($0, $1)) }
    controller.unavailableHandler = { _, target in dispatched.append((.repairBento, target)) }
    controller.start()
    defer { controller.stop() }

    if fuzz.middleClick {
        controller.handleMiddleClick(.init(kind: .down, position: fuzz.anchor, button: 2, modifiers: [], timestamp: 0))
    } else {
        controller.handleModifiers(fuzzTrigger)
        controller.handleActivationDeadline(generation: 1)
    }
    guard controller.isOpen, let placement = presenter.presentations.first?.placement else {
        outcome.violations.append("wheel did not open")
        return outcome
    }
    let center = placement.center
    // The liquid wheel draws and hit-tests at the selected size, not the legacy scale.
    let m = liquid ? LayoutWheelMetrics.standard.scaled(by: wheel.appearance.size.scale)
        : metrics(style: fuzz.style, scale: fuzz.scale)
    let levels = wheel.effectiveLevelCount

    var moved = false
    var lastDelivered: BTPoint?
    var finalVector: BTPoint?
    var revealVector: BTPoint?
    var movedOffReveal = false
    var openSector: LayoutWheelSector?
    var previousAim: (sector: LayoutWheelSector, option: Int)?

    func checkLiquidPointer(_ presentation: LayoutWheelPresentation) {
        guard liquid, let vector = presentation.pointer, let selection = presentation.selection else { return }
        let radius = hypot(vector.x, vector.y)
        let angle = atan2(vector.x, -vector.y)
        let offset = LayoutWheelFanGeometry.angularDistance(angle, Double(selection.sector.rawValue) * .pi / 4)
        let content = LayoutWheelLiquidDefaults.content(configuration: wheel)
        if let open = presentation.fan.openSector, let layout = content.submenuLayout {
            if selection.sector != open || selection.ring != wheel.groupRing {
                outcome.violations.append("liquid lock detached from its parent selection")
            }
            let lower = levels == .one ? content.wheelGeometry.hubRadius : content.wheelGeometry.outerRingInnerRadius - 4
            if radius < lower - 1e-9 { outcome.violations.append("liquid lock persisted inside the inner ring or hub") }
            if radius <= layout.rimRadius + 4, offset > Double.pi / 8 + 10 * .pi / 180 + 1e-9 {
                outcome.violations.append("liquid lock persisted outside its sector and leave margin")
            }
            // Beyond the rim, the approved Keep policy permits any angle.
        } else if offset > Double.pi / 8 + 5 / max(radius, 1) + 1e-9 {
            outcome.violations.append("unlocked liquid sector is distant from the pointer")
        }
    }

    func observeFan() {
        let presentation = presenter.presentations.last
        if let presentation { checkLiquidPointer(presentation) }
        let fan = presentation?.fan
        if liquid, let sector = fan?.openSector, let option = fan?.optionIndex,
           previousAim?.sector != sector || previousAim?.option != option,
           let vector = presentation?.pointer {
            let content = LayoutWheelLiquidDefaults.content(configuration: wheel)
            if let layout = content.submenuLayout {
                let options = layout.positions(sector: sector, count: wheel.group(at: sector).options.count)
                if !options.indices.contains(option) {
                    outcome.violations.append("liquid aimed an absent child")
                } else {
                    let reach = layout.optionRadius + layout.spacing / 2 + 8
                    let distance = hypot(vector.x - options[option].x, vector.y - options[option].y)
                    if distance > reach + 1e-9 { outcome.violations.append("new liquid aim outside child reach") }
                    if let previousAim, previousAim.sector == sector, options.indices.contains(previousAim.option) {
                        let previous = options[previousAim.option]
                        if distance + 6 >= hypot(vector.x - previous.x, vector.y - previous.y) {
                            outcome.violations.append("liquid child changed without six-point advantage")
                        }
                    }
                }
            }
        }
        previousAim = fan?.openSector.flatMap { sector in fan?.optionIndex.map { (sector, $0) } }
        if fan?.openSector != openSector {
            openSector = fan?.openSector
            revealVector = openSector == nil ? nil : lastDelivered
            movedOffReveal = false
        }
    }

    for step in fuzz.steps {
        switch step {
        case let .move(vector, delivered):
            let absolute = BTPoint(x: center.x + vector.x, y: center.y + vector.y)
            pointer.position = absolute
            finalVector = vector
            guard delivered else { continue }
            if hypot(absolute.x - fuzz.anchor.x, absolute.y - fuzz.anchor.y) > 5 { moved = true }
            lastDelivered = vector
            if let reveal = revealVector, hypot(vector.x - reveal.x, vector.y - reveal.y) > 5 { movedOffReveal = true }
            if fuzz.middleClick {
                controller.handleMiddleClick(.init(kind: .dragged, position: absolute, button: 2, modifiers: [],
                                                   timestamp: 0))
            } else {
                controller.handlePointer(absolute)
            }
            observeFan()
        case let .rest(duration):
            clock.time += duration
            controller.handleFanDeadline()
            observeFan()
        }
        if presenter.presentations.contains(where: { $0.placement != placement }) {
            outcome.violations.append("placement changed mid-gesture")
        }
    }

    // Pointer releases resample the final position. Return commits what the
    // delivered samples selected.
    if case .commitKey = fuzz.end { finalVector = lastDelivered }
    let releaseVector = finalVector ?? BTPoint(x: fuzz.anchor.x - center.x, y: fuzz.anchor.y - center.y)
    if let reveal = revealVector, hypot(releaseVector.x - reveal.x, releaseVector.y - reveal.y) > 5 {
        movedOffReveal = true
    }
    switch fuzz.end {
    case let .modifierRelease(partial):
        controller.handleModifiers(partial ? [.control, .option] : [])
        if partial { controller.handleModifiers([]) }
    case .escape:
        controller.handleKey(.escape)
        controller.handleModifiers([])
    case .commitKey:
        controller.handleKey(.commit)
        controller.handleModifiers([])
    case .middleUp:
        controller.handleMiddleClick(.init(kind: .up, position: pointer.position, button: 2, modifiers: [],
                                           timestamp: 0))
    }
    // Stray late callbacks must never dispatch again.
    controller.release()
    controller.handleFanDeadline()
    controller.handlePointer(pointer.position)
    controller.handleKey(.commit)
    controller.release()

    outcome.dispatched = dispatched
    if dispatched.count > 1 { outcome.violations.append("dispatched \(dispatched.count) times") }
    if captureCount != 1 { outcome.violations.append("captured \(captureCount) times") }
    if dispatched.contains(where: { $0.1 != captured }) { outcome.violations.append("dispatch used another target") }
    if case .escape = fuzz.end, !dispatched.isEmpty { outcome.violations.append("Escape dispatched") }
    if controller.isOpen { outcome.violations.append("wheel still open") }

    let command = dispatched.first?.0
    let pointerEverMoved = moved || {
        if case .commitKey = fuzz.end { return false }
        // A queued final sample still counts once the release resamples it.
        guard let finalVector else { return false }
        let absolute = BTPoint(x: center.x + finalVector.x, y: center.y + finalVector.y)
        return hypot(absolute.x - fuzz.anchor.x, absolute.y - fuzz.anchor.y) > 5
    }()
    guard case .escape = fuzz.end else {
        let radius = hypot(releaseVector.x, releaseVector.y)
        let angle = atan2(releaseVector.x, -releaseVector.y)
        if !pointerEverMoved {
            if command != nil { outcome.violations.append("dispatched without pointer movement") }
            return outcome
        }
        if radius <= m.geometry.hubRadius - 0.001, command != nil {
            outcome.violations.append("hub release dispatched \(String(describing: command))")
        }
        if fuzz.style == .custom {
            let expected = m.geometry(for: levels).selection(for: releaseVector, levelCount: levels)
                .flatMap { wheel.command(at: $0) }
            if command != expected {
                outcome.violations.append("custom release dispatched \(String(describing: command)), "
                    + "final sample selects \(String(describing: expected))")
            }
            return outcome
        }
        if liquid {
            if let presentation = presenter.presentations.last {
                checkLiquidPointer(presentation)
                let content = LayoutWheelLiquidDefaults.content(configuration: wheel)
                let state = LayoutWheelLiquidState(selection: presentation.selection, fan: presentation.fan,
                                                   pointer: presentation.pointer)
                if command != content.command(state) { outcome.violations.append("released command differs from drawn command") }
                if let option = presentation.fan.optionIndex {
                    guard let sector = presentation.fan.openSector else {
                        outcome.violations.append("liquid child without an open parent"); return outcome
                    }
                    if !wheel.group(at: sector).options.indices.contains(option) {
                        outcome.violations.append("liquid child is outside configured group")
                    }
                }
            }
            return outcome
        }
        // Grouped: hysteresis allows a nearby sector, never a distant one.
        let fan = m.fanGeometry(for: wheel)
        for sector in LayoutWheelSector.allCases {
            let group = LayoutWheelGroup.at(sector)
            if let index = group.options.firstIndex(where: { $0 == command }) {
                let tolerance = fan.optionAngle / 2 + 5 / max(radius, 1) + 1e-9
                if !movedOffReveal {
                    outcome.violations.append("resting release selected fan option \(group.options[index])")
                }
                if radius < fan.innerRadius - 5 - 1e-9 || radius > fan.outerRadius + 5 + 1e-9
                    || LayoutWheelFanGeometry.angularDistance(angle, fan.angle(sector: sector, option: index)) > tolerance {
                    outcome.violations.append("fan option \(group.options[index]) selected away from its tile")
                }
                return outcome
            }
        }
        if radius > m.outerRadius(for: wheel.groupRing, levelCount: levels) {
            let near = LayoutWheelSector.allCases.filter {
                LayoutWheelFanGeometry.angularDistance(angle, Double($0.rawValue) * .pi / 4)
                    <= .pi / 8 + 5 / radius + 1e-9
            }
            var allowed = near.map { LayoutWheelGroup.at($0).quickAction }
            // An open fan keeps its parent while the pointer crosses its tiles
            // and the gaps between them.
            if let openSector, radius >= fan.innerRadius - 5, radius <= fan.outerRadius + 5 {
                let offsets: [Double] = LayoutWheelGroup.at(openSector).options.indices.map { option -> Double in
                    let d: Double = angle - fan.angle(sector: openSector, option: option)
                    return atan2(sin(d), cos(d))
                }
                let onTile = offsets.contains { abs($0) <= fan.optionAngle / 2 + 5 / radius + 1e-9 }
                let before: Double = offsets.filter { $0 >= 0 }.min() ?? Double.infinity
                let after: Double = offsets.filter { $0 <= 0 }.max() ?? -Double.infinity
                let inGap = before - after <= Double.pi / 2 + 1e-9
                if onTile || inGap { allowed.append(LayoutWheelGroup.at(openSector).quickAction) }
            }
            if !allowed.contains(where: { $0 == command }) {
                outcome.violations.append("release beyond the rings at \(Int(angle * 180 / .pi))° dispatched "
                    + "\(String(describing: command)); expected one of \(allowed)")
            }
        }
        return outcome
    }
    return outcome
}

@Suite(.macOSTestApplication) struct LayoutWheelFuzzTests {
    @Test(arguments: [false, true]) @MainActor func layoutWheelGestureFuzzKeepsSelectionInvariants(liquid: Bool) {
        let environment = ProcessInfo.processInfo.environment
        let seed = environment["LAYOUT_WHEEL_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x5EED_2026_1021
        let cases = environment["LAYOUT_WHEEL_FUZZ_CASES"].flatMap(Int.init) ?? 1500
        var rng = SplitMix64(state: seed)
        var failures: [String] = []
        for index in 0..<cases {
            let fuzz = randomCase(&rng)
            let outcome = run(fuzz, liquid: liquid)
            if !outcome.violations.isEmpty {
                failures.append("case \(index) seed \(seed): \(outcome.violations)\n\(shrink(fuzz))")
                if failures.count >= 3 { break }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n\n"))")
    }

}

/// Removes steps while the case still fails, then reports the smallest script.
@MainActor private func shrink(_ fuzz: FuzzCase) -> FuzzCase {
    var best = fuzz
    var progress = true
    while progress {
        progress = false
        var index = 0
        while index < best.steps.count {
            var candidate = best
            candidate.steps.remove(at: index)
            if !run(candidate).violations.isEmpty {
                best = candidate
                progress = true
            } else {
                index += 1
            }
        }
    }
    return best
}

// Shrunk from the fuzz case above: a Custom flick whose last pointer sample is
// still queued when the trigger is released.
@Test(.macOSTestApplication) @MainActor func customReleaseAppliesAPointerSampleStillQueuedAtRelease() {
    for end in [FuzzEnd.modifierRelease(partial: false), .modifierRelease(partial: true), .middleUp] {
        let fuzz = FuzzCase(style: .custom, levels: .one, scale: 1, middleClick: { if case .middleUp = end { true } else { false } }(),
                            anchor: BTPoint(x: 720, y: 540),
                            steps: [.move(BTPoint(x: -33.94, y: -112.843), delivered: false)], end: end)
        let outcome = run(fuzz)
        #expect(outcome.violations.isEmpty, "\(end): \(outcome.violations)")
        #expect(outcome.dispatched.map(\.0) == [.windowAction(.topHalf)], "\(end)")
    }
}

/// Moving into Right and then back to the hub with the hub sample still queued
/// must cancel, not commit the stale Right selection.
@Test(.macOSTestApplication) @MainActor func customReleaseAtTheHubWithAQueuedSampleCancels() {
    let fuzz = FuzzCase(style: .custom, levels: .two, scale: 1, middleClick: false, anchor: BTPoint(x: 800, y: 500),
                        steps: [.move(BTPoint(x: 45, y: 0), delivered: true), .move(BTPoint(x: 2, y: 0), delivered: false)],
                        end: .modifierRelease(partial: false))
    let outcome = run(fuzz)
    #expect(outcome.violations.isEmpty, "\(outcome.violations)")
    #expect(outcome.dispatched.isEmpty)
}

/// Shrunk from fuzz case 1054: with the Displays fan open, pointing straight
/// down past the rings must not dispatch Next Display.
@Test(.macOSTestApplication) @MainActor func groupedOpenFanReleasesItsParentAwayFromEveryTile() {
    let fan = LayoutWheelMetrics.grouped.fanGeometry
    let band = (fan.innerRadius + fan.outerRadius) / 2
    let fuzz = FuzzCase(style: .grouped, levels: .two, scale: 1, middleClick: false, anchor: BTPoint(x: 800, y: 500),
                        steps: [.move(BTPoint(x: 124, y: 0), delivered: true), .rest(0.2),
                                .move(BTPoint(x: band * 0.7, y: band * 0.7), delivered: true),
                                .move(BTPoint(x: 3, y: band), delivered: true)],
                        end: .modifierRelease(partial: false))
    let outcome = run(fuzz)
    #expect(outcome.violations.isEmpty, "\(outcome.violations)")
    #expect(outcome.dispatched.map(\.0) == [.windowAction(.restore)])
}
