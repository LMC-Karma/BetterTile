import Foundation
import Testing
@testable import BetterTileCore

@Suite struct SavedLayoutCanvasTests {
    private func ids(_ counter: Counter = Counter()) -> (String) -> String { { counter.next($0) } }
    private final class Counter {
        var value = 0
        func next(_ prefix: String) -> String { value += 1; return "\(prefix)-\(value)" }
    }

    private func document(_ layout: SavedLayoutNode, slots: [String] = [], mode: LayoutMode = .bento, gap: Double = 0) -> SavedLayoutDocument {
        .init(name: "Test", mode: mode, layout: layout,
              slots: slots.map { .init(id: $0, bundleID: "com.example.\($0)") }, paneGap: gap)
    }
    private func columns(_ ratios: [Double], _ children: [SavedLayoutNode]) -> SavedLayoutNode {
        .split(axis: .vertical, ratios: ratios, children: children)
    }
    private func rows(_ ratios: [Double], _ children: [SavedLayoutNode]) -> SavedLayoutNode {
        .split(axis: .horizontal, ratios: ratios, children: children)
    }
    private func equalColumns(_ children: [SavedLayoutNode]) -> SavedLayoutNode {
        columns(Array(repeating: 1 / Double(children.count), count: children.count), children)
    }
    private func edit(_ outcome: SavedLayoutOutcome) -> SavedLayoutEdit? { if case let .change(edit) = outcome { edit } else { nil } }
    private func rejection(_ outcome: SavedLayoutOutcome) -> String? { if case let .rejected(text) = outcome { text } else { nil } }
    private func ratios(_ node: SavedLayoutNode?) -> [Double] {
        if case let .split(_, ratios, _)? = node { ratios } else { [] }
    }
    private func expectClose(_ values: [Double], _ expected: [Double], tolerance: Double = 1e-9) {
        #expect(values.count == expected.count)
        for (value, target) in zip(values, expected) { #expect(abs(value - target) <= tolerance, "\(values) vs \(expected)") }
    }
    /// Every document that an edit produces must pass the file validator.
    private func valid(_ edit: SavedLayoutEdit?) -> Bool { edit.map { SavedLayoutValidator.validate($0.document).isEmpty } ?? false }

    // MARK: Dividers

    /// An imported file can hold a pane far below the editor's minimum. Its divider cannot move,
    /// and rounding must not turn the tiny share into 0.
    @Test func aDividerWithNoRoomLeavesATinyImportedShareUnchanged() throws {
        let root = columns([0.9, 0.09999, 0.00001], [.empty, .empty, .empty])
        #expect(SavedLayoutValidator.validate(document(root)).isEmpty)
        #expect(try SavedLayoutCanvas.equalizingDivider(in: root, path: [], index: 1) == root)
        #expect(try SavedLayoutCanvas.movingDivider(in: root, path: [], index: 1, to: 0.95) == root)
    }

    @Test func movingADividerChangesOnlyItsTwoNeighborsAndKeepsTheSum() throws {
        let root = columns([0.2, 0.3, 0.5], [.empty, .empty, .empty])
        let moved = try SavedLayoutCanvas.movingDivider(in: root, path: [], index: 0, to: 0.3)
        expectClose(ratios(moved), [0.3, 0.2, 0.5])
        let second = try SavedLayoutCanvas.movingDivider(in: root, path: [], index: 1, to: 0.6)
        expectClose(ratios(second), [0.2, 0.4, 0.4])
        for value in [moved, second] { #expect(abs(ratios(value).reduce(0, +) - 1) < 1e-9) }
    }

    @Test func aDividerStopsAtTheMinimumPaneSizeOnBothSides() throws {
        let root = columns([0.5, 0.5], [.empty, .empty])
        expectClose(ratios(try SavedLayoutCanvas.movingDivider(in: root, path: [], index: 0, to: 0.01)), [0.1, 0.9])
        expectClose(ratios(try SavedLayoutCanvas.movingDivider(in: root, path: [], index: 0, to: 0.99)), [0.9, 0.1])
        let flat = rows([0.5, 0.5], [.empty, .empty])
        expectClose(ratios(try SavedLayoutCanvas.movingDivider(in: flat, path: [], index: 0, to: 0.0)), [0.12, 0.88])
    }

    @Test func nestedSplitsRaiseTheMinimumOfTheirSide() throws {
        // The left side holds two columns inside a row, so it needs at least two panes' width.
        let left = rows([0.5, 0.5], [columns([0.5, 0.5], [.empty, .empty]), .empty])
        let root = columns([0.5, 0.5], [left, .empty])
        let divider = try #require(SavedLayoutCanvas.dividers(root).first { $0.path.isEmpty })
        #expect(abs(divider.lower - 0.2) < 1e-9)
        #expect(abs(divider.upper - 0.9) < 1e-9)
        let clamped = try SavedLayoutCanvas.movingDivider(in: root, path: [], index: 0, to: 0.05)
        expectClose(ratios(clamped), [0.2, 0.8])
        // The inner divider is bounded by its own span, not the whole canvas.
        let inner = try #require(SavedLayoutCanvas.dividers(root).first { $0.path == [0, 0] })
        #expect(abs(inner.lower - 0.2) < 1e-9)
    }

    @Test func aDividerThatCannotMoveHasNoRange() {
        let tight = columns([0.1, 0.1, 0.8], [.empty, .empty, .empty])
        let divider = SavedLayoutCanvas.dividers(tight).first
        #expect(divider?.canMove == false)
        let roomy = SavedLayoutCanvas.dividers(columns([0.5, 0.5], [.empty, .empty])).first
        #expect(roomy?.canMove == true)
    }

    @Test func staleDividerAddressesAreRejected() {
        let root = columns([0.5, 0.5], [.empty, .empty])
        #expect(throws: SavedLayoutCanvasError.self) { try SavedLayoutCanvas.movingDivider(in: root, path: [3], index: 0, to: 0.4) }
        #expect(throws: SavedLayoutCanvasError.self) { try SavedLayoutCanvas.movingDivider(in: root, path: [], index: 4, to: 0.4) }
    }

    @Test func equalizingSplitsTheTwoNeighborsEvenly() throws {
        let root = columns([0.2, 0.5, 0.3], [.empty, .empty, .empty])
        expectClose(ratios(try SavedLayoutCanvas.equalizingDivider(in: root, path: [], index: 1)), [0.2, 0.4, 0.4])
    }

    @Test func dividerPositionsIncludeThePaneGap() throws {
        let root = columns([0.5, 0.5], [.empty, .empty])
        let divider = try #require(SavedLayoutCanvas.dividers(root, paneGap: 12).first)
        // 12 pt of 1200 is 1%. The divider sits in the middle of the gap.
        #expect(abs(divider.position - 0.5) < 1e-9)
        #expect(abs(divider.travel - 0.99) < 1e-9)
        let panes = SavedLayoutCanvas.leaves(root, paneGap: 12)
        #expect(abs(panes[0].rect.width - 0.495) < 1e-9)
        #expect(abs(panes[1].rect.x - 0.505) < 1e-9)
    }

    // MARK: Snap

    @Test func snapPicksTheNearestPointWithinEightPoints() throws {
        let divider = try #require(SavedLayoutCanvas.dividers(columns([0.5, 0.5], [.empty, .empty])).first)
        // 600 points of travel: 0.34 is 4 points from ⅓.
        #expect(SavedLayoutCanvas.snap(0.34, for: divider, travelPoints: 600)?.label == "⅓")
        #expect(SavedLayoutCanvas.snap(0.51, for: divider, travelPoints: 600)?.label == "½")
        #expect(SavedLayoutCanvas.snap(0.4, for: divider, travelPoints: 600) == nil)
        // Short travel: the same distance in shares is fewer points, so more snaps.
        #expect(SavedLayoutCanvas.snap(0.4, for: divider, travelPoints: 100)?.label == "⅓")
    }

    @Test func optionTurnsSnappingOff() throws {
        let divider = try #require(SavedLayoutCanvas.dividers(columns([0.5, 0.5], [.empty, .empty])).first)
        #expect(SavedLayoutCanvas.snap(0.5, for: divider, travelPoints: 600, enabled: false) == nil)
        #expect(SavedLayoutCanvas.snap(0.5, for: divider, travelPoints: 600, enabled: true)?.fraction == 0.5)
    }

    @Test func snapPointsOutsideTheDividerRangeAreSkipped() throws {
        // The left side holds three columns, so the divider cannot go below 30% and cannot snap to ¼.
        let left = rows([0.5, 0.5], [equalColumns([.empty, .empty, .empty]), .empty])
        let divider = try #require(SavedLayoutCanvas.dividers(columns([0.5, 0.5], [left, .empty])).first { $0.path.isEmpty })
        #expect(abs(divider.lower - 0.3) < 1e-9)
        #expect(SavedLayoutCanvas.snap(0.25, for: divider, travelPoints: 600) == nil)
        #expect(SavedLayoutCanvas.snap(0.34, for: divider, travelPoints: 600)?.label == "⅓")
    }

    // MARK: Swap, move, edge splits

    @Test func swappingExchangesContentAndKeepsTheTree() throws {
        let doc = document(columns([0.63, 0.37], [.slot("a"), rows([0.5, 0.5], [.slot("b"), .empty])]), slots: ["a", "b"])
        let swapped = try #require(SavedLayoutCanvas.swapLeaves(doc.layout!, [0], [1, 0]))
        #expect(swapped == columns([0.63, 0.37], [.slot("b"), rows([0.5, 0.5], [.slot("a"), .empty])]))
        let moved = try #require(SavedLayoutCanvas.swapLeaves(doc.layout!, [0], [1, 1]))
        #expect(moved == columns([0.63, 0.37], [.empty, rows([0.5, 0.5], [.slot("b"), .slot("a")])]))
        #expect(SavedLayoutCanvas.swapLeaves(doc.layout!, [0], [0]) == nil)
    }

    @Test func dropPlansSwapAndMoveApps() throws {
        let doc = document(columns([0.5, 0.5], [.slot("a"), .slot("b")]), slots: ["a", "b"])
        let swap = SavedLayoutCanvas.plan(.pane([0]), onto: .pane([1]), in: doc)
        let result = try #require(edit(swap.outcome))
        #expect(result.document.layout == columns([0.5, 0.5], [.slot("b"), .slot("a")]))
        #expect(result.selection == [1])
        #expect(swap.label == "Swap a with b")
        #expect(valid(result))

        let spare = document(columns([0.5, 0.5], [.slot("a"), .empty]), slots: ["a"])
        let move = SavedLayoutCanvas.plan(.pane([0]), onto: .pane([1]), in: spare)
        #expect(edit(move.outcome)?.document.layout == columns([0.5, 0.5], [.empty, .slot("a")]))
        #expect(move.label == "Move a to pane 2")

        let same = SavedLayoutCanvas.plan(.pane([0]), onto: .pane([0]), in: doc)
        #expect(same.outcome == .unchanged("Drop on another pane."))
        let none = SavedLayoutCanvas.plan(.pane([1]), onto: .pane([0]), in: spare)
        #expect(rejection(none.outcome) == "This pane has no app to move.")
    }

    @Test func paletteAppsReplaceAssignAndUnassign() throws {
        let doc = document(columns([0.5, 0.5], [.slot("a"), .empty]), slots: ["a"])
        let counter = Counter()
        let replace = SavedLayoutCanvas.plan(.app(bundleID: "com.example.new"), onto: .pane([0]), in: doc, makeID: ids(counter))
        let replaced = try #require(edit(replace.outcome))
        #expect(replaced.document.layout == doc.layout)
        #expect(replaced.document.slots == [.init(id: "a", bundleID: "com.example.new")]) // slot ID kept
        let assign = SavedLayoutCanvas.plan(.app(bundleID: "com.example.new"), onto: .pane([1]), in: doc, makeID: ids(counter))
        let assigned = try #require(edit(assign.outcome))
        #expect(assigned.document.layout == columns([0.5, 0.5], [.slot("a"), .slot("slot-1")]))
        #expect(assigned.document.slots.count == 2)
        #expect(valid(assigned))

        let unassign = SavedLayoutCanvas.plan(.pane([0]), onto: .palette, in: doc)
        let cleared = try #require(edit(unassign.outcome))
        #expect(cleared.document.layout == doc.layout) // The pre-existing empty right pane stays empty.
        #expect(cleared.document.slots == [.init(id: "a")])
        #expect(cleared.selection == [0])
        #expect(valid(cleared))

        let again = SavedLayoutCanvas.plan(.app(bundleID: "com.example.a"), onto: .pane([0]), in: doc)
        if case .unchanged = again.outcome {} else { Issue.record("Dropping the same app should change nothing") }
    }

    @Test func edgeSplitFlattensIntoTheParentSplit() throws {
        let doc = document(columns([0.5, 0.5], [.slot("a"), .slot("b")]), slots: ["a", "b"])
        let plan = SavedLayoutCanvas.plan(.app(bundleID: "com.example.c"), onto: .paneEdge([0], .left), in: doc, makeID: ids())
        let result = try #require(edit(plan.outcome))
        expectClose(ratios(result.document.layout), [0.25, 0.25, 0.5])
        #expect(result.document.layout == columns([0.25, 0.25, 0.5], [.slot("slot-1"), .slot("a"), .slot("b")]))
        #expect(result.selection == [0])
        #expect(plan.preview == NormalizedRect(x: 0, y: 0, width: 0.25, height: 1))
        #expect(valid(result))

        let across = SavedLayoutCanvas.plan(.app(bundleID: "com.example.c"), onto: .paneEdge([1], .bottom), in: doc, makeID: ids())
        let stacked = try #require(edit(across.outcome))
        #expect(stacked.document.layout == columns([0.5, 0.5], [.slot("a"), rows([0.5, 0.5], [.slot("b"), .slot("slot-1")])]))
        #expect(stacked.selection == [1, 1])
    }

    @Test func movingAnAppToAnotherPaneEdgeRemovesThePaneItLeft() throws {
        let doc = document(columns([0.3, 0.3, 0.4], [.slot("a"), .slot("b"), .slot("c")]), slots: ["a", "b", "c"])
        let plan = SavedLayoutCanvas.plan(.pane([0]), onto: .paneEdge([2], .bottom), in: doc)
        let result = try #require(edit(plan.outcome))
        // The left pane is gone; b and the new rows share its room.
        expectClose(ratios(result.document.layout), [0.3 / 0.7, 0.4 / 0.7])
        if case let .split(_, _, children)? = result.document.layout {
            #expect(children == [.slot("b"), rows([0.5, 0.5], [.slot("c"), .slot("a")])])
        } else { Issue.record("Expected a split") }
        #expect(result.document.slots.count == 3)
        #expect(result.selection == [1, 1])
        #expect(valid(result))
    }

    @Test func droppingOnTheAppsOwnPaneEdgeKeepsBothHalves() throws {
        let doc = document(columns([0.5, 0.5], [.slot("a"), .slot("b")]), slots: ["a", "b"])
        let plan = SavedLayoutCanvas.plan(.pane([0]), onto: .paneEdge([0], .right), in: doc)
        let result = try #require(edit(plan.outcome))
        let added = try #require(result.document.slots.last)
        #expect(added.prefer.isEmpty)
        #expect(result.document.layout == columns([0.25, 0.25, 0.5], [.slot(added.id), .slot("a"), .slot("b")]))
        #expect(valid(result))
    }

    @Test func canvasEdgeSplitSharesFollowTheRoot() throws {
        // The root already splits columns: one more column takes 1/(n+1).
        let three = document(equalColumns([.slot("a"), .slot("b"), .slot("c")]), slots: ["a", "b", "c"])
        let plan = SavedLayoutCanvas.plan(.app(bundleID: "com.example.d"), onto: .canvasEdge(.left), in: three, makeID: ids())
        let result = try #require(edit(plan.outcome))
        expectClose(ratios(result.document.layout), [0.25, 0.25, 0.25, 0.25], tolerance: 1e-9)
        #expect(plan.isCanvasEdge)
        #expect(plan.preview == NormalizedRect(x: 0, y: 0, width: 0.25, height: 1))
        // A different axis wraps the whole layout with a third.
        let wrapped = SavedLayoutCanvas.plan(.app(bundleID: "com.example.d"), onto: .canvasEdge(.bottom), in: three, makeID: ids())
        let bottom = try #require(edit(wrapped.outcome))
        expectClose(ratios(bottom.document.layout), [2.0 / 3, 1.0 / 3])
        #expect(bottom.selection == [1])
        // A single pane also uses a third.
        let single = document(.slot("a"), slots: ["a"])
        let right = try #require(edit(SavedLayoutCanvas.plan(.app(bundleID: "com.example.d"), onto: .canvasEdge(.right), in: single, makeID: ids()).outcome))
        expectClose(ratios(right.document.layout), [2.0 / 3, 1.0 / 3])
        #expect(valid(right))
    }

    @Test func movingTheOnlyPaneToTheCanvasEdgeChangesNothing() {
        let single = document(.slot("a"), slots: ["a"])
        let plan = SavedLayoutCanvas.plan(.pane([]), onto: .canvasEdge(.left), in: single)
        if case .unchanged = plan.outcome {} else { Issue.record("A lone pane moved to the edge should change nothing") }
    }

    // MARK: Remove and split

    @Test func removingAPaneCollapsesSingleChildSplitsAndRenormalizes() throws {
        let doc = document(columns([0.5, 0.5], [.slot("a"), rows([0.5, 0.5], [.slot("b"), .slot("c")])]), slots: ["a", "b", "c"])
        let first = try #require(edit(SavedLayoutCanvas.removingPane([1, 0], from: doc)))
        #expect(first.document.layout == columns([0.5, 0.5], [.slot("a"), .slot("c")]))
        #expect(first.document.slots.map(\.id) == ["a", "c"]) // the app goes with the pane
        #expect(valid(first))
        let root = try #require(edit(SavedLayoutCanvas.removingPane([0], from: doc)))
        #expect(root.document.layout == rows([0.5, 0.5], [.slot("b"), .slot("c")]))
        let three = document(columns([0.2, 0.3, 0.5], [.empty, .empty, .empty]))
        let kept = try #require(edit(SavedLayoutCanvas.removingPane([0], from: three)))
        expectClose(ratios(kept.document.layout), [0.3 / 0.8, 0.5 / 0.8])
    }

    @Test func theOnlyPaneCannotBeRemoved() {
        let doc = document(.slot("a"), slots: ["a"])
        #expect(rejection(SavedLayoutCanvas.removingPane([], from: doc)) == "The only pane can’t be removed.")
    }

    @Test func splittingPutsTheNewAnyWindowPaneAfterAndSelectsIt() throws {
        let doc = document(columns([0.5, 0.5], [.slot("a"), .slot("b")]), slots: ["a", "b"])
        let result = try #require(edit(SavedLayoutCanvas.splitting([0], axis: .horizontal, in: doc)))
        let added = try #require(result.document.slots.last)
        #expect(added.prefer.isEmpty)
        #expect(result.document.layout == columns([0.5, 0.5], [rows([0.5, 0.5], [.slot("a"), .slot(added.id)]), .slot("b")]))
        #expect(result.selection == [0, 1])
        let flat = try #require(edit(SavedLayoutCanvas.splitting([1], axis: .vertical, in: doc)))
        expectClose(ratios(flat.document.layout), [0.5, 0.25, 0.25])
        #expect(flat.selection == [2])
        #expect(valid(flat))
    }

    @Test func splittingAPaneThatWouldBeTooSmallIsRejected() {
        let doc = document(columns([0.15, 0.85], [.empty, .empty]))
        #expect(rejection(SavedLayoutCanvas.splitting([0], axis: .vertical, in: doc))?.hasPrefix("Not enough room") == true)
    }

    // MARK: Shape names

    @Test func shapeNamesFollowThePresetVocabulary() {
        func name(_ node: SavedLayoutNode) -> String { SavedLayoutCanvas.shape(node).name }
        #expect(name(.empty) == "Single Pane")
        #expect(name(equalColumns([.empty, .empty])) == "2 Columns")
        #expect(name(equalColumns([.empty, .empty, .empty])) == "3 Columns")
        #expect(name(rows([0.25, 0.25, 0.25, 0.25], Array(repeating: .empty, count: 4))) == "4 Rows")
        #expect(name(columns([0.5, 0.5], [rows([0.5, 0.5], [.empty, .empty]), rows([0.5, 0.5], [.empty, .empty])])) == "2×2 Grid")
        #expect(name(columns([1.0 / 3, 1.0 / 3, 1.0 / 3], Array(repeating: rows([0.5, 0.5], [.empty, .empty]), count: 3))) == "3×2 Grid")
        #expect(name(rows([0.5, 0.5], [equalColumns([.empty, .empty, .empty]), equalColumns([.empty, .empty, .empty])])) == "3×2 Grid")
        #expect(name(columns([0.63, 0.37], [.empty, rows([0.5, 0.5], [.empty, .empty])])) == "Main + 2")
        #expect(name(columns([0.5, 0.5], [.empty, rows([0.5, 0.5], [.empty, .empty])])) == "Main + 2")
        #expect(name(columns([0.37, 0.63], [rows([0.5, 0.5], [.empty, .empty]), .empty])) == "Main Right + 2")
        #expect(name(rows([0.6, 0.4], [.empty, equalColumns([.empty, .empty, .empty])])) == "Main Top + 3")
        #expect(name(rows([0.4, 0.6], [equalColumns([.empty, .empty]), .empty])) == "Main Bottom + 2")
        #expect(name(columns([0.3, 0.7], [.empty, .empty])) == "Custom")
        #expect(name(columns([0.4, 0.6], [.empty, rows([0.5, 0.5], [.empty, .empty])])) == "Custom")
    }

    @Test func shapeEqualityToleratesHalfAPercent() {
        func name(_ node: SavedLayoutNode) -> String { SavedLayoutCanvas.shape(node).name }
        #expect(name(columns([0.504, 0.496], [.empty, .empty])) == "2 Columns")
        #expect(name(columns([0.506, 0.494], [.empty, .empty])) == "Custom")
        #expect(name(columns([0.496, 0.504], [.empty, rows([0.5, 0.5], [.empty, .empty])])) == "Main + 2")
    }

    @Test func shapesMapToPresetsOnlyWhenTheyAreOne() {
        #expect(SavedLayoutCanvas.shape(SavedLayoutCanvas.presetLayout(.focus, panes: [])).preset == .focus)
        #expect(SavedLayoutCanvas.shape(SavedLayoutCanvas.presetLayout(.grid, panes: [])).preset == .grid)
        #expect(SavedLayoutCanvas.shape(SavedLayoutCanvas.presetLayout(.columns, panes: [])).preset == .columns)
        #expect(SavedLayoutCanvas.shape(SavedLayoutCanvas.presetLayout(.rows, panes: [])).preset == .rows)
        #expect(SavedLayoutCanvas.shape(.empty).preset == .single)
        #expect(SavedLayoutCanvas.shape(equalColumns([.empty, .empty, .empty])).preset == nil)
    }

    // MARK: Presets

    @Test func presetsCountOnlyAssignedAppsAndDropEmptyPanes() throws {
        let doc = document(equalColumns([.empty, .slot("a"), .empty, .slot("b")]), slots: ["a", "b"])
        // Four panes, two apps: "Two Rows" fits because empty panes do not count.
        let result = try #require(edit(SavedLayoutCanvas.applyingPreset(.rows, to: doc)))
        #expect(result.document.layout == rows([0.5, 0.5], [.slot("a"), .slot("b")]))
        #expect(valid(result))
        let spare = document(equalColumns([.empty, .empty, .slot("a")]), slots: ["a"])
        let single = try #require(edit(SavedLayoutCanvas.applyingPreset(.single, to: spare)))
        #expect(single.document.layout == .slot("a"))
        let many = document(equalColumns([.slot("a"), .slot("b")]), slots: ["a", "b"])
        let rejected = rejection(SavedLayoutCanvas.applyingPreset(.single, to: many))
        #expect(rejected?.contains("fewer panes") == true)
        let padded = try #require(edit(SavedLayoutCanvas.applyingPreset(.grid, to: many)))
        #expect(padded.document.slots.count == 4)
        #expect(padded.document.slots.suffix(2).allSatisfy { $0.prefer.isEmpty })
        #expect(padded.document.layout == SavedLayoutCanvas.presetLayout(.grid, panes: padded.document.slots.map { .slot($0.id) }))
    }

    @Test func choosingTheCurrentPresetKeepsPaneSizes() {
        let doc = document(columns([0.6, 0.4], [.empty, .empty]))
        // 60/40 is Custom, so Two Columns applies.
        #expect(edit(SavedLayoutCanvas.applyingPreset(.columns, to: doc)) != nil)
        let equal = document(equalColumns([.empty, .empty]))
        if case .unchanged = SavedLayoutCanvas.applyingPreset(.columns, to: equal) {} else { Issue.record("The current preset should change nothing") }
    }

    @Test func tabbedPresetStatusNamesTheShapeNotTheAdaptivePresetTitle() throws {
        var doc = document(.empty, mode: .tabbed)
        doc.layout = .empty
        let result = try #require(edit(SavedLayoutCanvas.applyingPreset(.focus, to: doc)))
        #expect(result.summary == "Main + 2.")
        let adaptive = try #require(edit(SavedLayoutCanvas.applyingPreset(.focus, to: document(.empty))))
        #expect(adaptive.summary == "\(TabbedPreset.focus.title).")
    }

    // MARK: Limits

    @Test func adaptiveHoldsSixApps() {
        let six = (0..<6).map { "s\($0)" }
        let doc = document(equalColumns(six.map { .slot($0) }), slots: six)
        let plan = SavedLayoutCanvas.plan(.app(bundleID: "com.example.seven"), onto: .canvasEdge(.bottom), in: doc, makeID: ids())
        #expect(plan.rejection == "Adaptive holds up to 6 apps.")
        // Moving an app does not add one.
        let move = SavedLayoutCanvas.plan(.pane([0]), onto: .canvasEdge(.bottom), in: doc)
        #expect(edit(move.outcome) != nil)
    }

    @Test func tabbedHoldsTwelvePanes() {
        let groups = (0..<12).map { "g\($0)" }
        let cells = groups.map { SavedLayoutNode.group($0) }
        let layout = columns([0.25, 0.25, 0.25, 0.25], (0..<4).map { column in
            rows([1.0 / 3, 1.0 / 3, 1.0 / 3], Array(cells[(column * 3)..<(column * 3 + 3)]))
        })
        var doc = document(layout, mode: .tabbed)
        doc.groups = groups.map { .init(id: $0, slots: [], selected: nil) }
        let plan = SavedLayoutCanvas.plan(.app(bundleID: "com.example.x"), onto: .paneEdge([0, 0], .right), in: doc, makeID: ids())
        #expect(plan.rejection == "Tabbed holds up to 12 panes.")
    }

    @Test func layoutsHoldSixtyFourNodesAndSixteenLevels() {
        let crowded = document(columns(Array(repeating: 1.0 / 63, count: 63), Array(repeating: .empty, count: 63)))
        let wide = SavedLayoutCanvas.problem(in: document(columns(Array(repeating: 1.0 / 64, count: 64), Array(repeating: .empty, count: 64))))
        #expect(wide == "A layout holds up to 64 panes and splits.")
        #expect(SavedLayoutCanvas.problem(in: crowded) == nil)
        func nest(_ depth: Int) -> SavedLayoutNode {
            guard depth > 1 else { return .empty }
            let axis: SplitAxis = depth.isMultiple(of: 2) ? .vertical : .horizontal
            return .split(axis: axis, ratios: [0.5, 0.5], children: [nest(depth - 1), .empty])
        }
        #expect(SavedLayoutCanvas.problem(in: document(nest(16))) == nil)
        #expect(SavedLayoutCanvas.problem(in: document(nest(17))) == "A layout nests up to 16 levels.")
    }

    @Test func aPaneBelowTheMinimumSizeIsRejectedOnlyWhenTheEditMadeIt() {
        let tiny = document(columns([0.05, 0.95], [.empty, .empty]))
        #expect(SavedLayoutCanvas.problem(in: tiny) == nil)
        #expect(SavedLayoutCanvas.problem(in: tiny, checkingMinimumSize: true)?.hasPrefix("Not enough room") == true)
        // Swapping in a layout that already has a small pane is not blocked.
        let swap = SavedLayoutCanvas.plan(.pane([1]), onto: .pane([0]), in: document(columns([0.05, 0.95], [.empty, .slot("a")]), slots: ["a"]))
        #expect(edit(swap.outcome) != nil)
    }

    // MARK: Tabbed

    @Test func tabbedDropsSwapGroupsAddTabsAndMakeGroupsForEdges() throws {
        var doc = document(columns([0.5, 0.5], [.group("g1"), .group("g2")]), slots: ["a", "b"], mode: .tabbed)
        doc.groups = [.init(id: "g1", slots: ["a"], selected: "a"), .init(id: "g2", slots: ["b"], selected: "b")]
        let swap = try #require(edit(SavedLayoutCanvas.plan(.pane([0]), onto: .pane([1]), in: doc).outcome))
        #expect(swap.document.layout == columns([0.5, 0.5], [.group("g2"), .group("g1")]))
        #expect(valid(swap))

        let tab = try #require(edit(SavedLayoutCanvas.plan(.app(bundleID: "com.example.c"), onto: .pane([0]), in: doc, makeID: ids()).outcome))
        #expect(tab.document.groups[0].slots == ["a", "slot-1"])
        #expect(tab.document.groups[0].selected == "slot-1")
        #expect(valid(tab))

        let edge = try #require(edit(SavedLayoutCanvas.plan(.app(bundleID: "com.example.c"), onto: .paneEdge([1], .right), in: doc, makeID: ids()).outcome))
        #expect(edge.document.groups.count == 3)
        #expect(edge.document.layout == columns([0.5, 0.25, 0.25], [.group("g1"), .group("g2"), .group("group-2")]))
        #expect(valid(edge))

        let cleared = try #require(edit(SavedLayoutCanvas.plan(.pane([0]), onto: .palette, in: doc).outcome))
        #expect(cleared.document.groups == doc.groups)
        #expect(cleared.document.slots == [.init(id: "a"), doc.slots[1]])
        #expect(cleared.document.layout == doc.layout)
        #expect(valid(cleared))

        let removed = try #require(edit(SavedLayoutCanvas.removingPane([0], from: doc)))
        #expect(removed.document.layout == .group("g2"))
        #expect(removed.document.groups.map(\.id) == ["g2"])
        #expect(valid(removed))
    }

    @Test func manualLayoutsAreNotEditedByDrags() {
        let manual = SavedLayoutDocument(name: "Manual", mode: .manual)
        #expect(SavedLayoutCanvas.plan(.app(bundleID: "com.example.a"), onto: .pane([]), in: manual).rejection != nil)
    }

    // MARK: Hit testing and navigation

    @Test func dropTargetsFollowTheZones() {
        let panes = SavedLayoutCanvas.leaves(columns([0.5, 0.5], [.empty, .empty]))
        func target(_ x: Double, _ y: Double) -> SavedLayoutDropTarget? {
            SavedLayoutCanvas.dropTarget(x: x, y: y, width: 800, height: 500, leaves: panes)
        }
        #expect(target(200, 250) == .pane([0]))
        #expect(target(600, 250) == .pane([1]))
        #expect(target(5, 250) == .canvasEdge(.left))
        #expect(target(795, 250) == .canvasEdge(.right))
        #expect(target(400, 3) == .canvasEdge(.top))
        #expect(target(300, 495) == .canvasEdge(.bottom))
        // Inside a pane, the outer 28% (14–72 pt) splits it.
        #expect(target(380, 250) == .paneEdge([0], .right))
        #expect(target(60, 250) == .paneEdge([0], .left))
        #expect(target(200, 40) == .paneEdge([0], .top))
        #expect(target(-10, 250) == .canvasEdge(.left)) // slack outside the canvas
        #expect(target(-40, 250) == nil)
    }

    @Test func neighborsFollowGeometryNotTreeOrder() {
        let panes = SavedLayoutCanvas.leaves(columns([0.5, 0.5], [.empty, rows([0.7, 0.3], [.empty, .empty])]))
        #expect(SavedLayoutCanvas.neighbor(of: [0], .right, in: panes) == [1, 0]) // larger overlap wins
        #expect(SavedLayoutCanvas.neighbor(of: [1, 1], .left, in: panes) == [0])
        #expect(SavedLayoutCanvas.neighbor(of: [1, 0], .down, in: panes) == [1, 1])
        #expect(SavedLayoutCanvas.neighbor(of: [1, 0], .up, in: panes) == nil)
        #expect(SavedLayoutCanvas.neighbor(of: [0], .left, in: panes) == nil)
    }
}
