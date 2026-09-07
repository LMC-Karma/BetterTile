import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test func dividerHandleIsSuppressedWhenAFloatingWindowCoversIt() {
    let handle = BTRect(x: 490, y: 300, width: 20, height: 56)
    let settings = BTRect(x: 300, y: 180, width: 700, height: 520)
    let besideHandle = BTRect(x: 520, y: 300, width: 200, height: 200)

    #expect(DividerHandleOcclusion.isCovered(handle, by: [settings]))
    #expect(!DividerHandleOcclusion.isCovered(handle, by: [besideHandle]))

    let displayID = DisplayID(rawValue: "main")
    let managed = WindowSnapshot(
        id: WindowID(rawValue: "managed"),
        processIdentifier: 1,
        frame: BTRect(x: 0, y: 0, width: 500, height: 800),
        displayID: displayID
    )
    let floating = WindowSnapshot(
        id: WindowID(rawValue: "floating"),
        processIdentifier: 2,
        frame: settings,
        displayID: displayID
    )
    #expect(DividerHandleOcclusion.obscuringFrames(
        in: [managed, floating],
        excluding: [managed.id]
    ) == [settings])
}

@Test func dividerGripUsesThreefoldStraightGrowthAndShortSpanCap() {
    #expect(DividerHandleGeometry.straightLength(span: 0...200, active: false) == 56)
    #expect(DividerHandleGeometry.straightLength(span: 0...200, active: true) == 168)
    #expect(DividerHandleGeometry.straightLength(span: 0...90, active: true) == 90)
}

@Test(arguments: [2.0, 6.0, 12.0])
func junctionGripKeepsACompactTargetAndCapsEachExistingArm(thickness: Double) {
    let center = BTPoint(x: 100, y: 100)
    let boundaries = [
        boundary("vertical", axis: .vertical, coordinate: 100, start: 80, end: 150),
        boundary("horizontal", axis: .horizontal, coordinate: 100, start: 80, end: 100),
    ]
    let restingArms = DividerHandleGeometry.junctionArmLengths(
        center: center,
        boundaries: boundaries,
        active: false,
        thickness: thickness
    )
    let activeArms = DividerHandleGeometry.junctionArmLengths(
        center: center,
        boundaries: boundaries,
        active: true,
        thickness: thickness
    )
    let resting = DividerHandleGeometry.junctionFrame(
        center: center,
        armLengths: restingArms,
        thickness: thickness
    )
    let active = DividerHandleGeometry.junctionFrame(
        center: center,
        armLengths: activeArms,
        thickness: thickness
    )

    let acquisition = DividerHandleGeometry.junctionAcquisitionFrame(center: center)
    #expect(resting.minX <= acquisition.minX)
    #expect(resting.minY <= acquisition.minY)
    #expect(resting.maxX >= acquisition.maxX)
    #expect(resting.maxY >= acquisition.maxY)
    #expect(Set(activeArms.keys) == [.up, .down, .left])
    #expect(activeArms[.right] == nil)
    #expect(activeArms[.down] == 36)
    #expect(activeArms[.up] == 20 - max(1, thickness / 2))
    #expect(activeArms[.left] == 20 - max(1, thickness / 2))
    #expect(active.minX >= 80)
    #expect(active.maxX <= 100 + max(16, thickness / 2))
    #expect(active.minY >= 80)
    #expect(active.maxY <= 150)
}

@Test func junctionAcquisitionIncludesSquareCornersAndAnEmptyTQuadrant() throws {
    let verticalID = UUID()
    let horizontalID = UUID()
    let boundaries = [
        boundary(
            "vertical", axis: .vertical, coordinate: 100, start: 40, end: 160,
            branchID: verticalID
        ),
        boundary(
            "left-arm", axis: .horizontal, coordinate: 100, start: 40, end: 100,
            branchID: horizontalID
        ),
    ]

    let interaction = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 116, y: 84),
        in: boundaries,
        hitWidth: 18,
        adjacencyTolerance: 6
    ))
    guard case .junction = interaction.kind else {
        Issue.record("The complete 32-point target must select the T junction.")
        return
    }
    let arms = DividerHandleGeometry.junctionArmLengths(
        center: BTPoint(x: 100, y: 100),
        boundaries: interaction.boundaries,
        active: false,
        thickness: 6
    )
    #expect(Set(arms.keys) == [.up, .down, .left])
}

@Test func junctionWinsInsideItsTargetAndStraightBoundaryWinsOutside() throws {
    let boundaries = [
        boundary("vertical", axis: .vertical, coordinate: 100, start: 40, end: 160),
        boundary("horizontal", axis: .horizontal, coordinate: 100, start: 40, end: 160),
    ]
    let junction = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 115, y: 115), in: boundaries, hitWidth: 18, adjacencyTolerance: 6
    ))
    let straight = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 100, y: 130), in: boundaries, hitWidth: 18, adjacencyTolerance: 6
    ))
    guard case .junction = junction.kind else {
        Issue.record("An eligible junction has priority inside its target.")
        return
    }
    #expect(straight.kind == .vertical)
}

@Test func fourWayJunctionRetainsEveryMeetingBentoBranch() throws {
    let boundaries = [
        boundary("v-top", axis: .vertical, coordinate: 100, start: 0, end: 100),
        boundary("v-bottom", axis: .vertical, coordinate: 100, start: 100, end: 200),
        boundary("h-left", axis: .horizontal, coordinate: 100, start: 0, end: 100),
        boundary("h-right", axis: .horizontal, coordinate: 100, start: 100, end: 200),
    ]
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 100, y: 100), in: boundaries, hitWidth: 18, adjacencyTolerance: 6
    ))
    #expect(interaction.boundaries.map(\.id).sorted() == boundaries.map(\.id).sorted())
    let arms = DividerHandleGeometry.junctionArmLengths(
        center: BTPoint(x: 100, y: 100),
        boundaries: interaction.boundaries,
        active: false,
        thickness: 6
    )
    #expect(Set(arms.keys) == Set(DividerHandleArm.allCases))
}

@Test func lockedOtherDisplayAndNearbyNonintersectionsCannotCreateAJunction() throws {
    let vertical = boundary("vertical", axis: .vertical, coordinate: 100, start: 40, end: 160)
    let locked = boundary(
        "locked", axis: .horizontal, coordinate: 100, start: 40, end: 160, isLocked: true
    )
    let otherDisplay = boundary(
        "other-display", display: "other", axis: .horizontal,
        coordinate: 100, start: 40, end: 160
    )
    let nearby = boundary(
        "nearby", axis: .horizontal, coordinate: 100, start: 40, end: 90
    )
    for candidate in [locked, otherDisplay, nearby] {
        let interaction = try #require(DividerInteractionResolver.resolve(
            at: BTPoint(x: 100, y: 100),
            in: [vertical, candidate],
            hitWidth: 18,
            adjacencyTolerance: 6
        ))
        guard case .junction = interaction.kind else { continue }
        Issue.record("An ineligible or cross-display boundary created a junction.")
    }
}

@Test func overlappingJunctionTargetsUseDistanceThenAStableCenterTieBreak() throws {
    let boundaries = [
        boundary("v100", axis: .vertical, coordinate: 100, start: 40, end: 160),
        boundary("h100", axis: .horizontal, coordinate: 100, start: 40, end: 160),
        boundary("v108", axis: .vertical, coordinate: 108, start: 40, end: 160),
        boundary("h108", axis: .horizontal, coordinate: 100, start: 101, end: 170),
    ]
    let nearest = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 107, y: 100), in: boundaries, hitWidth: 18, adjacencyTolerance: 2
    ))
    let tied = try #require(DividerInteractionResolver.resolve(
        at: BTPoint(x: 104, y: 100), in: boundaries, hitWidth: 18, adjacencyTolerance: 2
    ))
    #expect(nearest.boundaries.contains { $0.id == "v108" })
    #expect(tied.boundaries.contains { $0.id == "v100" })
}

@Test @MainActor func ghostPanelsRemainBelowTheActiveHandle() throws {
    _ = NSApplication.shared
    let handle = NSPanel(
        contentRect: CGRect(x: 100, y: 100, width: 20, height: 60),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    handle.level = .floating
    handle.orderFrontRegardless()
    defer { handle.orderOut(nil) }

    let display = DisplayID(rawValue: "main")
    let snapshot = WindowSnapshot(
        id: WindowID(rawValue: "window"), processIdentifier: 1,
        frame: BTRect(x: 0, y: 0, width: 300, height: 200), displayID: display
    )
    let ghosts = GhostFrameOverlayController()
    ghosts.show(
        placements: [Placement(windowID: snapshot.id, frame: snapshot.frame)],
        windows: [snapshot],
        below: handle
    )
    defer { ghosts.hide() }

    #expect(!ghosts.windowNumbers.isEmpty)
    #expect(ghosts.relativeOrderTargets[snapshot.id] == handle.windowNumber)
}

private func boundary(
    _ id: String,
    display: String = "main",
    axis: SplitAxis,
    coordinate: Double,
    start: Double,
    end: Double,
    isLocked: Bool = false,
    branchID: UUID? = UUID()
) -> BoundaryDescriptor {
    BoundaryDescriptor(
        id: id,
        displayID: DisplayID(rawValue: display),
        axis: axis,
        coordinate: coordinate,
        spanStart: start,
        spanEnd: end,
        beforeWindowIDs: [WindowID(rawValue: "\(id)-before")],
        afterWindowIDs: [WindowID(rawValue: "\(id)-after")],
        isLocked: isLocked,
        branchID: branchID
    )
}
