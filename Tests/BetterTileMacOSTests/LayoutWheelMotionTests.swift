import AppKit
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor final class WheelTestClock: LayoutWheelFrameClock {
    private(set) var isRunning = false
    private(set) var starts = 0
    var callback: ((Double) -> Void)?
    var time = 0.0
    func start(on view: NSView, tick: @escaping (Double) -> Void) {
        starts += 1; isRunning = true; callback = tick
    }
    func stop() { isRunning = false; callback = nil }
    func frame(hz: Double = 60) { time += 1 / hz; callback?(time) }
    func settle(hz: Double = 60) {
        for _ in 0..<240 where isRunning { frame(hz: hz) }
    }
}

@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelMotionTests {
    @Test(arguments: [60.0, 120.0])
    func fanSettlesOnceWithinTheOriginal120Milliseconds(hz: Double) {
        var spring = LayoutWheelSpring()
        spring.target = 1
        var peak = 0.0
        var firstRest: Double?
        for frame in 1...Int(hz) {
            spring.advance(1 / hz)
            peak = max(peak, spring.value)
            if spring.isAtRest, firstRest == nil { firstRest = Double(frame) / hz }
            if firstRest != nil {
                #expect(spring.isAtRest)
                #expect(spring.value == 1 && spring.velocity == 0)
            }
        }
        #expect(firstRest != nil && firstRest! <= 0.120)
        #expect(peak <= 1.04)
    }
    @Test func retargetingKeepsVelocityAndTakesShortestAngle() {
        var motion = LayoutWheelMotion()
        let geometry = LayoutWheelMetrics.grouped.fanGeometry
        motion.retarget(selection: .init(ring: .outer, sector: .left), fan: .init(), geometry: geometry, reduceMotion: false)
        motion.advance(1 / 60)
        let id = LayoutWheelItemID.sector(.init(ring: .outer, sector: .left))
        let before = motion.highlights[id]?.velocity
        motion.retarget(selection: .init(ring: .outer, sector: .bottomLeft), fan: .init(), geometry: geometry, reduceMotion: false)
        #expect(motion.highlights[id]?.velocity == before)
        #expect(abs(motion.angle.target - motion.angle.value) <= .pi / 4 + 0.001)
        let intervals: [Double] = [0, -.infinity, .nan, -1, 1000, 1 / 120]
        for dt in intervals { motion.advance(dt) }
        #expect(motion.angle.value.isFinite)
        #expect(motion.strength.value.isFinite)
        for _ in 0..<240 { motion.advance(1 / 120) }
        #expect(motion.isAtRest)
    }
    @Test func springTrajectoryAgreesAt60And120Hz() {
        var at60 = LayoutWheelSpring(), at120 = LayoutWheelSpring()
        at60.target = 1; at120.target = 1
        for _ in 0..<30 {
            at60.advance(1 / 60)
            at120.advance(1 / 120); at120.advance(1 / 120)
            #expect(abs(at60.value - at120.value) < 0.000001)
        }
    }

}
