import Foundation
import Testing
@testable import BetterTileCore

private let plannerDisplay = DisplayID(rawValue: "planner")
private let plannerBounds = BTRect(x: 0, y: 0, width: 1200, height: 800)

private func plannerWindow(
    _ name: String,
    frame: BTRect = plannerBounds,
    minimized: Bool = false
) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(rawValue: name),
        processIdentifier: 1,
        frame: frame,
        displayID: plannerDisplay,
        isMinimized: minimized
    )
}

@Test func activationAdoptsAValidPartitionWithoutWritingFrames() {
    let left = plannerWindow("left", frame: BTRect(x: 0, y: 0, width: 600, height: 800))
    let right = plannerWindow("right", frame: BTRect(x: 600, y: 0, width: 600, height: 800))
    let result = BentoPlanner().plan(
        state: BentoRuntimeState(),
        observation: BentoObservation(bounds: plannerBounds, windows: [left, right], focusedWindowID: left.id),
        intent: .activate
    )

    #expect(!result.writesFrames)
    #expect(Set(result.state.layout.root?.windowIDs ?? []) == [left.id, right.id])
    #expect(result.placements.isEmpty)
}

@Test func activationAdoptsTouchingThirdsIntoAGappedBentoLayout() throws {
    let gaplessThirds = (0..<3).map { index in
        plannerWindow(
            "\(index)",
            frame: BTRect(x: Double(index) * 400, y: 0, width: 400, height: 800)
        )
    }
    let metrics = BentoLayoutMetrics(paneGap: 8)
    let result = BentoPlanner().plan(
        state: BentoRuntimeState(layout: BentoLayoutState(metrics: metrics)),
        observation: BentoObservation(
            bounds: plannerBounds,
            windows: gaplessThirds,
            focusedWindowID: gaplessThirds[0].id
        ),
        intent: .activate
    )

    guard case let .partition(root) = result.state.layout.root else {
        Issue.record("Expected the existing three-column topology to be preserved")
        return
    }
    #expect(root.axis == .vertical)
    #expect(root.children.flatMap(\.windowIDs) == gaplessThirds.map(\.id))
    #expect(root.ratios.allSatisfy { abs($0 - 1.0 / 3.0) < 0.000_001 })
    #expect(result.writesFrames)
    #expect(result.placements.count == 3)
    #expect(result.placements.allSatisfy {
        $0.frame.minX >= plannerBounds.minX
            && $0.frame.maxX <= plannerBounds.maxX
            && $0.frame.minY >= plannerBounds.minY
            && $0.frame.maxY <= plannerBounds.maxY
    })
}

@Test func retileUsesTheStoredThirdsAsTheClosestRecoveryLayout() throws {
    let windows = (0..<3).map { index in
        plannerWindow(
            "\(index)",
            frame: BTRect(
                x: Double(index) * 400 - (index == 0 ? 7 : 0),
                y: 0,
                width: 400 + (index == 2 ? 12 : 0),
                height: 800
            )
        )
    }
    let stored = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: windows.map { .leaf($0.id) },
        ratios: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]
    )))
    let result = BentoPlanner().plan(
        state: BentoRuntimeState(layout: stored),
        observation: BentoObservation(
            bounds: plannerBounds,
            windows: windows,
            focusedWindowID: windows[0].id
        ),
        intent: .retile
    )

    guard case let .partition(root) = result.state.layout.root else {
        Issue.record("Expected retile to keep the closest stored topology")
        return
    }
    #expect(root.axis == .vertical)
    #expect(root.children.flatMap(\.windowIDs) == windows.map(\.id))
    #expect(result.writesFrames)
    #expect(result.placements.count == 3)
    #expect(result.placements.allSatisfy {
        $0.frame.minX >= plannerBounds.minX
            && $0.frame.maxX <= plannerBounds.maxX
            && $0.frame.minY >= plannerBounds.minY
            && $0.frame.maxY <= plannerBounds.maxY
    })
}

@Test func retileRepairsExtremeThreeColumnRatiosToCanonicalThirds() throws {
    let widths = [480.0, 528.0, 192.0]
    var x = 0.0
    let windows = widths.enumerated().map { index, width in
        defer { x += width }
        return plannerWindow(
            "\(index)",
            frame: BTRect(x: x, y: 0, width: width, height: 800)
        )
    }
    let stored = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: windows.map { .leaf($0.id) },
        ratios: [0.4, 0.44, 0.16]
    )))
    let result = BentoPlanner().plan(
        state: BentoRuntimeState(layout: stored),
        observation: BentoObservation(
            bounds: plannerBounds,
            windows: windows,
            focusedWindowID: windows[0].id
        ),
        intent: .retile
    )

    guard case let .partition(root) = result.state.layout.root else {
        Issue.record("Expected the three-column recovery topology")
        return
    }
    #expect(root.ratios.allSatisfy { abs($0 - 1.0 / 3.0) < 0.000_001 })
    #expect(result.placements.map(\.frame.size.width).allSatisfy { abs($0 - 400) < 0.000_001 })
}

@Test func retileKeepsAFocusedRightWindowOnTheRight() throws {
    let left = plannerWindow(
        "left",
        frame: BTRect(x: 0, y: 80, width: 500, height: 720)
    )
    let right = plannerWindow(
        "right",
        frame: BTRect(x: 600, y: 0, width: 600, height: 800)
    )
    let result = BentoPlanner().plan(
        state: BentoRuntimeState(),
        observation: BentoObservation(
            bounds: plannerBounds,
            windows: [left, right],
            focusedWindowID: right.id
        ),
        intent: .retile
    )

    let rightPlacement = try #require(result.placements.first { $0.windowID == right.id })
    #expect(rightPlacement.frame.minX >= plannerBounds.midX)
}

@Test func retileKeepsAFocusedBottomWindowOnTheBottomOfAPortraitDisplay() throws {
    let bounds = BTRect(x: 0, y: 0, width: 800, height: 1200)
    let top = plannerWindow(
        "top",
        frame: BTRect(x: 80, y: 0, width: 720, height: 500)
    )
    let bottom = plannerWindow(
        "bottom",
        frame: BTRect(x: 0, y: 600, width: 800, height: 600)
    )
    let result = BentoPlanner().plan(
        state: BentoRuntimeState(),
        observation: BentoObservation(
            bounds: bounds,
            windows: [top, bottom],
            focusedWindowID: bottom.id
        ),
        intent: .retile
    )

    let bottomPlacement = try #require(result.placements.first { $0.windowID == bottom.id })
    #expect(bottomPlacement.frame.minY >= bounds.midY)
}

@Test func retileUsesFocusToBreakAnEqualMovementTie() throws {
    let wider = plannerWindow(
        "a",
        frame: BTRect(x: 0, y: 0, width: 600, height: 800)
    )
    let focused = plannerWindow(
        "b",
        frame: BTRect(x: 0, y: 0, width: 400, height: 800)
    )
    let result = BentoPlanner().plan(
        state: BentoRuntimeState(),
        observation: BentoObservation(
            bounds: plannerBounds,
            windows: [wider, focused],
            focusedWindowID: focused.id
        ),
        intent: .retile
    )

    let focusedPlacement = try #require(result.placements.first { $0.windowID == focused.id })
    #expect(focusedPlacement.frame.minX == plannerBounds.minX)
}

@Test func retilePreservesNearestAutomaticPanesThroughSixWindows() throws {
    for count in 2...6 {
        let windows = (0..<count).map { plannerWindow("\($0)") }
        let canonical = BentoPlanner().plan(
            state: BentoRuntimeState(),
            observation: BentoObservation(
                bounds: plannerBounds,
                windows: windows,
                focusedWindowID: windows[0].id
            ),
            intent: .activate
        ).placements
        let broken = canonical.map { placement in
            var frame = placement.frame
            if placement.windowID == windows[0].id {
                frame.origin.y += 24
                frame.size.height -= 24
            }
            return plannerWindow(placement.windowID.rawValue, frame: frame)
        }
        let repaired = BentoPlanner().plan(
            state: BentoRuntimeState(),
            observation: BentoObservation(
                bounds: plannerBounds,
                windows: broken,
                focusedWindowID: windows[count - 1].id
            ),
            intent: .retile
        ).placements

        #expect(
            Dictionary(uniqueKeysWithValues: repaired.map { ($0.windowID, $0.frame) })
                == Dictionary(uniqueKeysWithValues: canonical.map { ($0.windowID, $0.frame) }),
            "Expected the nearest canonical assignment for \(count) windows"
        )
    }
}

@Test func retileAllowsMirroredThreeAndFivePaneLayouts() throws {
    for count in [3, 5] {
        let windows = (0..<count).map { plannerWindow("\($0)") }
        let canonical = BentoPlanner().plan(
            state: BentoRuntimeState(),
            observation: BentoObservation(
                bounds: plannerBounds,
                windows: windows,
                focusedWindowID: windows[0].id
            ),
            intent: .activate
        ).placements
        let mirrored = canonical.map { placement in
            var frame = placement.frame
            frame.origin.x = plannerBounds.maxX - frame.maxX
            if placement.windowID == windows[1].id {
                frame.origin.y += 24
                frame.size.height -= 24
            }
            return plannerWindow(placement.windowID.rawValue, frame: frame)
        }
        let repaired = BentoPlanner().plan(
            state: BentoRuntimeState(),
            observation: BentoObservation(
                bounds: plannerBounds,
                windows: mirrored,
                focusedWindowID: windows[0].id
            ),
            intent: .retile
        ).placements
        let expected = Dictionary(uniqueKeysWithValues: canonical.map { placement in
            var frame = placement.frame
            frame.origin.x = plannerBounds.maxX - frame.maxX
            return (placement.windowID, frame)
        })

        #expect(repaired.allSatisfy { placement in
            expected[placement.windowID]?.approximatelyEquals(
                placement.frame,
                tolerance: 0.000_001
            ) == true
        }, "Expected the nearest mirrored assignment for \(count) windows")
    }
}

@Test func retilePrefersStoredTopologyWhenFramesHaveNoSpatialSignal() throws {
    let windows = (0..<3).map { plannerWindow("\($0)") }
    let stored = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: windows.map { .leaf($0.id) }
    )))
    let result = BentoPlanner().plan(
        state: BentoRuntimeState(layout: stored),
        observation: BentoObservation(
            bounds: plannerBounds,
            windows: windows,
            focusedWindowID: windows[2].id
        ),
        intent: .retile
    )

    guard case let .partition(root) = result.state.layout.root else {
        Issue.record("Expected the stored three-column topology")
        return
    }
    #expect(result.state.layout == stored)
    #expect(root.axis == .vertical)
    #expect(root.children.count == 3)
    #expect(root.children.flatMap(\.windowIDs) == windows.map(\.id))
}

@Test func activationFallsBackToThePracticalGrid() {
    let windows = (1...4).map { plannerWindow("\($0)") }
    let result = BentoPlanner().plan(
        state: BentoRuntimeState(),
        observation: BentoObservation(
            bounds: plannerBounds,
            windows: windows,
            focusedWindowID: windows[0].id
        ),
        intent: .activate
    )

    #expect(result.writesFrames)
    #expect(Set(result.placements.map(\.frame.size)) == [BTSize(width: 600, height: 400)])
}

@Test func focusedInsertionUsesPracticalThreePaneLayout() throws {
    let a = plannerWindow("a")
    let b = plannerWindow("b")
    let c = plannerWindow("c")
    let first = BentoPlanner().plan(
        state: BentoRuntimeState(layout: BentoLayoutState(root: .leaf(a.id))),
        observation: BentoObservation(bounds: plannerBounds, windows: [a, b], focusedWindowID: a.id),
        intent: .insert(b.id)
    )
    let second = BentoPlanner().plan(
        state: first.state,
        observation: BentoObservation(bounds: plannerBounds, windows: [a, b, c], focusedWindowID: a.id),
        intent: .insert(c.id)
    )

    let root = try #require(second.state.layout.root)
    guard case let .partition(rootPartition) = root else {
        Issue.record("Expected normalized root partition")
        return
    }
    #expect(rootPartition.axis == .vertical)
    #expect(rootPartition.ratios == [0.5, 0.5])
    #expect(rootPartition.children.first == .leaf(a.id))
    let nested = try #require(rootPartition.children.last)
    guard case let .partition(nestedPartition) = nested else {
        Issue.record("Expected the other two windows to share a stack")
        return
    }
    #expect(nestedPartition.axis == .horizontal)
    #expect(nestedPartition.children.flatMap(\.windowIDs) == [b.id, c.id])
    #expect(nestedPartition.ratios == [0.5, 0.5])
}

@Test func automaticInsertionUsesBalancedLayoutsThroughSixWindows() throws {
    let windows = (1...6).map { plannerWindow("\($0)") }
    let planner = BentoPlanner()
    var state = BentoRuntimeState(layout: BentoLayoutState(root: .leaf(windows[0].id)))

    for count in 2...6 {
        state = planner.plan(
            state: state,
            observation: BentoObservation(
                bounds: plannerBounds,
                windows: Array(windows.prefix(count)),
                focusedWindowID: windows[0].id
            ),
            intent: .insert(windows[count - 1].id)
        ).state

        let frames = Dictionary(
            uniqueKeysWithValues: state.layout.placements(in: plannerBounds)
                .map { ($0.windowID, $0.frame) }
        )
        if count == 4 {
            #expect(Set(frames.values.map(\.size)) == [BTSize(width: 600, height: 400)])
        } else if count == 5 {
            #expect(frames[windows[0].id] == BTRect(x: 0, y: 0, width: 400, height: 800))
            #expect(windows.prefix(count).dropFirst().allSatisfy {
                guard let size = frames[$0.id]?.size else { return false }
                return abs(size.width - 400) < 0.001 && abs(size.height - 400) < 0.001
            })
        } else if count == 6 {
            #expect(Set(frames.values.map(\.size)) == [BTSize(width: 400, height: 400)])
        }
    }
}

@Test func practicalLayoutUsesHorizontalTracksOnAPortraitDisplay() throws {
    let portraitBounds = BTRect(x: 0, y: 0, width: 800, height: 1200)
    let a = plannerWindow("a", frame: portraitBounds)
    let b = plannerWindow("b", frame: portraitBounds)
    let c = plannerWindow("c", frame: portraitBounds)
    let first = BentoPlanner().plan(
        state: BentoRuntimeState(layout: BentoLayoutState(root: .leaf(a.id))),
        observation: BentoObservation(
            bounds: portraitBounds,
            windows: [a, b],
            focusedWindowID: a.id
        ),
        intent: .insert(b.id)
    )
    let result = BentoPlanner().plan(
        state: first.state,
        observation: BentoObservation(
            bounds: portraitBounds,
            windows: [a, b, c],
            focusedWindowID: a.id
        ),
        intent: .insert(c.id)
    )

    let frames = Dictionary(
        uniqueKeysWithValues: result.state.layout.placements(in: portraitBounds)
            .map { ($0.windowID, $0.frame) }
    )
    #expect(frames[a.id] == BTRect(x: 0, y: 0, width: 800, height: 600))
    #expect(frames[b.id] == BTRect(x: 0, y: 600, width: 400, height: 600))
    #expect(frames[c.id] == BTRect(x: 400, y: 600, width: 400, height: 600))
}

/// Beyond six panes a window stays visible and floating. It is not minimized,
/// it does not take the display from the panes, and the six-pane tree is
/// untouched - a window the user can still see and use beats one hidden to
/// protect a layout.
@Test func aSeventhWindowFloatsVisiblyWithoutDisturbingTheSixPanes() throws {
    let windows = (1...8).map { plannerWindow("\($0)") }
    var layout = BentoLayoutState(root: .leaf(windows[0].id))
    for window in windows[1..<6] {
        layout.split(windows[0].id, inserting: window.id, in: plannerBounds)
    }
    let originalRoot = layout.root
    let observation = BentoObservation(bounds: plannerBounds, windows: windows, focusedWindowID: windows[0].id)

    let seventh = BentoPlanner().plan(
        state: BentoRuntimeState(layout: layout),
        observation: observation,
        intent: .insert(windows[6].id)
    )
    let eighth = BentoPlanner().plan(
        state: seventh.state,
        observation: observation,
        intent: .insert(windows[7].id)
    )

    #expect(eighth.state.layout.root == originalRoot, "the six panes keep their arrangement")
    #expect(eighth.minimizeWindowIDs.isEmpty, "nothing is hidden to make room")
    #expect(eighth.state.layout.floatingWindowIDs.isSuperset(of: [windows[6].id, windows[7].id]))
    #expect(eighth.placements.isEmpty, "an overflow window keeps its own frame")
}

@Test func theOverflowMessageNamesTheCapAndTheOutcome() {
    #expect(bentoOverflowMessage == "Bento manages up to six panes. This window will remain floating.")
}

/// Activating a desktop that already holds more than six windows floats the
/// extras rather than hiding them.
@Test func activatingWithMoreThanSixWindowsFloatsTheExtras() throws {
    let windows = (1...8).map { plannerWindow("\($0)") }
    let observation = BentoObservation(bounds: plannerBounds, windows: windows, focusedWindowID: windows[0].id)
    let result = BentoPlanner().plan(
        state: BentoRuntimeState(layout: BentoLayoutState()),
        observation: observation,
        intent: .activate
    )
    #expect(result.minimizeWindowIDs.isEmpty)
    #expect(result.state.layout.floatingWindowIDs.count == 2)
    #expect((result.state.layout.root?.windowIDs.count ?? 0) == 6)
}

@Test func minimizingAndRestoringUsesALocalReinsertionAnchor() {
    let a = plannerWindow("a")
    let b = plannerWindow("b")
    let c = plannerWindow("c")
    var layout = BentoLayoutState(root: .leaf(a.id))
    layout.split(a.id, inserting: b.id, in: plannerBounds)
    layout.split(a.id, inserting: c.id, in: plannerBounds)
    let all = [a, b, c]
    let removed = BentoPlanner().plan(
        state: BentoRuntimeState(layout: layout),
        observation: BentoObservation(bounds: plannerBounds, windows: all, focusedWindowID: a.id),
        intent: .remove(a.id, minimized: true)
    )
    #expect(removed.state.reinsertionAnchors[a.id] != nil)
    #expect(removed.state.layout.root?.windowIDs.contains(a.id) == false)

    let restored = BentoPlanner().plan(
        state: removed.state,
        observation: BentoObservation(bounds: plannerBounds, windows: all, focusedWindowID: b.id),
        intent: .restore(a.id)
    )
    #expect(restored.state.layout.root?.windowIDs.contains(a.id) == true)
    #expect(restored.state.reinsertionAnchors[a.id] == nil)
}

@Test func crossDisplayEdgeTransferRemovesAndInsertsAsOnePlan() throws {
    let source = plannerWindow("source")
    let sourcePeer = plannerWindow("source-peer")
    let destinationPeer = plannerWindow("destination-peer")
    var sourceLayout = BentoLayoutState(root: .leaf(source.id))
    sourceLayout.split(source.id, inserting: sourcePeer.id, in: plannerBounds)
    let destinationBounds = BTRect(x: 1200, y: 0, width: 1200, height: 800)
    let destinationWindow = WindowSnapshot(
        id: destinationPeer.id,
        processIdentifier: 2,
        frame: destinationBounds,
        displayID: DisplayID(rawValue: "destination")
    )

    let result = try #require(BentoPlanner().transfer(
        sourceWindowID: source.id,
        targetWindowID: destinationPeer.id,
        position: .left,
        sourceState: BentoRuntimeState(layout: sourceLayout),
        destinationState: BentoRuntimeState(
            layout: BentoLayoutState(root: .leaf(destinationPeer.id))
        ),
        sourceObservation: BentoObservation(
            bounds: plannerBounds,
            windows: [source, sourcePeer]
        ),
        destinationObservation: BentoObservation(
            bounds: destinationBounds,
            windows: [destinationWindow]
        )
    ))

    #expect(result.sourceState.layout.root?.windowIDs == [sourcePeer.id])
    #expect(result.destinationState.layout.root?.windowIDs == [source.id, destinationPeer.id])
    #expect(Set(result.placements.map(\.windowID)) == [source.id, sourcePeer.id, destinationPeer.id])
}

// MARK: - Floating pane exchange

/// An overflow window has to be usable, not merely visible: it can take a
/// pane's slot, and the pane's previous occupant floats in its place. The
/// layout keeps its shape and its pane count.
@Test func aFloatingWindowCanTakeAPaneAndDisplaceItsOccupant() throws {
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    let floater = WindowID(rawValue: "floater")
    var layout = BentoLayoutState(root: .leaf(a))
    layout.split(a, inserting: b, in: plannerBounds)
    layout.setFloating(true, windowID: floater)
    let shape = layout.placements(in: plannerBounds).map(\.frame).sorted { $0.minX < $1.minX }

    let exchanged = layout.exchangeFloating(floater, withPaneOf: b)
    #expect(exchanged)
    #expect(layout.root?.windowIDs.contains(floater) == true)
    #expect(layout.root?.windowIDs.contains(b) != true)
    #expect(layout.floatingWindowIDs.contains(b), "the displaced pane floats")
    #expect(!layout.floatingWindowIDs.contains(floater))
    #expect(layout.root?.windowIDs.count == 2, "the pane count is unchanged")
    #expect(layout.placements(in: plannerBounds).map(\.frame).sorted { $0.minX < $1.minX } == shape,
            "the layout keeps its shape")
}

@Test func exchangeRefusesWindowsThatAreNotFloatingOrNotPanes() {
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    let floater = WindowID(rawValue: "floater")
    let stranger = WindowID(rawValue: "stranger")
    var layout = BentoLayoutState(root: .leaf(a))
    layout.split(a, inserting: b, in: plannerBounds)
    layout.setFloating(true, windowID: floater)

    let paneIsNotFloating = layout.exchangeFloating(a, withPaneOf: b)
    #expect(!paneIsNotFloating, "a pane is not a floating window")
    let targetIsNotAPane = layout.exchangeFloating(floater, withPaneOf: stranger)
    #expect(!targetIsNotAPane, "the target must be a pane")
    let selfExchange = layout.exchangeFloating(floater, withPaneOf: floater)
    #expect(!selfExchange)
}
