import Foundation

/// The shape the liquid Layout Wheel rests in, in top-left logical points
/// relative to the wheel centre. Presentation only: selection keeps using
/// `LayoutWheelGeometry` and `LayoutWheelFanState`.
public struct LayoutWheelLiquidLayout: Equatable, Sendable {
    /// The outer edge of the outermost ring at rest.
    public var outerRadius: Double
    /// The edge between the inner and the outer ring, or nil for one ring.
    public var stepRadius: Double?
    public var wellRadius: Double
    /// The radius of each ring's icons, inner ring first.
    public var iconRadii: [Double]
    /// A fan option's radius at full size.
    public var dropletRadius: Double
    /// The size preset, 1 at Medium. Distances in the tuning scale with it.
    public var scale: Double
    public let slotCount = LayoutWheelSector.allCases.count

    public init(outerRadius: Double, stepRadius: Double? = nil, wellRadius: Double,
                iconRadii: [Double], dropletRadius: Double, scale: Double = 1) {
        self.outerRadius = outerRadius
        self.stepRadius = stepRadius
        self.wellRadius = wellRadius
        self.iconRadii = iconRadii
        self.dropletRadius = dropletRadius
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }

    public var ringCount: Int { stepRadius == nil ? 1 : 2 }
    public var outermostRing: Int { ringCount - 1 }

    /// Slot zero is at the top; slots continue clockwise, like `LayoutWheelSector`.
    public func slotAngle(_ slot: Int) -> Double {
        -Double.pi / 2 + Double(slot) * 2 * .pi / Double(slotCount)
    }

    public var slotWidth: Double { 2 * .pi / Double(slotCount) }
}

/// How the wheel appears.
public enum LayoutWheelLiquidOpening: String, CaseIterable, Sendable {
    /// A short, settled grow and fade.
    case calm
    /// Grows from smaller and overshoots slightly.
    case rise
    /// The rim starts drawn in and springs out with a wobble.
    case bloom
    /// Almost only a fade.
    case quick
}

/// How the wheel leaves after a release or a cancel.
public enum LayoutWheelLiquidClosing: String, CaseIterable, Sendable {
    /// Release pops and grows slightly while fading; cancel shrinks and fades.
    case calm
    /// A fast fade without a size change.
    case quick
    /// Shrinks well toward the centre while fading.
    case sink
}

/// Feel values. Distances are points at the Medium size.
public struct LayoutWheelLiquidTuning: Equatable, Sendable {
    public var opening = LayoutWheelLiquidOpening.calm
    public var closing = LayoutWheelLiquidClosing.calm
    /// How far the whole drawing leans toward the pointer; 0 turns it off.
    /// Presentation only: hit testing never moves.
    public var drift = 0.0
    /// Oval wobble frequency of the rim, in hertz. Higher feels tighter.
    public var tension = 2.6
    /// Damping ratio of the rim's oval wobble. Lower rings longer.
    public var ringing = 0.32
    /// How far the aimed slot swells outward.
    public var bulge = 7.0
    /// The longest pointer stretch beyond the rim.
    public var stretch = 30.0
    /// How hard the rim snaps back when a stretch shortens, per second.
    public var recoil = 12.0
    /// Scales every impulse on the rim: arrival, release, pinch-off, landing.
    public var splash = 1.0
    /// Magnet spring for each slot: how the selection snaps in.
    public var magnetResponse = 0.28
    public var magnetDamping = 0.58
    /// Magnet speed added when the aim arrives, and on release.
    public var impact = 3.0
    public var commit = 7.0
    /// Fan droplet travel spring.
    public var dropletResponse = 0.34
    public var dropletDamping = 0.72
    /// A droplet detaches beyond `detachGap` and attaches again below
    /// `attachGap`. The difference stops flicker at the boundary.
    public var detachGap = 9.0
    public var attachGap = 4.0

    public init() {}
    public static let standard = Self()
}

/// What the liquid wheel shows now. Supplied by the gesture, never decided here.
public struct LayoutWheelLiquidInput: Equatable, Sendable {
    public struct Focus: Hashable, Sendable {
        /// 0 is the inner ring.
        public var ring: Int
        public var slot: Int
        public init(ring: Int, slot: Int) { self.ring = ring; self.slot = slot }
    }

    public struct Fan: Equatable, Sendable {
        /// The parent's slot on the outermost ring.
        public var parentSlot: Int
        /// Option centres relative to the wheel centre.
        public var options: [BTPoint]
        public var aimedOption: Int?
        /// Where every option grows from, such as a cluster's chevron. Nil:
        /// each grows from the rim below its own place.
        public var emergence: BTPoint?
        public init(parentSlot: Int, options: [BTPoint], aimedOption: Int? = nil, emergence: BTPoint? = nil) {
            self.parentSlot = parentSlot; self.options = options; self.aimedOption = aimedOption
            self.emergence = emergence
        }
    }

    /// The pointer relative to the wheel centre.
    public var pointer: BTPoint?
    public var focus: Focus?
    public var fan: Fan?

    public init(pointer: BTPoint? = nil, focus: Focus? = nil, fan: Fan? = nil) {
        self.pointer = pointer; self.focus = focus; self.fan = fan
    }
}

/// One fan option that buds from the rim, pinches off and floats to its place.
public struct LayoutWheelLiquidDroplet: Equatable, Sendable {
    public let parentSlot: Int
    public let option: Int
    public let baseRadius: Double
    /// Where it emerges and returns: just inside the rim, below its place.
    public let origin: BTPoint
    public internal(set) var x: LayoutWheelLiquidSpring
    public internal(set) var y: LayoutWheelLiquidSpring
    /// 0...1 of `baseRadius`.
    public internal(set) var size: LayoutWheelLiquidSpring
    /// 0...1 while the option is aimed.
    public internal(set) var swell: LayoutWheelLiquidSpring
    /// The oval shape harmonic, as cos(2a) and sin(2a) amplitudes.
    public internal(set) var ovalCosine = LayoutWheelLiquidSpring()
    public internal(set) var ovalSine = LayoutWheelLiquidSpring()
    /// Opacity. Only Reduce Motion fades droplets; otherwise they grow.
    public internal(set) var fade: LayoutWheelLiquidSpring
    public internal(set) var iconTint = 0.0
    public internal(set) var openingElapsed = 0.0
    /// Fade the opening neck during this window. A settled bubble must never keep a liquid bridge.
    static let openingConnectionWindow = 0.22...0.5
    /// A connection belongs only to the opening splash, never the settled fan.
    public var connection: Double {
        guard !isRetracting else { return 0 }
        let window = Self.openingConnectionWindow
        let t = min(1, max(0, (openingElapsed - window.lowerBound) / (window.upperBound - window.lowerBound)))
        return 1 - t * t * (3 - 2 * t)
    }
    public internal(set) var isAttached: Bool
    public internal(set) var isRetracting = false

    public var center: BTPoint { BTPoint(x: x.value, y: y.value) }
    /// The current radius, including growth and the aimed swell.
    public var radius: Double { baseRadius * max(0, size.value) * (1 + 0.1 * swell.value) }
}

/// Deterministic motion for the liquid Layout Wheel.
///
/// The caller supplies time and input; the model never reads a clock. It
/// owns presentation only: a value here can never choose or dispatch a
/// command. `isAtRest` tells the renderer when to stop its frame clock.
public struct LayoutWheelLiquid: Equatable, Sendable {
    public enum Ending: Equatable, Sendable { case commit, cancel }
    public enum Phase: Equatable, Sendable { case closed, open, closing(Ending) }

    public let layout: LayoutWheelLiquidLayout
    public let tuning: LayoutWheelLiquidTuning
    public let reduceMotion: Bool
    public private(set) var phase: Phase = .closed
    public private(set) var outer: LayoutWheelLiquidRim
    /// The edge between the two rings, when there are two.
    public private(set) var step: LayoutWheelLiquidRim?
    public private(set) var droplets: [LayoutWheelLiquidDroplet] = []
    public private(set) var input = LayoutWheelLiquidInput()

    private var magnets: [LayoutWheelLiquidSpring]
    private var iconTints: [Double]
    public private(set) var submenuDimming = 0.0
    private var aim = LayoutWheelLiquidSpring()
    private var glow = LayoutWheelLiquidSpring()
    private var glowRadius = LayoutWheelLiquidSpring()
    private var reach = LayoutWheelLiquidSpring()
    private var reachAngle = LayoutWheelLiquidSpring()
    private var presence = LayoutWheelLiquidSpring()
    private var driftX = LayoutWheelLiquidSpring()
    private var driftY = LayoutWheelLiquidSpring()
    private var hasAimed = false
    private var impactPending = false
    private var closingHold = 0.0
    private let spectrum: LayoutWheelLiquidRim.Spectrum
    private var profile = Array(repeating: 0.0, count: LayoutWheelLiquidRim.sampleCount)

    /// More droplets than this can only exist while one fan replaces another.
    public static let maximumDroplets = 12

    public init(layout: LayoutWheelLiquidLayout, tuning: LayoutWheelLiquidTuning = .standard,
                reduceMotion: Bool = false) {
        self.layout = layout
        self.tuning = tuning
        self.reduceMotion = reduceMotion
        outer = LayoutWheelLiquidRim(restRadius: layout.outerRadius)
        step = layout.stepRadius.map(LayoutWheelLiquidRim.init(restRadius:))
        magnets = Array(repeating: .init(), count: layout.ringCount * layout.slotCount)
        iconTints = Array(repeating: 0, count: layout.ringCount * layout.slotCount)
        spectrum = .init(tension: tuning.tension, ringing: tuning.ringing, reduceMotion: reduceMotion)
    }

    // MARK: Events

    /// Starts a fresh presentation. Nothing from an earlier one survives.
    public mutating func open() {
        self = Self(layout: layout, tuning: tuning, reduceMotion: reduceMotion)
        phase = .open
        presence.target = 1
        if tuning.opening == .bloom, !reduceMotion {
            // Start drawn in by an eighth of the radius; the springs bring it out.
            outer.offsetUniformly(by: -0.12 * layout.outerRadius)
            step?.offsetUniformly(by: -0.12 * (layout.stepRadius ?? 0))
        }
    }

    /// Follows the gesture. Ignored unless the wheel is open.
    public mutating func update(_ next: LayoutWheelLiquidInput) {
        guard phase == .open, next != input else { return }
        let previous = input
        input = next
        if next.focus != previous.focus { refocus(previous: previous.focus) }
        updateDrift()
        updateReach()
        updateFan()
    }

    /// The user released on a command. The selection pops, then everything fades.
    public mutating func release() {
        guard phase == .open else { return }
        phase = .closing(.commit)
        closingHold = reduceMotion ? 0.04 : 0.07
        guard let focus = input.focus else { return }
        if !reduceMotion {
            magnets[index(focus)].velocity += tuning.commit
            glow.velocity += 4
            if let aimed = input.fan?.aimedOption,
               let drop = droplets.firstIndex(where: { !$0.isRetracting && $0.option == aimed }) {
                droplets[drop].swell.velocity += tuning.commit
            } else if let rim = rim(for: focus.ring) {
                strike(rim: rim, angle: layout.slotAngle(focus.slot), speed: 160 * layout.scale)
            }
        }
        reach.target = 0
    }

    /// The gesture ended without a command: unfocus, retract, fade quickly.
    public mutating func cancel() {
        guard phase == .open else { return }
        phase = .closing(.cancel)
        for index in magnets.indices { magnets[index].target = 0 }
        glow.target = 0
        reach.target = 0
        retractDroplets()
        presence.target = 0
    }

    // MARK: Time

    public mutating func advance(_ elapsed: Double) {
        guard phase != .closed, elapsed.isFinite, elapsed > 0 else { return }
        let dt = min(elapsed, 0.1)
        if closingHold > 0 {
            closingHold -= dt
            if closingHold <= 0 { closingHold = 0; presence.target = 0 }
        }
        advancePresence(dt)
        // Presentation cross-fades use supplied model time, including a fake frame clock.
        let tintStep = dt / 0.12
        for index in iconTints.indices {
            let target = phase == .open && input.focus.map({ self.index($0) == index }) == true ? 1.0 : 0.0
            iconTints[index] += min(tintStep, max(-tintStep, target - iconTints[index]))
        }
        let dimTarget = phase == .open && input.fan != nil ? 1.0 : 0.0
        submenuDimming += min(tintStep, max(-tintStep, dimTarget - submenuDimming))
        // Cancel and Reduce Motion fade the selection out without a bounce.
        let calm = reduceMotion || phase == .closing(.cancel)
        let magnet = LayoutWheelLiquidSpring.Parameters(
            response: reduceMotion ? 0.08 : (calm ? 0.16 : tuning.magnetResponse),
            dampingRatio: calm ? 1 : tuning.magnetDamping)
        for index in magnets.indices { magnets[index].advance(dt, magnet) }
        aim.advance(dt, .init(response: 0.2, dampingRatio: 1))
        glow.advance(dt, .init(response: reduceMotion ? 0.1 : 0.18, dampingRatio: 1))
        glowRadius.advance(dt, .init(response: 0.16, dampingRatio: 1))
        reach.advance(dt, .init(response: 0.1, dampingRatio: 1))
        if case .closing = phase { driftX.target = 0; driftY.target = 0 }
        let lean = LayoutWheelLiquidSpring.Parameters(response: 0.3, dampingRatio: 0.9)
        driftX.advance(dt, lean)
        driftY.advance(dt, lean)
        reachAngle.advance(dt, .init(response: 0.12, dampingRatio: 1))
        fireImpactIfArrived()
        advanceDroplets(dt)
        rebuildTargets()
        outer.advance(dt, spectrum: spectrum)
        step?.advance(dt, spectrum: spectrum)

        if case .closing = phase, presence.target == 0, presence.value <= 0.004 {
            phase = .closed
            return
        }
        if isSettled { settle() }
    }

    /// True when another frame would draw the same picture. A closed wheel
    /// is at rest; a closing one never is until it closes.
    public var isAtRest: Bool {
        switch phase {
        case .closed: true
        case .closing: false
        case .open: isSettled
        }
    }

    // MARK: Output for drawing

    /// 0...1, to multiply every drawn alpha.
    public var opacity: Double { min(1, max(0, presence.value)) }

    /// The whole drawing's scale about the centre.
    public var scale: Double {
        guard !reduceMotion else { return 1 }
        let p = min(1.2, max(0, presence.value))
        switch phase {
        case .closing(let ending):
            switch tuning.closing {
            case .calm: return ending == .commit ? 1 + 0.03 * (1 - p) : 0.92 + 0.08 * p
            case .quick: return 1
            case .sink: return 0.6 + 0.4 * p
            }
        default:
            switch tuning.opening {
            case .calm: return 0.9 + 0.1 * p
            case .rise: return 0.82 + 0.18 * p
            case .bloom: return 0.75 + 0.25 * p
            case .quick: return 0.97 + 0.03 * p
            }
        }
    }

    /// The drawing's lean toward the pointer. Presentation only.
    public var drift: BTPoint { BTPoint(x: driftX.value, y: driftY.value) }

    /// The selection snap for one slot: 0 at rest, 1 aimed, briefly above 1.
    public func magnet(ring: Int, slot: Int) -> Double {
        guard ring >= 0, ring < layout.ringCount, slot >= 0, slot < layout.slotCount else { return 0 }
        return magnets[ring * layout.slotCount + slot].value
    }

    /// A shader mask tint, independent of the bouncing selection magnet.
    public func iconTint(ring: Int, slot: Int) -> Double {
        guard ring >= 0, ring < layout.ringCount, slot >= 0, slot < layout.slotCount else { return 0 }
        return iconTints[ring * layout.slotCount + slot]
    }

    /// The highlight that travels around the ring toward the aimed slot.
    public struct Glow: Equatable, Sendable {
        public var angle: Double
        public var radius: Double
        public var intensity: Double
        /// Angular half-width; it widens while the highlight travels.
        public var spread: Double
    }

    public var focusGlow: Glow {
        let travel = min(1.5, abs(aim.velocity) / 8)
        // The cloud trails its own motion a little, like dye in a current.
        return Glow(angle: aim.value - 0.03 * aim.velocity, radius: glowRadius.value,
                    intensity: max(0, glow.value) / (1 + 0.6 * travel),
                    spread: layout.slotWidth * 0.82 * (1 + travel))
    }

    /// How far a ring icon moves with the liquid: half the edge's own motion.
    public func iconOffset(ring: Int, slot: Int) -> BTPoint {
        guard ring >= 0, ring < layout.ringCount else { return BTPoint(x: 0, y: 0) }
        let angle = layout.slotAngle(slot)
        let edge = ring == layout.outermostRing ? outer : step
        let distance = 0.5 * (edge?.displacement(at: angle) ?? 0)
        return BTPoint(x: cos(angle) * distance, y: sin(angle) * distance)
    }

    // MARK: Focus

    private func index(_ focus: LayoutWheelLiquidInput.Focus) -> Int {
        min(max(0, focus.ring), layout.ringCount - 1) * layout.slotCount
            + min(max(0, focus.slot), layout.slotCount - 1)
    }

    private mutating func refocus(previous: LayoutWheelLiquidInput.Focus?) {
        for index in magnets.indices { magnets[index].target = 0 }
        guard let focus = input.focus else {
            glow.target = 0
            impactPending = false
            return
        }
        magnets[index(focus)].target = 1
        glow.target = 1
        let ring = min(max(0, focus.ring), layout.ringCount - 1)
        glowRadius.target = layout.iconRadii.indices.contains(ring) ? layout.iconRadii[ring] : layout.outerRadius
        let angle = layout.slotAngle(focus.slot)
        if !hasAimed || reduceMotion {
            // The first aim appears in place; it has nowhere to travel from.
            aim = .init(value: angle)
            glowRadius.settle()
            hasAimed = true
        } else {
            aim.target = aim.value + LayoutWheelLiquidRim.wrapped(angle - aim.value)
        }
        impactPending = !reduceMotion
    }

    /// The magnet snaps in when the travelling highlight reaches its slot.
    private mutating func fireImpactIfArrived() {
        guard impactPending, phase == .open, let focus = input.focus else { return }
        let angle = layout.slotAngle(focus.slot)
        guard abs(LayoutWheelLiquidRim.wrapped(aim.value - angle)) < 7 * .pi / 180 else { return }
        impactPending = false
        magnets[index(focus)].velocity += tuning.impact
        if let rim = rim(for: focus.ring) {
            strike(rim: rim, angle: angle, speed: 60 * layout.scale)
        }
    }

    private enum RimID { case outer, step }

    private func rim(for ring: Int) -> RimID? {
        if ring == layout.outermostRing { return .outer }
        return step == nil ? nil : .step
    }

    private mutating func strike(rim: RimID, angle: Double, speed: Double) {
        guard !reduceMotion else { return }
        switch rim {
        case .outer: outer.strike(angle: angle, halfWidth: layout.slotWidth * 0.7, speed: speed * tuning.splash)
        case .step: step?.strike(angle: angle, halfWidth: layout.slotWidth * 0.7, speed: speed * tuning.splash)
        }
    }

    // MARK: Pointer drift

    private mutating func updateDrift() {
        guard !reduceMotion, tuning.drift > 0, let pointer = input.pointer,
              pointer.x.isFinite, pointer.y.isFinite else {
            driftX.target = 0; driftY.target = 0
            return
        }
        let distance = hypot(pointer.x, pointer.y)
        guard distance > 0 else { driftX.target = 0; driftY.target = 0; return }
        let amount = tuning.drift * layout.scale * min(1, distance / layout.outerRadius)
        driftX.target = pointer.x / distance * amount
        driftY.target = pointer.y / distance * amount
    }

    // MARK: Pointer stretch

    private var maximumReach: Double { tuning.stretch * layout.scale }

    /// The rim follows the pointer past its edge, with a soft limit, and
    /// recoils when the stretch shortens.
    private mutating func updateReach() {
        var target = 0.0
        if !reduceMotion, input.fan == nil, let focus = input.focus, focus.ring == layout.outermostRing,
           let pointer = input.pointer, pointer.x.isFinite, pointer.y.isFinite {
            let beyond = hypot(pointer.x, pointer.y) - layout.outerRadius
            if beyond > 0, maximumReach > 0 {
                target = maximumReach * tanh(beyond / maximumReach)
                let angle = atan2(pointer.y, pointer.x)
                if reach.value < 0.5 {
                    reachAngle = .init(value: angle)
                } else {
                    reachAngle.target = reachAngle.value + LayoutWheelLiquidRim.wrapped(angle - reachAngle.value)
                }
            }
        }
        let lost = reach.target - target
        if lost > 0.5 * layout.scale, !reduceMotion {
            outer.strike(angle: reachAngle.value, halfWidth: reachHalfWidth,
                         speed: -tuning.recoil * tuning.splash * lost)
        }
        reach.target = target
    }

    private var reachHalfWidth: Double {
        let radius = lobeRadius
        return min(1.2, max(0.35, asin(min(1, radius / layout.outerRadius)) * 2.2))
    }

    /// The pulled lobe's radius: it narrows as it stretches, like a drawn-out drop.
    private var lobeRadius: Double {
        let extent = maximumReach > 0 ? min(1, max(0, reach.value / maximumReach)) : 0
        return (24 - 10 * extent) * layout.scale
    }

    /// How far a circle pulled out of the rim toward the pointer reaches past
    /// the rim along `angle`: the ray's far intersection with that circle.
    /// The harmonic filter then rounds the crease into a neck.
    private func lobe(at angle: Double) -> Double {
        let rho = lobeRadius
        let distance = layout.outerRadius + reach.value - rho
        let offset = LayoutWheelLiquidRim.wrapped(angle - reachAngle.value)
        guard abs(offset) < .pi / 2 else { return 0 }
        let across = distance * sin(offset)
        guard abs(across) < rho else { return 0 }
        let far = distance * cos(offset) + (rho * rho - across * across).squareRoot()
        return max(0, far - layout.outerRadius)
    }

    // MARK: Fan droplets

    private mutating func updateFan() {
        guard let fan = input.fan else {
            retractDroplets()
            return
        }
        let live = droplets.filter { !$0.isRetracting }
        let sameFan = !live.isEmpty && live.allSatisfy { $0.parentSlot == fan.parentSlot }
            && live.count == fan.options.count
        if !sameFan {
            retractDroplets()
            for (option, center) in fan.options.enumerated() {
                spawnDroplet(option: option, at: center, parent: fan.parentSlot, emergence: fan.emergence)
            }
            if droplets.count > Self.maximumDroplets {
                // Drop the oldest retracting droplets; they are nearly gone.
                droplets.removeFirst(droplets.count - Self.maximumDroplets)
            }
        }
        for index in droplets.indices where !droplets[index].isRetracting {
            let option = droplets[index].option
            droplets[index].swell.target = option == fan.aimedOption ? 1 : 0
            if fan.options.indices.contains(option), fan.options[option].x.isFinite, fan.options[option].y.isFinite {
                droplets[index].x.target = fan.options[option].x
                droplets[index].y.target = fan.options[option].y
            }
        }
    }

    private mutating func spawnDroplet(option: Int, at center: BTPoint, parent: Int, emergence: BTPoint?) {
        guard center.x.isFinite, center.y.isFinite else { return }
        let angle = atan2(center.y, center.x)
        let radius = layout.dropletRadius
        let rimRadius = layout.outerRadius + baseDisplacement(at: angle)
        var origin = BTPoint(x: cos(angle) * (rimRadius - 0.3 * radius), y: sin(angle) * (rimRadius - 0.3 * radius))
        if let emergence, emergence.x.isFinite, emergence.y.isFinite {
            // Grow out of one point, just inside the rim there.
            let at = atan2(emergence.y, emergence.x)
            let depth = max(0, hypot(emergence.x, emergence.y) - 0.3 * radius)
            origin = BTPoint(x: cos(at) * depth, y: sin(at) * depth)
        }
        let start = reduceMotion ? center : origin
        var x = LayoutWheelLiquidSpring(value: start.x, target: center.x)
        var y = LayoutWheelLiquidSpring(value: start.y, target: center.y)
        if reduceMotion { x.settle(); y.settle() }
        var drop = LayoutWheelLiquidDroplet(
            parentSlot: parent, option: option, baseRadius: radius, origin: origin,
            x: x, y: y,
            size: .init(value: reduceMotion ? 1 : 0.35, target: 1),
            swell: .init(),
            fade: .init(value: reduceMotion ? 0 : 1, target: 1),
            isAttached: !reduceMotion)
        drop.isRetracting = false
        droplets.append(drop)
    }

    private mutating func retractDroplets() {
        for index in droplets.indices where !droplets[index].isRetracting {
            droplets[index].isRetracting = true
            droplets[index].swell.target = 0
            if reduceMotion {
                droplets[index].fade.target = 0
            } else {
                droplets[index].x.target = droplets[index].origin.x
                droplets[index].y.target = droplets[index].origin.y
                droplets[index].size.target = 0
            }
        }
    }

    private mutating func advanceDroplets(_ dt: Double) {
        guard !droplets.isEmpty else { return }
        let travel = LayoutWheelLiquidSpring.Parameters(response: tuning.dropletResponse,
                                                        dampingRatio: tuning.dropletDamping)
        let growth = LayoutWheelLiquidSpring.Parameters(response: 0.3, dampingRatio: 0.8)
        let swell = LayoutWheelLiquidSpring.Parameters(response: 0.24, dampingRatio: 0.5)
        let oval = LayoutWheelLiquidSpring.Parameters(response: 0.22, dampingRatio: 0.28)
        let fade = LayoutWheelLiquidSpring.Parameters(response: 0.12, dampingRatio: 1)
        for index in droplets.indices {
            var drop = droplets[index]
            drop.openingElapsed = min(LayoutWheelLiquidDroplet.openingConnectionWindow.upperBound, drop.openingElapsed + dt)
            let tintTarget = !drop.isRetracting && input.fan?.aimedOption == drop.option ? 1.0 : 0.0
            drop.iconTint += min(dt / 0.12, max(-dt / 0.12, tintTarget - drop.iconTint))
            drop.x.advance(dt, travel)
            drop.y.advance(dt, travel)
            drop.size.advance(dt, growth)
            drop.swell.advance(dt, swell)
            drop.fade.advance(dt, fade)
            if !reduceMotion {
                // Moving liquid stretches along its path.
                let speed = hypot(drop.x.velocity, drop.y.velocity)
                let amount = min(0.12, speed * 0.00025 / layout.scale)
                let heading = atan2(drop.y.velocity, drop.x.velocity)
                drop.ovalCosine.target = speed > 1 ? amount * cos(2 * heading) : 0
                drop.ovalSine.target = speed > 1 ? amount * sin(2 * heading) : 0
            }
            drop.ovalCosine.advance(dt, oval)
            drop.ovalSine.advance(dt, oval)
            droplets[index] = drop
            if !reduceMotion { updateAttachment(index) }
        }
        droplets.removeAll { drop in
            drop.isRetracting && (reduceMotion ? drop.fade.value < 0.02 : drop.size.value < 0.04)
        }
    }

    /// The gap between a droplet's edge and the rim below it, measured from the
    /// rim's target rather than its wobble, so ringing cannot cause flicker.
    public func gap(of drop: LayoutWheelLiquidDroplet) -> Double {
        let center = drop.center
        let angle = atan2(center.y, center.x)
        return hypot(center.x, center.y) - drop.radius - layout.outerRadius - baseDisplacement(at: angle)
    }

    private mutating func updateAttachment(_ index: Int) {
        let drop = droplets[index]
        let gap = gap(of: drop)
        let angle = atan2(drop.y.value, drop.x.value)
        let heading = atan2(drop.y.velocity, drop.x.velocity)
        if drop.isAttached, gap > tuning.detachGap * layout.scale {
            droplets[index].isAttached = false
            // The neck snaps: the rim springs back and the drop wobbles.
            outer.strike(angle: angle, halfWidth: neckHalfWidth(drop), speed: -220 * tuning.splash * layout.scale * drop.connection)
            droplets[index].ovalCosine.velocity += 2.6 * cos(2 * heading)
            droplets[index].ovalSine.velocity += 2.6 * sin(2 * heading)
        } else if !drop.isAttached, gap < tuning.attachGap * layout.scale {
            droplets[index].isAttached = true
            outer.strike(angle: angle, halfWidth: neckHalfWidth(drop), speed: 160 * tuning.splash * layout.scale * drop.connection)
            droplets[index].ovalCosine.velocity -= 2.0 * cos(2 * heading)
            droplets[index].ovalSine.velocity -= 2.0 * sin(2 * heading)
        }
    }

    private func neckHalfWidth(_ drop: LayoutWheelLiquidDroplet) -> Double {
        let distance = max(1, hypot(drop.x.value, drop.y.value))
        return min(0.6, 1.6 * asin(min(1, max(0.05, drop.radius / distance))))
    }

    // MARK: Rim targets

    /// Bulges and stretch on the outer rim, without necks or area correction.
    private func baseDisplacement(at angle: Double) -> Double {
        var value = 0.0
        if !reduceMotion {
            let ring = layout.outermostRing
            for slot in 0..<layout.slotCount {
                let m = magnets[ring * layout.slotCount + slot].value
                guard abs(m) > 1e-5 else { continue }
                value += tuning.bulge * layout.scale * m * LayoutWheelLiquidRim.bump(
                    offset: LayoutWheelLiquidRim.wrapped(angle - layout.slotAngle(slot)),
                    halfWidth: layout.slotWidth * 0.75)
            }
            if reach.value > 1e-4 { value += lobe(at: angle) }
        }
        return value
    }

    private mutating func rebuildTargets() {
        guard !reduceMotion else { return } // The rims stay perfect circles.
        let count = LayoutWheelLiquidRim.sampleCount
        var necks: [(angle: Double, height: Double, width: Double)] = []
        for drop in droplets where drop.isAttached && drop.size.value > 0.05 {
            let gap = gap(of: drop)
            let height = min(max(0, gap), tuning.detachGap * layout.scale) * drop.connection
            if height > 0 {
                necks.append((atan2(drop.y.value, drop.x.value), height, neckHalfWidth(drop)))
            }
        }
        for index in 0..<count {
            let angle = LayoutWheelLiquidRim.angle(ofSample: index)
            var value = baseDisplacement(at: angle)
            for neck in necks {
                value += neck.height * LayoutWheelLiquidRim.bump(
                    offset: LayoutWheelLiquidRim.wrapped(angle - neck.angle), halfWidth: neck.width)
            }
            profile[index] = value
        }
        Self.preserveArea(&profile, restRadius: layout.outerRadius)
        outer.setTarget(profile)

        guard step != nil, let stepRadius = layout.stepRadius else { return }
        for index in 0..<count {
            let angle = LayoutWheelLiquidRim.angle(ofSample: index)
            var value = 0.0
            for slot in 0..<layout.slotCount {
                let m = magnets[slot].value
                guard abs(m) > 1e-5 else { continue }
                value += 0.6 * tuning.bulge * layout.scale * m * LayoutWheelLiquidRim.bump(
                    offset: LayoutWheelLiquidRim.wrapped(angle - layout.slotAngle(slot)),
                    halfWidth: layout.slotWidth * 0.75)
            }
            profile[index] = value
        }
        Self.preserveArea(&profile, restRadius: stepRadius)
        step?.setTarget(profile)
    }

    /// Lowers the whole outline by the one constant that keeps the mean
    /// squared radius, which is the enclosed area, equal to the rest circle's.
    /// A bulge then draws its liquid from the rest of the ring.
    static func preserveArea(_ samples: inout [Double], restRadius r: Double) {
        guard !samples.isEmpty else { return }
        let count = Double(samples.count)
        let mean = samples.reduce(0, +) / count
        let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / count
        // Solve mean((r + d - c)^2) = r^2 for the smaller root c.
        let discriminant = r * r + mean * mean - meanSquare
        guard discriminant > 0 else { return }
        let shift = r + mean - discriminant.squareRoot()
        for index in samples.indices { samples[index] -= shift }
    }

    // MARK: Presence and rest

    private mutating func advancePresence(_ dt: Double) {
        if reduceMotion {
            // A short linear fade: no scale change and nothing that overshoots.
            let rate = dt / 0.12
            presence.value += max(-rate, min(rate, presence.target - presence.value))
            presence.velocity = 0
            return
        }
        let parameters: LayoutWheelLiquidSpring.Parameters = switch (phase, tuning.opening, tuning.closing) {
        case (.closing, _, .quick): .init(response: 0.1, dampingRatio: 1)
        case (.closing, _, .sink): .init(response: 0.3, dampingRatio: 1)
        case (.closing(.cancel), _, _): .init(response: 0.16, dampingRatio: 1)
        case (.closing, _, _): .init(response: 0.22, dampingRatio: 1)
        case (_, .rise, _): .init(response: 0.34, dampingRatio: 0.68)
        case (_, .bloom, _): .init(response: 0.32, dampingRatio: 1)
        case (_, .quick, _): .init(response: 0.12, dampingRatio: 1)
        default: .init(response: 0.26, dampingRatio: 1)
        }
        presence.advance(dt, parameters)
    }

    private var isSettled: Bool {
        guard presence.isSettled(tolerance: 0.001, velocityTolerance: 0.01),
              closingHold == 0, !impactPending,
              aim.isSettled(tolerance: 0.0005, velocityTolerance: 0.005),
              glow.isSettled(tolerance: 0.001, velocityTolerance: 0.01),
              glowRadius.isSettled(tolerance: 0.01, velocityTolerance: 0.1),
              reach.isSettled(tolerance: 0.01, velocityTolerance: 0.1),
              reachAngle.isSettled(tolerance: 0.0005, velocityTolerance: 0.005),
              driftX.isSettled(tolerance: 0.01, velocityTolerance: 0.1),
              driftY.isSettled(tolerance: 0.01, velocityTolerance: 0.1),
              magnets.allSatisfy({ $0.isSettled(tolerance: 0.001, velocityTolerance: 0.01) }),
              iconTints.enumerated().allSatisfy({ pair in
                  let target = phase == .open && input.focus.map({ self.index($0) == pair.offset }) == true ? 1.0 : 0.0
                  return abs(pair.element - target) < 1e-9
              }),
              abs(submenuDimming - (phase == .open && input.fan != nil ? 1 : 0)) < 1e-9,
              outer.isSettled, step?.isSettled ?? true
        else { return false }
        return droplets.allSatisfy { drop in
            !drop.isRetracting
                && drop.openingElapsed >= LayoutWheelLiquidDroplet.openingConnectionWindow.upperBound
                && abs(drop.iconTint - (input.fan?.aimedOption == drop.option ? 1 : 0)) < 1e-9
                && drop.x.isSettled(tolerance: 0.01, velocityTolerance: 0.1)
                && drop.y.isSettled(tolerance: 0.01, velocityTolerance: 0.1)
                && drop.size.isSettled(tolerance: 0.001, velocityTolerance: 0.01)
                && drop.swell.isSettled(tolerance: 0.001, velocityTolerance: 0.01)
                && drop.fade.isSettled(tolerance: 0.001, velocityTolerance: 0.01)
                && drop.ovalCosine.isSettled(tolerance: 0.0005, velocityTolerance: 0.005)
                && drop.ovalSine.isSettled(tolerance: 0.0005, velocityTolerance: 0.005)
        }
    }

    /// Lands every channel exactly on its target, so the resting picture is a
    /// fixed point and the clock can stop.
    private mutating func settle() {
        presence.settle(); aim.settle(); glow.settle(); glowRadius.settle()
        reach.settle(); reachAngle.settle(); driftX.settle(); driftY.settle()
        for index in magnets.indices { magnets[index].settle() }
        for index in droplets.indices {
            droplets[index].x.settle(); droplets[index].y.settle()
            droplets[index].size.settle(); droplets[index].swell.settle()
            droplets[index].fade.settle()
            droplets[index].ovalCosine.settle(); droplets[index].ovalSine.settle()
        }
        // Targets come from the settled channels, so a later frame rebuilds
        // exactly these and the state stays put.
        rebuildTargets()
        outer.settle(); step?.settle()
    }
}
