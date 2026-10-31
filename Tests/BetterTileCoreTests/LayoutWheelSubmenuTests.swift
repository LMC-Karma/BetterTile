import Foundation
import Testing
@testable import BetterTileCore

// Grouped at the Custom size plus chevron room: hub 32, inner ring to 68,
// outer ring from 76, rim at 120.
private let geometry = LayoutWheelGeometry(hubRadius: 32, innerRingOuterRadius: 68, outerRingInnerRadius: 76)!
private let fan = LayoutWheelSubmenuLayout(rimRadius: 120, optionRadius: 22, style: .fan)
private let cluster = LayoutWheelSubmenuLayout(rimRadius: 120, optionRadius: 22, style: .cluster)

private func polar(_ sector: LayoutWheelSector, _ radius: Double, turn: Double = 0) -> BTPoint {
    let angle = -Double.pi / 2 + Double(sector.rawValue) * .pi / 4 + turn
    return BTPoint(x: cos(angle) * radius, y: sin(angle) * radius)
}

private func distance(_ a: BTPoint, _ b: BTPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

/// Rests on a group long enough to open it.
private func openGroup(_ sector: LayoutWheelSector, layout: LayoutWheelSubmenuLayout) -> (LayoutWheelFanState, Double) {
    var state = LayoutWheelFanState()
    let point = polar(sector, 98)
    state.update(vector: point, at: 0, geometry: geometry, layout: layout)
    state.update(vector: point, at: 0.25, geometry: geometry, layout: layout)
    return (state, 0.25)
}

@Suite struct LayoutWheelSubmenuLayoutTests {
    @Test(arguments: [2, 3, 4, 5, 6])
    func fanOptionsSitSideBySideJustOutsideTheRim(count: Int) {
        let points = fan.positions(sector: .right, count: count)
        #expect(points.count == count)
        for point in points {
            #expect(abs(hypot(point.x, point.y) - (120 + 8 + 22)) < 1e-9)
        }
        // Neighbours are 2 radii plus the 6 pt spacing apart, centre to centre.
        for (a, b) in zip(points, points.dropFirst()) {
            #expect(abs(distance(a, b) - 50) < 1e-6)
        }
        // Centred on the group.
        let mean = points.reduce(0) { $0 + atan2($1.y, $1.x) } / Double(count)
        #expect(abs(mean) < 1e-9)
    }

    @Test(arguments: [3, 4, 5, 6])
    func clusterOptionsRingAPointBeyondTheChevron(count: Int) {
        let points = cluster.positions(sector: .top, count: count)
        let center = BTPoint(x: points.reduce(0) { $0 + $1.x } / Double(count),
                             y: points.reduce(0) { $0 + $1.y } / Double(count))
        // The ring sits on the group's axis, straight out from the chevron.
        #expect(abs(center.x) < 1e-6 && center.y < -120)
        let ring = cluster.clusterRadius(count: count)
        for point in points {
            #expect(abs(distance(point, center) - ring) < 1e-6)
            // No option overlaps the rim.
            #expect(hypot(point.x, point.y) - 22 >= 120 + 8 - 1e-6)
        }
        let sorted = points.indices.map { index in
            points.indices.filter { $0 != index }.map { distance(points[index], points[$0]) }.min()!
        }
        #expect(sorted.allSatisfy { $0 >= 50 - 1e-6 })
    }

    @Test func clusterAboveThreeKeepsSmallGroupsAsFans() {
        let mixed = LayoutWheelSubmenuLayout(rimRadius: 120, optionRadius: 22, style: .clusterAboveThree)
        #expect(!mixed.usesCluster(count: 3))
        #expect(mixed.usesCluster(count: 4))
        #expect(!fan.usesCluster(count: 6))
        #expect(cluster.usesCluster(count: 3))
        #expect(!cluster.usesCluster(count: 2))
        #expect(mixed.positions(sector: .left, count: 3) == fan.positions(sector: .left, count: 3))
    }
}

@Suite struct LayoutWheelFanStateTests {
    @Test(arguments: LayoutWheelSubmenuLockBeyondRim.allCases)
    func farSideOutsideTheRimKeepsOrCancelsTheAim(_ policy: LayoutWheelSubmenuLockBeyondRim) {
        var (state, time) = openGroup(.top, layout: fan)
        let options = fan.positions(sector: .top, count: LayoutWheelGroup.at(.top).options.count)
        state.update(vector: options[1], at: time + 0.01, geometry: geometry, layout: fan, lockBeyondRim: policy)
        #expect(state.optionIndex == 1)
        for radius in [150.0, 1_000.0] {
            time += 0.02
            state.update(vector: polar(.bottom, radius), at: time, geometry: geometry, layout: fan, lockBeyondRim: policy)
            if policy == .keep {
                #expect(state.openSector == .top && state.optionIndex == 1)
                #expect(state.command == LayoutWheelGroup.at(.top).options[1])
            } else {
                #expect(state.openSector == nil && state.optionIndex == nil)
                #expect(state.selection == nil && state.command == nil && state.deadline == nil)
            }
        }
        #expect(state.release() == (policy == .keep ? LayoutWheelGroup.at(.top).options[1] : nil))
        #expect(state == LayoutWheelFanState())
    }

    @Test(arguments: LayoutWheelSubmenuStyle.allCases, LayoutWheelSector.allCases)
    func boundedLockReachesEveryOption(style: LayoutWheelSubmenuStyle, sector: LayoutWheelSector) {
        let layout = LayoutWheelSubmenuLayout(rimRadius: 120, optionRadius: 22, style: style)
        for (index, point) in layout.positions(sector: sector, count: LayoutWheelGroup.at(sector).options.count).enumerated() {
            var (state, time) = openGroup(sector, layout: layout)
            state.update(vector: point, at: time + 0.01, geometry: geometry, layout: layout, lockBeyondRim: .withinGroupAngle)
            #expect(state.optionIndex == index && state.openSector == sector)
            time += 0.02
            // Still held arbitrarily far out along the option's direction.
            state.update(vector: BTPoint(x: point.x * 10, y: point.y * 10), at: time,
                         geometry: geometry, layout: layout, lockBeyondRim: .withinGroupAngle)
            #expect(state.optionIndex == index && state.openSector == sector)
        }
    }

    @Test(arguments: LayoutWheelSubmenuLockBeyondRim.allCases, [-1.0, 1.0])
    func angularMarginDoesNotChatter(policy: LayoutWheelSubmenuLockBeyondRim, direction: Double) {
        // Displays' single option fits inside its sector, so its boundary is 22.5° + 10°.
        var (state, time) = openGroup(.right, layout: fan)
        let options = fan.positions(sector: .right, count: LayoutWheelGroup.at(.right).options.count)
        state.update(vector: options[0], at: time + 0.01, geometry: geometry, layout: fan, lockBeyondRim: policy)
        let boundary = Double.pi / 8 + LayoutWheelFanState.leaveMargin
        for frame in 0..<200 {
            time += 1 / 120
            let turn = direction * (boundary + (frame % 2 == 0 ? -0.01 : 0.01))
            state.update(vector: polar(.right, 300, turn: turn), at: time, geometry: geometry, layout: fan,
                         lockBeyondRim: policy)
            if policy == .keep || frame == 0 {
                #expect(state.openSector == .right && state.optionIndex == 0)
            } else {
                #expect(state.openSector == nil && state.command == nil && state.deadline == nil)
            }
        }
        if policy == .withinGroupAngle {
            // Crossing back inside the angle cannot rearm outside the rim, even after a rest.
            time += 1
            state.update(vector: options[0], at: time, geometry: geometry, layout: fan, lockBeyondRim: policy)
            #expect(state.selection == nil && state.deadline == nil)
            // Returning to another group on the ring starts a fresh rest.
            state.update(vector: polar(.topRight, 98), at: time + 0.01, geometry: geometry, layout: fan, lockBeyondRim: policy)
            #expect(state.openSector == nil && state.selection?.sector == .topRight)
            state.update(vector: polar(.topRight, 98), at: time + 0.22, geometry: geometry, layout: fan, lockBeyondRim: policy)
            #expect(state.openSector == .topRight && state.optionIndex == nil)
        }
    }

    @Test func restingOnAGroupOpensItAfter200Milliseconds() {
        var state = LayoutWheelFanState()
        let point = polar(.left, 98)
        state.update(vector: point, at: 0, geometry: geometry, layout: fan)
        #expect(state.openSector == nil && state.deadline == 0.2)
        state.update(vector: point, at: 0.19, geometry: geometry, layout: fan)
        #expect(state.openSector == nil)
        state.update(vector: point, at: 0.2, geometry: geometry, layout: fan)
        #expect(state.openSector == .left)
        #expect(state.selection == LayoutWheelSelection(ring: .outer, sector: .left))
        // No option is chosen for the user.
        #expect(state.optionIndex == nil)
    }

    @Test func anAimedOptionStaysAimedBetweenAndPastTheOptions() {
        var (state, time) = openGroup(.left, layout: fan)
        let options = fan.positions(sector: .left, count: LayoutWheelGroup.at(.left).options.count)
        time += 0.02
        state.update(vector: options[2], at: time, geometry: geometry, layout: fan)
        #expect(state.optionIndex == 2)
        // Halfway to the next option, and far beyond them: still option 2.
        let between = BTPoint(x: (options[2].x + options[3].x) / 2, y: (options[2].y + options[3].y) / 2)
        for point in [between, BTPoint(x: options[2].x * 1.8, y: options[2].y * 1.8)] {
            time += 0.02
            state.update(vector: point, at: time, geometry: geometry, layout: fan)
            #expect(state.optionIndex == 2)
            #expect(state.openSector == .left)
        }
        // Clearly on the next option: it moves.
        time += 0.02
        state.update(vector: options[3], at: time, geometry: geometry, layout: fan)
        #expect(state.optionIndex == 3)
        #expect(state.command == LayoutWheelGroup.at(.left).options[3])
    }

    @Test func anOpenGroupIgnoresOtherGroupsUntilThePointerIsWellInsideOne() {
        var (state, time) = openGroup(.top, layout: fan)
        // Past the rim above a neighbouring group: still the open group.
        for point in [polar(.topRight, 160), polar(.topLeft, 200), polar(.right, 150)] {
            time += 0.02
            state.update(vector: point, at: time, geometry: geometry, layout: fan)
            #expect(state.openSector == .top)
        }
        // On the ring, just past the boundary into the next group: still held.
        time += 0.02
        state.update(vector: polar(.top, 98, turn: .pi / 8 + 0.1), at: time, geometry: geometry, layout: fan)
        #expect(state.openSector == .top)
        // Well inside the next group on the ring: the group closes and the new one is aimed.
        time += 0.02
        state.update(vector: polar(.topRight, 98), at: time, geometry: geometry, layout: fan)
        #expect(state.openSector == nil)
        #expect(state.selection == LayoutWheelSelection(ring: .outer, sector: .topRight))
    }

    @Test(arguments: LayoutWheelSubmenuLockBeyondRim.allCases)
    func theInnerRingAndTheHubCloseAnOpenGroup(_ policy: LayoutWheelSubmenuLockBeyondRim) {
        var (state, time) = openGroup(.right, layout: fan)
        time += 0.02
        state.update(vector: polar(.right, 50), at: time, geometry: geometry, layout: fan, lockBeyondRim: policy)
        #expect(state.openSector == nil)
        #expect(state.selection == LayoutWheelSelection(ring: .inner, sector: .right))
        (state, time) = openGroup(.right, layout: fan)
        state.update(vector: BTPoint(x: 5, y: 0), at: time + 0.02, geometry: geometry, layout: fan, lockBeyondRim: policy)
        #expect(state.openSector == nil && state.selection == nil && state.command == nil)
    }

    @Test func releaseRunsTheAimedOptionOrTheGroupsMainAction() {
        var (state, time) = openGroup(.top, layout: cluster)
        let options = cluster.positions(sector: .top, count: LayoutWheelGroup.at(.top).options.count)
        #expect(state.command == LayoutWheelGroup.at(.top).quickAction)
        state.update(vector: options[1], at: time + 0.02, geometry: geometry, layout: cluster)
        #expect(state.release() == LayoutWheelGroup.at(.top).options[1])
        #expect(state == LayoutWheelFanState())
        time = 0
    }

    @Test func boundaryJitterBetweenTwoOptionsDoesNotFlicker() {
        var (state, time) = openGroup(.left, layout: fan)
        let options = fan.positions(sector: .left, count: LayoutWheelGroup.at(.left).options.count)
        time += 0.02
        state.update(vector: options[1], at: time, geometry: geometry, layout: fan)
        let middle = BTPoint(x: (options[1].x + options[2].x) / 2, y: (options[1].y + options[2].y) / 2)
        var changes = 0
        var last = state.optionIndex
        for frame in 0..<200 {
            let wobble = (frame % 2 == 0 ? 2.5 : -2.5)
            let dx = options[2].x - options[1].x, dy = options[2].y - options[1].y
            let length = hypot(dx, dy)
            time += 1 / 120
            state.update(vector: BTPoint(x: middle.x + dx / length * wobble, y: middle.y + dy / length * wobble),
                         at: time, geometry: geometry, layout: fan)
            if state.optionIndex != last { changes += 1; last = state.optionIndex }
        }
        #expect(changes == 0)
    }

    @Test func chooseLayoutStaysClosedWithoutALayout() {
        var state = LayoutWheelFanState()
        let point = polar(.bottomLeft, 98)
        state.update(vector: point, at: 0, geometry: geometry, layout: fan, layoutAvailable: false)
        state.update(vector: point, at: 0.3, geometry: geometry, layout: fan, layoutAvailable: false)
        #expect(state.openSector == nil && state.deadline == nil)
        state.update(vector: BTPoint(x: .nan, y: 0), at: 0.4, geometry: geometry, layout: fan)
        #expect(state.selection == nil)
    }
}

@Suite struct LayoutWheelLiquidPresetTests {
    private let layout = LayoutWheelLiquidLayout(outerRadius: 120, stepRadius: 72, wellRadius: 32,
                                                 iconRadii: [50, 98], dropletRadius: 22)

    private func run(_ model: inout LayoutWheelLiquid, until done: (LayoutWheelLiquid) -> Bool) -> Double? {
        var elapsed = 0.0
        while elapsed < 3 {
            if done(model) { return elapsed }
            model.advance(1 / 120); elapsed += 1 / 120
        }
        return nil
    }

    @Test(arguments: LayoutWheelLiquidOpening.allCases)
    func everyOpeningSettlesAtFullSize(_ opening: LayoutWheelLiquidOpening) {
        var tuning = LayoutWheelLiquidTuning.standard
        tuning.opening = opening
        var model = LayoutWheelLiquid(layout: layout, tuning: tuning)
        model.open()
        var largest = 0.0, smallest = 2.0
        let rest = run(&model) { model in
            largest = max(largest, model.scale); smallest = min(smallest, model.scale)
            return model.isAtRest
        }
        #expect(rest.map { $0 < 1.5 } == true)
        #expect(model.scale == 1 && model.opacity == 1)
        switch opening {
        case .rise: #expect(largest > 1.005) // It overshoots.
        case .bloom: #expect(smallest < 0.8 && abs(model.outer.displacement(at: 0)) < 0.05)
        case .quick: #expect(smallest > 0.96)
        case .calm: #expect(largest <= 1 + 1e-9)
        }
    }

    @Test func bloomStartsWithTheRimDrawnIn() {
        var tuning = LayoutWheelLiquidTuning.standard
        tuning.opening = .bloom
        var model = LayoutWheelLiquid(layout: layout, tuning: tuning)
        model.open()
        #expect(model.outer.radius(at: 0) < 120 - 10)
        var swungPast = false
        for _ in 0..<120 { model.advance(1 / 120); if model.outer.radius(at: 0) > 120.2 { swungPast = true } }
        #expect(swungPast)
    }

    @Test(arguments: LayoutWheelLiquidClosing.allCases)
    func everyClosingEndsClosed(_ closing: LayoutWheelLiquidClosing) {
        var tuning = LayoutWheelLiquidTuning.standard
        tuning.closing = closing
        for ending in [LayoutWheelLiquid.Ending.commit, .cancel] {
            var model = LayoutWheelLiquid(layout: layout, tuning: tuning)
            model.open()
            model.update(.init(pointer: BTPoint(x: 98, y: 0), focus: .init(ring: 1, slot: 2)))
            _ = run(&model) { $0.isAtRest }
            if ending == .commit { model.release() } else { model.cancel() }
            var smallest = 2.0
            let closed = run(&model) { model in
                if model.phase != .closed { smallest = min(smallest, model.scale) }
                return model.phase == .closed
            }
            let limit = closing == .quick ? 0.25 : 0.6
            #expect(closed.map { $0 < limit } == true)
            if closing == .sink { #expect(smallest < 0.7) }
            if closing == .quick { #expect(smallest == 1) }
        }
    }

    @Test func driftLeansTowardThePointerAndSettlesBack() {
        var tuning = LayoutWheelLiquidTuning.standard
        tuning.drift = 6
        var model = LayoutWheelLiquid(layout: layout, tuning: tuning)
        model.open()
        model.update(.init(pointer: BTPoint(x: 240, y: 0), focus: .init(ring: 1, slot: 2)))
        _ = run(&model) { $0.isAtRest }
        #expect(abs(model.drift.x - 6) < 0.02 && abs(model.drift.y) < 0.02)
        // No lean beyond the set distance, however far the pointer goes.
        model.update(.init(pointer: BTPoint(x: 0, y: 900), focus: .init(ring: 1, slot: 4)))
        var largest = 0.0
        _ = run(&model) { model in largest = max(largest, hypot(model.drift.x, model.drift.y)); return model.isAtRest }
        #expect(largest <= 6.3)
        model.cancel()
        _ = run(&model) { $0.phase == .closed }
        // Off by default and under Reduce Motion.
        var calm = LayoutWheelLiquid(layout: layout, tuning: tuning, reduceMotion: true)
        calm.open()
        calm.update(.init(pointer: BTPoint(x: 240, y: 0), focus: .init(ring: 1, slot: 2)))
        _ = run(&calm) { $0.isAtRest }
        #expect(calm.drift == BTPoint(x: 0, y: 0))
        #expect(LayoutWheelLiquidTuning.standard.drift == 0)
    }

    @Test func clusterDropletsGrowFromTheChevron() {
        var model = LayoutWheelLiquid(layout: layout)
        model.open()
        let chevron = BTPoint(x: 0, y: -120)
        let options = [BTPoint(x: -30, y: -190), BTPoint(x: 30, y: -190), BTPoint(x: 0, y: -230)]
        model.update(.init(pointer: BTPoint(x: 0, y: -98), focus: .init(ring: 1, slot: 0),
                           fan: .init(parentSlot: 0, options: options, emergence: chevron)))
        for drop in model.droplets {
            #expect(abs(drop.center.x) < 1e-9)
            #expect(drop.center.y > -120 && drop.center.y < -100)
        }
        _ = run(&model) { $0.isAtRest }
        for (drop, target) in zip(model.droplets, options) { #expect(distance(drop.center, target) < 0.05) }
    }
}
