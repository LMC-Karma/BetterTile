import AppKit
import Testing
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct DisplayRefreshSampleTests {
    @Test func aBurstDeliversOnlyItsLatestPointAtTheNextRefresh() {
        let ticks = ResizeDisplayLink(automatic: false)
        var points: [CGPoint] = []
        let sample = DisplayRefreshSample(ticks: ticks) { points.append($0) }
        for x in 0..<1000 { sample.submit(CGPoint(x: x, y: 10)) }
        #expect(points.isEmpty)
        #expect(sample.isPending)
        ticks.fire()
        #expect(points == [CGPoint(x: 999, y: 10)])
        #expect(!sample.isPending)
        for _ in 0..<100 { ticks.fire() }
        #expect(points.count == 1)
    }

    @Test func aPressFlushesThePendingPointBeforeReadingHover() {
        let ticks = ResizeDisplayLink(automatic: false)
        var hover = CGPoint.zero
        var passes = 0
        let sample = DisplayRefreshSample(ticks: ticks) { hover = $0; passes += 1 }
        sample.submit(CGPoint(x: 12, y: 9))
        sample.submit(CGPoint(x: 40, y: 9))
        sample.flush()
        #expect(hover == CGPoint(x: 40, y: 9))
        #expect(passes == 1)
        ticks.fire()
        #expect(passes == 1)
    }

    @Test func cancellationPreventsAStalePassAndAStationaryPointerDoesNoWork() {
        let ticks = ResizeDisplayLink(automatic: false)
        var passes = 0
        let sample = DisplayRefreshSample<Int>(ticks: ticks) { _ in passes += 1 }
        for _ in 0..<10 { ticks.fire() }
        #expect(passes == 0)
        sample.submit(1)
        sample.cancel()
        ticks.fire()
        #expect(passes == 0)
        sample.submit(2)
        ticks.fire()
        #expect(passes == 1)
    }

    @Test func aSampleQueuedByTheConsumerWaitsForTheFollowingRefresh() {
        let ticks = ResizeDisplayLink(automatic: false)
        var values: [Int] = []
        var sample: DisplayRefreshSample<Int>!
        sample = DisplayRefreshSample(ticks: ticks) { value in
            values.append(value)
            if value == 1 { sample.submit(2) }
        }
        sample.submit(1)
        ticks.fire()
        #expect(values == [1])
        #expect(sample.isPending)
        ticks.fire()
        #expect(values == [1, 2])
        #expect(!sample.isPending)
        sample = nil
    }

    @Test func aPendingDisplayCallbackDoesNotRetainTheSampler() {
        let ticks = ResizeDisplayLink(automatic: false)
        var passes = 0
        weak var weakSample: DisplayRefreshSample<Int>?
        do {
            let sample = DisplayRefreshSample<Int>(ticks: ticks) { _ in passes += 1 }
            weakSample = sample
            sample.submit(1)
        }
        #expect(weakSample == nil)
        ticks.fire()
        #expect(passes == 0)
    }

}
