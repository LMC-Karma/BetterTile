import Foundation
import Testing
@testable import BetterTileCore

// Grouped Medium proportions: two rings, fans beyond the outer edge.
private let twoRings = LayoutWheelLiquidLayout(outerRadius: 154, stepRadius: 91, wellRadius: 32,
                                               iconRadii: [60, 124], dropletRadius: 22)
private let oneRing = LayoutWheelLiquidLayout(outerRadius: 84, wellRadius: 32, iconRadii: [58], dropletRadius: 22)

private func vector(slot: Int, radius: Double, layout: LayoutWheelLiquidLayout = twoRings) -> BTPoint {
    let angle = layout.slotAngle(slot)
    return BTPoint(x: cos(angle) * radius, y: sin(angle) * radius)
}

private func focus(_ slot: Int, radius: Double = 124, ring: Int = 1) -> LayoutWheelLiquidInput {
    .init(pointer: vector(slot: slot, radius: radius), focus: .init(ring: ring, slot: slot))
}

private func fan(_ slot: Int, radius: Double = 197, aimed: Int? = nil) -> LayoutWheelLiquidInput.Fan {
    let angle = twoRings.slotAngle(slot)
    let options = [-0.45, 0, 0.45].map { BTPoint(x: cos(angle + $0) * radius, y: sin(angle + $0) * radius) }
    return .init(parentSlot: slot, options: options, aimedOption: aimed)
}

/// Advances until rest, returning the elapsed time, or nil after `limit`.
@discardableResult
private func settle(_ model: inout LayoutWheelLiquid, hz: Double = 120, limit: Double = 4) -> Double? {
    var elapsed = 0.0
    while elapsed < limit {
        if model.isAtRest { return elapsed }
        model.advance(1 / hz)
        elapsed += 1 / hz
    }
    return model.isAtRest ? elapsed : nil
}

private func outline(_ rim: LayoutWheelLiquidRim) -> [Double] {
    (0..<LayoutWheelLiquidRim.sampleCount).map { rim.displacement(at: LayoutWheelLiquidRim.angle(ofSample: $0)) }
}

/// One scripted gesture: open, sweep every slot, stretch, open a fan, aim a
/// child, leave the fan, and release. Returns every frame's model.
private func scriptedGesture(hz: Double, reduceMotion: Bool = false,
                             ending: LayoutWheelLiquid.Ending = .commit) -> [LayoutWheelLiquid] {
    var model = LayoutWheelLiquid(layout: twoRings, reduceMotion: reduceMotion)
    var frames: [LayoutWheelLiquid] = []
    var time = 0.0
    func run(until end: Double, _ input: (Double) -> LayoutWheelLiquidInput?) {
        while time < end - 1e-9 {
            if let next = input(time) { model.update(next) }
            model.advance(1 / hz)
            time += 1 / hz
            frames.append(model)
        }
    }
    model.open()
    run(until: 0.3) { _ in nil }
    run(until: 1.3) { time in
        let slot = Int((time - 0.3) / 0.125) % 8
        return focus(slot, ring: slot % 2)
    }
    run(until: 1.8) { time in
        .init(pointer: vector(slot: 2, radius: 124 + 300 * (time - 1.3)), focus: .init(ring: 1, slot: 2))
    }
    run(until: 2.4) { _ in .init(pointer: vector(slot: 2, radius: 124), focus: .init(ring: 1, slot: 2), fan: fan(2)) }
    run(until: 2.8) { _ in .init(pointer: vector(slot: 2, radius: 197), focus: .init(ring: 1, slot: 2), fan: fan(2, aimed: 1)) }
    run(until: 3.2) { _ in focus(6) }
    if ending == .commit { model.release() } else { model.cancel() }
    run(until: 4.2) { _ in nil }
    return frames
}

// MARK: - Springs

@Suite struct LayoutWheelLiquidSpringTests {
    @Test(arguments: [0.2, 0.58, 1.0])
    func closedFormMatchesAFineNumericalSolution(damping: Double) {
        let parameters = LayoutWheelLiquidSpring.Parameters(response: 0.28, dampingRatio: damping)
        var exact = LayoutWheelLiquidSpring(value: 0, target: 1)
        exact.velocity = 3
        var x = 0.0, v = 3.0
        let omega = parameters.angularFrequency, zeta = parameters.dampingRatio
        let h = 1e-5
        for _ in 0..<Int(0.5 / h) {
            v += (-omega * omega * (x - 1) - 2 * zeta * omega * v) * h
            x += v * h
        }
        exact.advance(0.5, parameters)
        #expect(abs(exact.value - x) < 1e-3)
        #expect(abs(exact.velocity - v) < 1e-2)
    }

    @Test func oneLongStepEqualsManyShortSteps() {
        let parameters = LayoutWheelLiquidSpring.Parameters(response: 0.3, dampingRatio: 0.5)
        var once = LayoutWheelLiquidSpring(value: 0, target: 10)
        once.advance(0.75, parameters)
        for hz in [60.0, 120.0, 240.0] {
            var stepped = LayoutWheelLiquidSpring(value: 0, target: 10)
            for _ in 0..<Int(0.75 * hz) { stepped.advance(1 / hz, parameters) }
            #expect(abs(stepped.value - once.value) < 1e-9)
            #expect(abs(stepped.velocity - once.velocity) < 1e-8)
        }
    }

    @Test func underdampedOvershootsOnceAndSettlesCriticalNeverOvershoots() {
        func trace(_ damping: Double) -> (peak: Double, settledAt: Double?) {
            let parameters = LayoutWheelLiquidSpring.Parameters(response: 0.28, dampingRatio: damping)
            var spring = LayoutWheelLiquidSpring(value: 0, target: 1)
            var peak = 0.0
            for frame in 1...240 {
                spring.advance(1 / 120, parameters)
                peak = max(peak, spring.value)
                if spring.isSettled(tolerance: 0.001, velocityTolerance: 0.01) { return (peak, Double(frame) / 120) }
            }
            return (peak, nil)
        }
        let magnet = trace(0.58)
        #expect(magnet.peak > 1.05 && magnet.peak < 1.2)
        #expect(magnet.settledAt.map { $0 < 0.8 } == true)
        let critical = trace(1)
        #expect(critical.peak <= 1)
        #expect(critical.settledAt.map { $0 < 0.5 } == true)
    }

    @Test func nonFiniteStepsAndParametersAreIgnored() {
        var spring = LayoutWheelLiquidSpring(value: 0, target: 1)
        let parameters = LayoutWheelLiquidSpring.Parameters(response: .nan, dampingRatio: .infinity)
        for dt in [0, -1, .nan, .infinity] { spring.advance(dt, parameters) }
        #expect(spring.value == 0 && spring.velocity == 0)
        spring.advance(1 / 60, parameters)
        #expect(spring.value.isFinite && spring.velocity.isFinite)
    }
}

// MARK: - Rim

@Suite struct LayoutWheelLiquidRimTests {
    @Test func aSmoothTargetIsReproducedAndSettles() {
        var rim = LayoutWheelLiquidRim(restRadius: 154)
        let width = Double.pi / 4 * 0.75
        rim.setTarget((0..<LayoutWheelLiquidRim.sampleCount).map {
            7 * LayoutWheelLiquidRim.bump(offset: LayoutWheelLiquidRim.wrapped(LayoutWheelLiquidRim.angle(ofSample: $0)), halfWidth: width)
        })
        let spectrum = LayoutWheelLiquidRim.Spectrum(tension: 2.6, ringing: 0.32)
        var elapsed = 0.0
        while !rim.isSettled, elapsed < 3 { rim.advance(1 / 120, spectrum: spectrum); elapsed += 1 / 120 }
        #expect(rim.isSettled)
        #expect(elapsed < 2)
        // The series is filtered, so the peak rounds off slightly.
        #expect(abs(rim.displacement(at: 0) - 7) < 0.3)
        #expect(abs(rim.displacement(at: .pi)) < 0.15)
    }

    @Test func aStrikeRingsKeepsTheAreaAndDiesOut() {
        var rim = LayoutWheelLiquidRim(restRadius: 154)
        rim.strike(angle: -.pi / 2, halfWidth: 0.55, speed: 240)
        let spectrum = LayoutWheelLiquidRim.Spectrum(tension: 2.6, ringing: 0.32)
        var lowest = 0.0, highest = 0.0, largestAreaError = 0.0, elapsed = 0.0
        while elapsed < 3 {
            rim.advance(1 / 120, spectrum: spectrum)
            elapsed += 1 / 120
            let top = rim.displacement(at: -.pi / 2)
            lowest = min(lowest, top); highest = max(highest, top)
            largestAreaError = max(largestAreaError, abs(rim.areaRatio - 1))
        }
        #expect(highest > 2)
        // It swings back past rest: that is the ringing.
        #expect(lowest < -0.3)
        #expect(largestAreaError < 0.003)
        #expect(rim.isSettled)
        #expect(outline(rim).allSatisfy { abs($0) < 0.02 })
    }

    @Test func fineHarmonicsAreDampedHarderThanBroadOnes() {
        let spectrum = LayoutWheelLiquidRim.Spectrum(tension: 2.6, ringing: 0.32)
        let ratios = spectrum.modes.map(\.dampingRatio)
        #expect(ratios[2] < ratios[4] && ratios[4] < ratios[6])
        #expect(ratios[12...].allSatisfy { $0 == 1 })
        #expect(LayoutWheelLiquidRim.Spectrum(tension: 2.6, ringing: 0.32, reduceMotion: true)
            .modes.allSatisfy { $0.dampingRatio == 1 })
    }

    @Test func sampledDerivativesMatchTheOutline() {
        var rim = LayoutWheelLiquidRim(restRadius: 100)
        rim.setTarget((0..<LayoutWheelLiquidRim.sampleCount).map {
            5 * cos(3 * LayoutWheelLiquidRim.angle(ofSample: $0))
        })
        rim.settle()
        var samples: [SIMD4<Float>] = []
        rim.sample(into: &samples)
        let h = 1e-3
        for index in stride(from: 0, to: LayoutWheelLiquidRim.sampleCount, by: 17) {
            let angle = LayoutWheelLiquidRim.angle(ofSample: index)
            let r = rim.radius(at: angle), before = rim.radius(at: angle - h), after = rim.radius(at: angle + h)
            #expect(abs(Double(samples[index].x) - r) < 1e-3)
            #expect(abs(Double(samples[index].y) - (after - before) / (2 * h)) < 1e-3)
            #expect(abs(Double(samples[index].z) - (after - 2 * r + before) / (h * h)) < 0.05)
        }
        // Almost all of the oval-free third harmonic survives the filter.
        #expect(abs(rim.displacement(at: 0) - 5) < 0.1)
    }

    @Test func areaCorrectionKeepsTheMeanSquareRadius() {
        var samples = (0..<LayoutWheelLiquidRim.sampleCount).map {
            30 * LayoutWheelLiquidRim.bump(offset: LayoutWheelLiquidRim.wrapped(LayoutWheelLiquidRim.angle(ofSample: $0)), halfWidth: 0.5)
        }
        LayoutWheelLiquid.preserveArea(&samples, restRadius: 154)
        let meanSquare = samples.reduce(0) { $0 + (154 + $1) * (154 + $1) } / Double(samples.count)
        #expect(abs(meanSquare / (154 * 154) - 1) < 1e-12)
        // The liquid for the bump comes from everywhere else.
        #expect(samples[128] < 0)
    }
}

// MARK: - Model

@Suite struct LayoutWheelLiquidModelTests {
    @Test func openComesToRestAndRestIsAFixedPoint() {
        var model = LayoutWheelLiquid(layout: twoRings)
        #expect(model.isAtRest) // Closed: nothing to draw.
        model.open()
        #expect(!model.isAtRest)
        let opened = settle(&model)
        #expect(opened.map { $0 < 0.6 } == true)
        #expect(model.opacity == 1 && model.scale == 1)
        model.update(focus(3))
        #expect(!model.isAtRest)
        #expect(settle(&model).map { $0 < 2 } == true)
        let resting = model
        for _ in 0..<120 { model.advance(1 / 120) }
        #expect(model == resting)
        // Pointer motion inside the same slot changes nothing that is drawn.
        model.update(.init(pointer: vector(slot: 3, radius: 110), focus: .init(ring: 1, slot: 3)))
        #expect(model.isAtRest)
        // A new slot wakes it.
        model.update(focus(4))
        #expect(!model.isAtRest)
    }

    @Test func theAimedSlotSnapsInWithOneOvershoot() {
        var model = LayoutWheelLiquid(layout: twoRings)
        model.open()
        settle(&model)
        model.update(focus(2))
        var values: [Double] = []
        for _ in 0..<240 {
            model.advance(1 / 120)
            values.append(model.magnet(ring: 1, slot: 2))
        }
        let peak = values.max() ?? 0
        #expect(peak > 1.04 && peak < 1.25)
        // After the first swing back below 1, every later ripple is invisible.
        let peakIndex = values.firstIndex(of: peak) ?? 0
        let back = values[peakIndex...].firstIndex { $0 < 1 } ?? values.count
        #expect(values[back...].allSatisfy { abs($0 - 1) < 0.03 })
        #expect(model.outer.radius(at: twoRings.slotAngle(2)) > 154 + 0.6 * 7)
    }

    @Test func outlineAreaStaysWithinOnePercentThroughAWholeGesture() {
        for hz in [60.0, 120.0] {
            for frame in scriptedGesture(hz: hz) {
                #expect(abs(frame.outer.areaRatio - 1) < 0.01)
                if let step = frame.step { #expect(abs(step.areaRatio - 1) < 0.01) }
            }
        }
    }

    @Test func stretchFollowsThePointerWithASoftLimitAndRecoils() {
        var model = LayoutWheelLiquid(layout: twoRings)
        model.open()
        model.update(focus(2))
        settle(&model)
        let bulge = model.outer.displacement(at: 0)
        model.update(.init(pointer: vector(slot: 2, radius: 164), focus: .init(ring: 1, slot: 2)))
        settle(&model)
        let near = model.outer.displacement(at: 0) - bulge
        model.update(.init(pointer: vector(slot: 2, radius: 1000), focus: .init(ring: 1, slot: 2)))
        settle(&model)
        let far = model.outer.displacement(at: 0) - bulge
        #expect(near > 6 && near < 11)
        // The soft limit is 30 pt; the lobe also draws a little liquid from the bulge beside it.
        #expect(far > 20 && far <= 32)
        // Snap the pointer back inside: the rim springs past its resting bulge.
        model.update(focus(2))
        var lowest = Double.infinity
        for _ in 0..<120 {
            model.advance(1 / 120)
            lowest = min(lowest, model.outer.displacement(at: 0))
        }
        #expect(lowest < bulge - 1)
        #expect(settle(&model) != nil)
        #expect(abs(model.outer.displacement(at: 0) - bulge) < 0.05)
    }

    @Test func noStretchWhileAFanIsOpenOrOnTheInnerRing() {
        var model = LayoutWheelLiquid(layout: twoRings)
        model.open()
        model.update(.init(pointer: vector(slot: 2, radius: 400), focus: .init(ring: 0, slot: 2)))
        settle(&model)
        #expect(model.outer.displacement(at: 0) < 0.05)
        model.update(.init(pointer: vector(slot: 2, radius: 400), focus: .init(ring: 1, slot: 2), fan: fan(2)))
        settle(&model)
        #expect(model.outer.displacement(at: 0) < 7 + 0.5)
    }

    @Test func dropletsBudPinchOffOnceAndReturn() {
        var model = LayoutWheelLiquid(layout: twoRings)
        model.open()
        model.update(focus(2))
        settle(&model)
        model.update(.init(pointer: vector(slot: 2, radius: 124), focus: .init(ring: 1, slot: 2), fan: fan(2)))
        #expect(model.droplets.count == 3)
        #expect(model.droplets.allSatisfy { $0.isAttached })
        var detachments = 0
        var attached = model.droplets.map(\.isAttached)
        for _ in 0..<360 {
            model.advance(1 / 120)
            let now = model.droplets.map(\.isAttached)
            detachments += zip(attached, now).filter { $0 && !$1 }.count
            attached = now
        }
        #expect(detachments == 3)
        #expect(model.isAtRest)
        for drop in model.droplets {
            #expect(!drop.isAttached)
            #expect(abs(hypot(drop.center.x, drop.center.y) - 197) < 0.05)
        }
        model.update(focus(2))
        #expect(model.droplets.allSatisfy { $0.isRetracting })
        #expect(settle(&model).map { $0 < 1 } == true)
        #expect(model.droplets.isEmpty)
    }

    /// Swings one droplet's gap by +/-1.5 pt around `gap`, once a second for
    /// seven seconds, and counts attach/detach changes after the first second.
    /// `startFar` parks it detached first, so the attach threshold is crossed
    /// from outside.
    private func boundaryTransitions(_ tuning: LayoutWheelLiquidTuning, around gap: Double,
                                     startFar: Bool) -> (transitions: Int, attached: Bool) {
        var model = LayoutWheelLiquid(layout: twoRings, tuning: tuning)
        model.open()
        model.update(focus(2))
        settle(&model)
        // The aimed slot's settled bulge is the rim the gap is measured from.
        let rim = twoRings.outerRadius + tuning.bulge
        var transitions = 0
        var last: Bool?
        var attached = false
        for frame in 0..<(8 * 120) {
            let t = Double(frame) / 120
            let swing = t < 1 ? (startFar ? 20 - gap : 0) : 1.5 * sin(2 * .pi * (t - 1))
            let distance = rim + 22 + gap + swing
            model.update(.init(pointer: vector(slot: 2, radius: 124), focus: .init(ring: 1, slot: 2),
                               fan: .init(parentSlot: 2, options: [BTPoint(x: distance, y: 0)])))
            model.advance(1 / 120)
            guard let drop = model.droplets.first(where: { !$0.isRetracting }) else { continue }
            if t >= 1, let last, last != drop.isAttached { transitions += 1 }
            last = drop.isAttached
            attached = drop.isAttached
        }
        return (transitions, attached)
    }

    @Test func attachmentHysteresisHasNoChatterAcrossEitherThreshold() {
        let tuning = LayoutWheelLiquidTuning.standard
        // Around the detach threshold the drop leaves once and stays away.
        let detach = boundaryTransitions(tuning, around: tuning.detachGap, startFar: false)
        #expect(detach.transitions <= 1)
        #expect(!detach.attached)
        // Around the attach threshold, coming from outside, it lands once and stays.
        let attach = boundaryTransitions(tuning, around: tuning.attachGap, startFar: true)
        #expect(attach.transitions <= 1)
        #expect(attach.attached)
    }

    @Test func withoutHysteresisTheSameSwingChatters() {
        // Control: one threshold for both directions flips on every crossing,
        // so the test above would fail if the two thresholds were equal.
        var tuning = LayoutWheelLiquidTuning.standard
        tuning.attachGap = tuning.detachGap
        #expect(boundaryTransitions(tuning, around: tuning.detachGap, startFar: false).transitions >= 6)
        tuning.detachGap = LayoutWheelLiquidTuning.standard.attachGap
        tuning.attachGap = tuning.detachGap
        #expect(boundaryTransitions(tuning, around: tuning.attachGap, startFar: true).transitions >= 6)
    }

    @Test func releasePopsTheSelectionThenFades() {
        var model = LayoutWheelLiquid(layout: twoRings)
        model.open()
        model.update(focus(6))
        settle(&model)
        model.release()
        #expect(model.phase == .closing(.commit))
        var peak = 0.0, largest = 0.0, elapsed = 0.0
        while model.phase != .closed, elapsed < 1 {
            model.advance(1 / 120)
            elapsed += 1 / 120
            peak = max(peak, model.magnet(ring: 1, slot: 6))
            largest = max(largest, model.scale)
        }
        #expect(peak > 1.15)
        #expect(largest > 1.005)
        #expect(model.phase == .closed && model.isAtRest)
        #expect(elapsed < 0.45)
        // A closed wheel ignores input and time.
        let closed = model
        model.update(focus(1)); model.advance(1 / 60)
        #expect(model == closed)
    }

    @Test func cancelFadesQuicklyWithoutAPopAndRetractsFans() {
        var model = LayoutWheelLiquid(layout: twoRings)
        model.open()
        model.update(.init(pointer: vector(slot: 2, radius: 124), focus: .init(ring: 1, slot: 2), fan: fan(2, aimed: 0)))
        settle(&model)
        model.cancel()
        #expect(model.phase == .closing(.cancel))
        #expect(model.droplets.allSatisfy { $0.isRetracting })
        var previous = model.magnet(ring: 1, slot: 2), elapsed = 0.0, smallest = 1.0
        while model.phase != .closed, elapsed < 1 {
            model.advance(1 / 120)
            elapsed += 1 / 120
            let value = model.magnet(ring: 1, slot: 2)
            #expect(value <= previous + 1e-12)
            previous = value
            smallest = min(smallest, model.scale)
        }
        #expect(elapsed < 0.3)
        #expect(smallest < 0.95)
        #expect(model.phase == .closed)
    }

    @Test func reduceMotionHasNoRingingNoStretchAndShortFades() {
        let frames = scriptedGesture(hz: 120, reduceMotion: true)
        for frame in frames {
            #expect(outline(frame.outer).allSatisfy { $0 == 0 })
            #expect(frame.scale == 1)
            for ring in 0..<2 { for slot in 0..<8 { #expect(frame.magnet(ring: ring, slot: slot) <= 1 + 1e-12) } }
            for drop in frame.droplets {
                #expect(drop.ovalCosine.value == 0 && drop.ovalSine.value == 0)
                #expect(abs(hypot(drop.center.x, drop.center.y) - 197) < 1e-9)
            }
        }
        // Open and both endings are fades of at most about a tenth of a second.
        var model = LayoutWheelLiquid(layout: twoRings, reduceMotion: true)
        model.open()
        #expect(settle(&model).map { $0 <= 0.13 } == true)
        model.update(focus(1))
        #expect(settle(&model).map { $0 <= 0.2 } == true)
        model.cancel()
        var elapsed = 0.0
        while model.phase != .closed, elapsed < 1 { model.advance(1 / 120); elapsed += 1 / 120 }
        #expect(elapsed <= 0.13)
        let commit = scriptedGesture(hz: 120, reduceMotion: true, ending: .commit)
        #expect(commit.last?.phase == .closed)
    }

    @Test func replayIsDeterministicAndAgreesAcrossFrameRates() {
        #expect(scriptedGesture(hz: 120) == scriptedGesture(hz: 120))
        // Sample both rates at the same instants: every 1/60 s.
        let at60 = scriptedGesture(hz: 60)
        let at120 = scriptedGesture(hz: 120)
        var largest = 0.0
        for (index, slow) in at60.enumerated() where 2 * index + 1 < at120.count {
            let fast = at120[2 * index + 1]
            for angle in stride(from: 0.0, to: 2 * .pi, by: .pi / 16) {
                largest = max(largest, abs(slow.outer.displacement(at: angle) - fast.outer.displacement(at: angle)))
            }
        }
        // Input arrives once per frame, so 60 Hz sees each change up to 8 ms later.
        #expect(largest < 3)
        #expect(at60.last?.phase == .closed && at120.last?.phase == .closed)
    }

    @Test func oneRingBulgesItsOnlyEdgeAndNonFiniteInputIsHarmless() {
        var model = LayoutWheelLiquid(layout: oneRing)
        model.open()
        model.update(.init(pointer: vector(slot: 4, radius: 60, layout: oneRing), focus: .init(ring: 0, slot: 4)))
        settle(&model)
        #expect(model.outer.radius(at: oneRing.slotAngle(4)) > 84 + 4)
        model.update(.init(pointer: BTPoint(x: .nan, y: .infinity), focus: .init(ring: 0, slot: 4)))
        model.advance(.nan); model.advance(-1); model.advance(.infinity)
        settle(&model)
        #expect(model.outer.radius(at: oneRing.slotAngle(4)).isFinite)
        #expect(model.isAtRest)
        // Out-of-range focus is clamped, not trapped.
        model.update(.init(focus: .init(ring: 7, slot: 99)))
        #expect(settle(&model) != nil)
    }
}
