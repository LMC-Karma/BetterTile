import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test func dockFootprintRequiresStableAppearanceAndDelayedDisappearance() {
    let displayID = DisplayID(rawValue: "main")
    let footprint = DockFootprint(edge: .bottom, thickness: 80)
    var stabilizer = DockFootprintStabilizer()
    stabilizer.sample([displayID: footprint], timestamp: 1)
    #expect(stabilizer.visible[displayID] == nil)
    stabilizer.sample([displayID: footprint], timestamp: 1.09)
    #expect(stabilizer.visible[displayID] == nil)
    stabilizer.sample([displayID: footprint], timestamp: 1.1)
    #expect(stabilizer.visible[displayID] == footprint)

    stabilizer.sample([:], timestamp: 2)
    stabilizer.sample([:], timestamp: 2.49)
    #expect(stabilizer.visible[displayID] == footprint)
    stabilizer.sample([:], timestamp: 2.5)
    #expect(stabilizer.visible[displayID] == nil)
}

@Test func dockSamplingLeaseCoalescesTriggersAndStopsAfterStableSamples() {
    var lease = DockSamplingLease()
    lease.trigger(at: 1)
    #expect(lease.isActive)

    lease.recordSample(changed: false, at: 1.2)
    lease.recordSample(changed: false, at: 1.4)
    lease.recordSample(changed: false, at: 1.6)
    #expect(lease.isActive)

    lease.recordSample(changed: false, at: 1.7)
    #expect(!lease.isActive)

    lease.trigger(at: 2)
    lease.recordSample(changed: true, at: 2.2)
    lease.recordSample(changed: false, at: 2.4)
    lease.recordSample(changed: false, at: 2.6)
    #expect(lease.isActive)
    lease.recordSample(changed: false, at: 2.9)
    #expect(!lease.isActive)
}

@Test func dockSamplingLeaseHasABoundedMaximumDuration() {
    var lease = DockSamplingLease()
    lease.trigger(at: 10)
    for step in 1...20 {
        lease.trigger(at: 10 + Double(step) / 10)
        lease.recordSample(changed: true, at: 10 + Double(step) / 10)
    }
    #expect(!lease.isActive)
}

@Test func visibleDockFootprintsReserveBottomAndSideWorkAreas() {
    let displayID = DisplayID(rawValue: "main")
    let full = BTRect(x: 0, y: 0, width: 1200, height: 800)
    let appKitVisible = BTRect(x: 0, y: 24, width: 1200, height: 776)
    var stabilizer = DockFootprintStabilizer()
    stabilizer.sample([displayID: DockFootprint(edge: .bottom, thickness: 80)], timestamp: 1)
    stabilizer.sample([displayID: DockFootprint(edge: .bottom, thickness: 80)], timestamp: 1.1)
    #expect(stabilizer.effectiveFrame(
        displayID: displayID, fullFrame: full, appKitVisibleFrame: appKitVisible
    ) == BTRect(x: 0, y: 24, width: 1200, height: 696))

    stabilizer.sample([:], timestamp: 2)
    stabilizer.sample([:], timestamp: 2.5)
    #expect(stabilizer.effectiveFrame(
        displayID: displayID, fullFrame: full, appKitVisibleFrame: appKitVisible
    ) == appKitVisible)

    var left = DockFootprintStabilizer()
    left.sample([displayID: DockFootprint(edge: .left, thickness: 80)], timestamp: 1)
    left.sample([displayID: DockFootprint(edge: .left, thickness: 80)], timestamp: 1.1)
    #expect(left.effectiveFrame(
        displayID: displayID, fullFrame: full, appKitVisibleFrame: appKitVisible
    ) == BTRect(x: 80, y: 24, width: 1120, height: 776))

    var right = DockFootprintStabilizer()
    right.sample([displayID: DockFootprint(edge: .right, thickness: 80)], timestamp: 1)
    right.sample([displayID: DockFootprint(edge: .right, thickness: 80)], timestamp: 1.1)
    #expect(right.effectiveFrame(
        displayID: displayID, fullFrame: full, appKitVisibleFrame: appKitVisible
    ) == BTRect(x: 0, y: 24, width: 1120, height: 776))
}
