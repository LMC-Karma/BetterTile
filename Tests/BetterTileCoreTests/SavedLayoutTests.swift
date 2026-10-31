import Foundation
import Testing
@testable import BetterTileCore

@Suite struct SavedLayoutTests {
    let bounds = BTRect(x: 100, y: 50, width: 1000, height: 800)
    let a = WindowID(rawValue: "runtime-a")
    let b = WindowID(rawValue: "runtime-b")
    let c = WindowID(rawValue: "runtime-c")

    func document(mode: LayoutMode = .bento) -> SavedLayoutDocument {
        .init(name: "Work", mode: mode,
              layout: .split(axis: .vertical, ratios: [0.6, 0.4], children: [.slot("editor"), .slot("browser")]),
              slots: [.init(id: "editor", bundleID: "com.example.Editor"), .init(id: "browser", bundleID: "com.apple.Safari")])
    }

    func windows() -> [SavedLayoutEligibleWindow] {
        [.init(id: a, bundleID: "com.example.Editor", frame: bounds),
         .init(id: b, bundleID: "com.apple.Safari", frame: bounds)]
    }

    @Test func codableRoundTripOmitsRuntimeIdentities() throws {
        let original = document()
        let data = try SavedLayoutValidator.encode(original)
        #expect(try JSONDecoder().decode(SavedLayoutDocument.self, from: JSONEncoder().encode(original)) == original)
        #expect(try SavedLayoutValidator.decode(data) == original)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["runtime-a", "runtime-b", "title", "path", "processIdentifier", "windowID", "AX"] {
            #expect(!text.contains(forbidden))
        }
    }

    @Test func futureVersionPreservesSourceAndLastKnownGood() throws {
        let original = document()
        var draft = SavedLayoutDraft()
        #expect(draft.update(try SavedLayoutValidator.encode(original)))
        // The rest of a future schema need not resemble the current format.
        let future = Data("{\n  \"version\": 99, \"future\": {\"keep\": true}\n}\n".utf8)
        #expect(draft.update(future) == false)
        #expect(draft.source == future)
        #expect(draft.lastKnownGood == original)
        #expect(draft.issues.first?.path == "$.version")
        #expect(draft.issues.first?.message.contains("99") == true)
        #expect(draft.update(try SavedLayoutValidator.encode(.init(name: "Empty", mode: .manual))))
        #expect(draft.lastKnownGood?.name == "Empty")
        #expect(draft.issues.isEmpty)
    }

    @Test func malformedJSONRetainsLastKnownGood() throws {
        var draft = SavedLayoutDraft()
        #expect(draft.update(try SavedLayoutValidator.encode(document())))
        let invalid = Data("{\"version\":2,".utf8)
        #expect(draft.update(invalid) == false)
        #expect(draft.source == invalid)
        #expect(draft.lastKnownGood == document())
        #expect(draft.issues.first?.path == "$")
    }

    @Test func futureVersionFileIsUntouched() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("{\"version\":99,\"opaque\":[1,2,3]}".utf8)
        try data.write(to: url)
        var draft = SavedLayoutDraft()
        #expect(draft.update(try Data(contentsOf: url)) == false)
        #expect(try Data(contentsOf: url) == data)
        #expect(draft.lastKnownGood == nil)
    }

    @Test(arguments: [[0.0, 1.0], [-0.1, 1.1], [0.3, 0.3], [0.5], [Double.nan, 0.5]])
    func badRatiosHaveJSONPath(ratios: [Double]) {
        var value = document()
        value.layout = .split(axis: .vertical, ratios: ratios, children: [.slot("editor"), .slot("browser")])
        #expect(SavedLayoutValidator.validate(value).contains { $0.path == "$.layout.ratios" })
    }

    @Test func emptyTreeAndDuplicateSlotsAreRejected() {
        var value = document()
        value.layout = nil
        #expect(SavedLayoutValidator.validate(value).contains { $0.path == "$.layout" })
        value.layout = .split(axis: .horizontal, ratios: [], children: [])
        #expect(SavedLayoutValidator.validate(value).contains { $0.path == "$.layout.children" })
        value = document()
        value.slots.append(value.slots[0])
        #expect(SavedLayoutValidator.validate(value).contains { $0.path == "$.slots[2].id" })
    }

    @Test(arguments: ["adaptive", "tabbed", "future-mode", "linked"])
    func unsupportedModeHasPlainEnglishError(mode: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document())) as? [String: Any])
        object["mode"] = mode
        do {
            _ = try SavedLayoutValidator.decode(JSONSerialization.data(withJSONObject: object))
            Issue.record("Unsupported mode was accepted")
        } catch let error as SavedLayoutValidationError {
            #expect(error.issues.first?.path == "$.mode")
            #expect(error.issues.first?.message.contains("Choose") == true)
        }
    }

    @Test func missingFieldAndNestedTypeErrorsHavePaths() throws {
        let invalid = Data("{\"version\":2,\"name\":\"Work\",\"mode\":\"bento\",\"slots\":[{\"id\":\"a\",\"prefer\":[{\"app\":42}]}]}".utf8)
        do { _ = try SavedLayoutValidator.decode(invalid); Issue.record("Wrong type accepted") }
        catch let error as SavedLayoutValidationError { #expect(error.issues.first?.path == "$.slots[0].prefer[0].app") }
        do { _ = try SavedLayoutValidator.decode(Data("{\"version\":2}".utf8)); Issue.record("Missing name accepted") }
        catch let error as SavedLayoutValidationError { #expect(error.issues.first?.path == "$.name") }
    }

    @Test func brokenReferenceAndRepeatedUseAreRejected() {
        var value = document()
        value.layout = .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("missing-pane"), .slot("editor")])
        #expect(SavedLayoutValidator.validate(value).contains { $0.path == "$.layout.children[0].slot" && $0.message.contains("missing-pane") })
        value.floats = [.init(slot: "editor", rect: .init(x: 0, y: 0, width: 0.2, height: 0.2))]
        #expect(SavedLayoutValidator.validate(value).contains { $0.path == "$.floats[0].slot" })
    }

    @Test func capturePlanIdentityPreservesGapsVacancyAndDeliberateFloat() throws {
        let state = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical,
            children: [.leaf(a), .leaf(b), .vacant(UUID())], ratios: [0.5, 0.3, 0.2])),
            floatingWindowIDs: [c], metrics: .init(paneGap: 6))
        var frames = Dictionary(uniqueKeysWithValues: state.placements(in: bounds).map { ($0.windowID, $0.frame) })
        frames[c] = BTRect(x: 200, y: 150, width: 250, height: 200)
        let bundles = [a: "com.example.Editor", b: "com.apple.Safari", c: "com.apple.Notes"]
        let value = try SavedLayoutCapture.capture(name: "Current", input: .init(session: .bento(state),
            bundleIDs: bundles, frames: frames, workArea: bounds, deliberateFloatingWindowIDs: [c]))
        let eligible = bundles.map { SavedLayoutEligibleWindow(id: $0.key, bundleID: $0.value, frame: frames[$0.key]!) }
        let plan = try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible, currentSession: .bento(state))
        #expect(plan.isEmpty)
        #expect(plan.assignments.count == 3)
        #expect(plan.needsSessionUpdate == false)
        #expect(value.floats.count == 1)
        #expect(value.paneGap == 6)
        #expect(!String(decoding: try SavedLayoutValidator.encode(value), as: UTF8.self).contains("runtime-"))
    }

    @Test func captureExcludesAutomaticFloatsAndFailsForMissingBundle() throws {
        let state = BentoLayoutState(root: .leaf(a), floatingWindowIDs: [b])
        let value = try SavedLayoutCapture.capture(name: "One", input: .init(session: .bento(state),
            bundleIDs: [a: "com.example.Editor"], frames: [:], workArea: bounds))
        #expect(value.slots.count == 1)
        #expect(value.floats.isEmpty)
        #expect(throws: SavedLayoutValidationError.self) {
            try SavedLayoutCapture.capture(name: "One", input: .init(session: .bento(state), bundleIDs: [:], frames: [:], workArea: bounds))
        }
    }

    @Test func twoWindowsOfOneAppUseDistanceAndAllowAChoice() throws {
        let extra = SavedLayoutEligibleWindow(id: c, bundleID: "com.apple.Safari", frame: bounds)
        let plan = try SavedLayoutPlanner.plan(document(), in: bounds, windows: windows() + [extra])
        #expect(plan.assignments == ["editor": a, "browser": b])
        #expect(plan.slotReasons["browser"] == .preferred(rank: 0))
        #expect(plan.slotReasons.values.allSatisfy { $0 != .empty })
        #expect(plan.unmatchedWindowIDs == [c])
        let chosen = try SavedLayoutPlanner.plan(document(), in: bounds, windows: windows() + [extra], choices: ["browser": c])
        #expect(chosen.assignments["browser"] == c)
        #expect(chosen.emptySlots.isEmpty)
        #expect(chosen.unmatchedWindowIDs == [b])
    }

    @Test func repeatedAppSlotsNeverReuseOneWindow() throws {
        var value = document()
        value.slots[1].prefer = value.slots[0].prefer
        let plan = try SavedLayoutPlanner.plan(value, in: bounds, windows: [windows()[0]])
        #expect(plan.assignments.count == 1)
        #expect(plan.emptySlots.count == 1)
        #expect(Set(plan.assignments.values) == [a])
        let chosen = try SavedLayoutPlanner.plan(value, in: bounds, windows: [windows()[0]], choices: ["editor": a])
        #expect(chosen.assignments == ["editor": a])
        #expect(chosen.emptySlots == ["browser"])
        #expect(chosen.slotReasons["browser"] == .empty)
    }

    @Test func unavailablePreferencesLeaveEmptySlotsWithoutLaunchProposals() throws {
        var value = document()
        value.slots[1].prefer = value.slots[0].prefer
        let plan = try SavedLayoutPlanner.plan(value, in: bounds, windows: [])
        #expect(plan.emptySlots == value.slots.map(\.id))
        #expect(plan.slotReasons == ["editor": .empty, "browser": .empty])
        #expect(plan.placements.isEmpty)
        #expect(plan.isEmpty)
        #expect(plan.assignments.isEmpty)
    }

    @Test func workAreaScalesAndSecondApplyConverges() throws {
        let larger = BTRect(x: -1800, y: 100, width: 1800, height: 1200)
        let first = try SavedLayoutPlanner.plan(document(), in: larger, windows: windows())
        #expect(first.placements.first { $0.windowID == a }?.frame == BTRect(x: -1800, y: 100, width: 1080, height: 1200))
        let frames = Dictionary(uniqueKeysWithValues: first.placements.map { ($0.windowID, $0.frame) })
        let settled = windows().map { SavedLayoutEligibleWindow(id: $0.id, bundleID: $0.bundleID, frame: frames[$0.id]!) }
        let second = try SavedLayoutPlanner.plan(document(), in: larger, windows: settled, currentSession: first.targetSession)
        #expect(second.isEmpty)
        #expect(second.assignments == first.assignments)
        #expect(second.targetSession == first.targetSession)
    }

    @Test func minimumSizesAdaptTheExistingTreeAndImpossibleFitFails() throws {
        var eligible = windows()
        eligible[1].minimumSize = BTSize(width: 650, height: 80)
        let first = try SavedLayoutPlanner.plan(document(), in: bounds, windows: eligible)
        let frames = Dictionary(uniqueKeysWithValues: first.placements.map { ($0.windowID, $0.frame) })
        #expect(frames[b]?.size.width == 650)
        #expect(frames[a]?.size.width == 350)
        #expect(frames[a]?.maxX == frames[b]?.minX)
        eligible = eligible.map { .init(id: $0.id, bundleID: $0.bundleID, frame: frames[$0.id]!, minimumSize: $0.minimumSize) }
        #expect(try SavedLayoutPlanner.plan(document(), in: bounds, windows: eligible, currentSession: first.targetSession).isEmpty)
        eligible[0].minimumSize = BTSize(width: 500, height: 80)
        #expect(throws: SavedLayoutValidationError.self) { try SavedLayoutPlanner.plan(document(), in: bounds, windows: eligible) }
    }

    @Test func manualRectanglesCaptureScaleGrowAndConverge() throws {
        let frame = BTRect(x: 200, y: 210, width: 400, height: 320)
        let value = try SavedLayoutCapture.capture(name: "Manual", input: .init(session: .manual,
            bundleIDs: [a: "com.example.Editor"], frames: [a: frame], workArea: bounds))
        #expect(value.windows[0].rect == NormalizedRect(x: 0.1, y: 0.2, width: 0.4, height: 0.4))
        #expect(value.layout == nil)
        #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(value)) == value)
        let eligible = [SavedLayoutEligibleWindow(id: a, bundleID: "com.example.Editor", frame: frame)]
        #expect(try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible, currentSession: .manual).isEmpty)
        let small = BTRect(x: 0, y: 0, width: 500, height: 400)
        let plan = try SavedLayoutPlanner.plan(value, in: small, windows: [.init(id: a, bundleID: "com.example.Editor", frame: frame,
            minimumSize: .init(width: 300, height: 200))])
        #expect(plan.placements == [.init(windowID: a, frame: BTRect(x: 50, y: 80, width: 300, height: 200))])
    }

    @Test func invalidRectanglesAndMixedModesAreRejected() {
        var value = SavedLayoutDocument(name: "Manual", mode: .manual, slots: [.init(id: "a", bundleID: "com.apple.Safari")],
            windows: [.init(slot: "a", rect: .init(x: 0.9, y: 0, width: 0.2, height: 1))])
        #expect(SavedLayoutValidator.validate(value).contains { $0.path == "$.windows[0].rect" })
        value.layout = .slot("a")
        #expect(SavedLayoutValidator.validate(value).contains { $0.path == "$.layout" })
    }

    @Test func tabbedGroupsCaptureRoundTripAndPlanIdentity() throws {
        var state = TabbedLayoutState(preset: .columns)
        state.reconcile(windowIDs: [a, b, c], removed: [], focused: a)
        state.move(c, to: state.panes[1].id)
        state.select(a)
        let snapshots = windows().map { WindowSnapshot(id: $0.id, processIdentifier: 1, frame: $0.frame,
            displayID: .init(rawValue: "test")) } + [WindowSnapshot(id: c, processIdentifier: 1, frame: bounds, displayID: .init(rawValue: "test"))]
        let frames = Dictionary(uniqueKeysWithValues: try state.placements(in: bounds, windows: snapshots).map { ($0.windowID, $0.frame) })
        let bundles = [a: "com.example.Editor", b: "com.apple.Safari", c: "com.apple.Notes"]
        let value = try SavedLayoutCapture.capture(name: "Tabs", input: .init(session: .tabbed(state),
            bundleIDs: bundles, frames: frames, workArea: bounds))
        #expect(value.mode.rawValue == "tabbed-v1")
        #expect(value.groups.map(\.slots.count) == [2, 1])
        #expect(value.groups[0].selected == value.groups[0].slots[0])
        #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(value)) == value)
        let eligible = bundles.map { SavedLayoutEligibleWindow(id: $0.key, bundleID: $0.value, frame: frames[$0.key]!) }
        let plan = try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible, currentSession: .tabbed(state))
        #expect(plan.isEmpty)
        guard case let .tabbed(target) = plan.targetSession else { Issue.record("Expected Tabbed target"); return }
        #expect(target.panes.map(\.tabs) == state.panes.map(\.tabs))
        #expect(target.panes.map(\.selected) == state.panes.map(\.selected))
    }

    @Test func tabbedFitsSelectedMinimumWithStripAndKeepsEmptyPane() throws {
        let value = SavedLayoutDocument(name: "Tabs", mode: .tabbed,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.group("main"), .group("empty")]),
            slots: [.init(id: "a", bundleID: "com.example.Editor"), .init(id: "b", bundleID: "com.apple.Safari")],
            groups: [.init(id: "main", slots: ["a", "b"], selected: "a"), .init(id: "empty", slots: [])], paneGap: 6)
        var eligible = windows()
        eligible[0].minimumSize = .init(width: 700, height: 80)
        // Hidden tabs do not grow the selected pane.
        eligible[1].minimumSize = .init(width: 900, height: 100)
        let plan = try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible)
        guard case let .tabbed(state) = plan.targetSession else { Issue.record("Expected Tabbed"); return }
        #expect(state.panes[1].tabs.isEmpty)
        #expect(state.frames(in: bounds)[state.panes[0].id]?.size.width == 700)
        #expect(plan.placements.first { $0.windowID == a }?.frame.minY == bounds.minY + TabbedLayoutState.headerHeight)
        eligible[0].minimumSize = .init(width: 700, height: 790)
        #expect(throws: SavedLayoutValidationError.self) { try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible) }
    }

    @Test func invalidGroupSelectionAndDuplicateMembershipAreRejected() {
        var value = SavedLayoutDocument(name: "Tabs", mode: .tabbed, layout: .group("main"),
            slots: [.init(id: "a", bundleID: "com.apple.Safari")], groups: [.init(id: "main", slots: ["a"], selected: "missing")])
        #expect(SavedLayoutValidator.validate(value).contains { $0.path == "$.groups[0].selected" })
        value.groups[0].selected = "a"
        value.groups[0].slots.append("a")
        #expect(SavedLayoutValidator.validate(value).contains { $0.path == "$.groups[0].slots[1]" })
    }

    @Test func invalidRuntimeInputsAndChoicesDoNotProducePlans() {
        #expect(throws: SavedLayoutValidationError.self) {
            try SavedLayoutPlanner.plan(document(), in: bounds, windows: windows() + [windows()[0]])
        }
        let chosen = try? SavedLayoutPlanner.plan(document(), in: bounds, windows: windows(), choices: ["editor": b])
        #expect(chosen?.assignments["editor"] == b)
        #expect(chosen?.slotReasons["editor"] == .chosen)
        #expect(throws: SavedLayoutValidationError.self) {
            try SavedLayoutPlanner.plan(document(), in: bounds, windows: windows(), choices: ["missing": a])
        }
        #expect(throws: SavedLayoutValidationError.self) {
            try SavedLayoutPlanner.plan(document(), in: BTRect(x: 0, y: 0, width: 0, height: 800), windows: windows())
        }
    }

    @Test func repeatedAppChoicesConvergeWithoutDuplicateAssignments() throws {
        var value = document()
        value.slots[1].prefer = value.slots[0].prefer
        let eligible = [a, b].map { SavedLayoutEligibleWindow(id: $0, bundleID: "com.example.Editor", frame: bounds) }
        let choices = ["editor": a, "browser": b]
        let first = try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible, choices: choices)
        let frames = Dictionary(uniqueKeysWithValues: first.placements.map { ($0.windowID, $0.frame) })
        let settled = eligible.map { SavedLayoutEligibleWindow(id: $0.id, bundleID: $0.bundleID, frame: frames[$0.id]!) }
        let second = try SavedLayoutPlanner.plan(value, in: bounds, windows: settled, choices: choices, currentSession: first.targetSession)
        #expect(second.isEmpty)
        #expect(Set(second.assignments.values).count == 2)
        #expect(second.emptySlots.isEmpty)
        #expect(throws: SavedLayoutValidationError.self) {
            try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible, choices: ["editor": a, "browser": a])
        }
    }

    @Test func metadataChangesAreNotMistakenForEmptyPlans() throws {
        let value = SavedLayoutDocument(name: "Tabs", mode: .tabbed, layout: .group("main"),
            slots: [.init(id: "a", bundleID: "com.example.Editor"), .init(id: "b", bundleID: "com.apple.Safari")],
            groups: [.init(id: "main", slots: ["a", "b"], selected: "a")])
        let initial = try SavedLayoutPlanner.plan(value, in: bounds, windows: windows())
        let frames = Dictionary(uniqueKeysWithValues: initial.placements.map { ($0.windowID, $0.frame) })
        let settled = windows().map { SavedLayoutEligibleWindow(id: $0.id, bundleID: $0.bundleID, frame: frames[$0.id]!) }
        guard case var .tabbed(current) = initial.targetSession else { Issue.record("Expected Tabbed"); return }
        current.select(b)
        let selected = try SavedLayoutPlanner.plan(value, in: bounds, windows: settled, currentSession: .tabbed(current))
        #expect(selected.placements.isEmpty)
        #expect(selected.needsSessionUpdate == true)
        #expect(!selected.isEmpty)
        let mode = try SavedLayoutPlanner.plan(value, in: bounds, windows: settled, currentSession: .manual)
        #expect(mode.needsSessionUpdate == true)
        let matching = try SavedLayoutPlanner.plan(value, in: bounds, windows: settled, currentSession: initial.targetSession)
        #expect(matching.isEmpty)
    }

    @Test func swappedTabbedPanesStillCaptureIdentity() throws {
        var current = TabbedLayoutState(preset: .columns)
        current.reconcile(windowIDs: [a, b], removed: [], focused: a)
        current.move(b, to: current.panes[1].id)
        var swapped = current.layout
        swapped.swap(a, b)
        current.synchronize(with: swapped)
        let snapshots = windows().map { WindowSnapshot(id: $0.id, processIdentifier: 1, frame: bounds,
            displayID: .init(rawValue: "test")) }
        let frames = Dictionary(uniqueKeysWithValues: try current.placements(in: bounds, windows: snapshots).map { ($0.windowID, $0.frame) })
        let bundles = [a: "com.example.Editor", b: "com.apple.Safari"]
        let value = try SavedLayoutCapture.capture(name: "Swapped", input: .init(session: .tabbed(current),
            bundleIDs: bundles, frames: frames, workArea: bounds))
        let eligible = windows().map { SavedLayoutEligibleWindow(id: $0.id, bundleID: $0.bundleID, frame: frames[$0.id]!) }
        #expect(try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible, currentSession: .tabbed(current)).isEmpty)
    }

    @Test func changedCurrentMembershipProducesAPlanRatherThanAnError() throws {
        let current = BentoLayoutState(root: .leaf(c))
        let plan = try SavedLayoutPlanner.plan(document(), in: bounds, windows: windows(), currentSession: .bento(current))
        #expect(plan.needsSessionUpdate == true)
        #expect(plan.assignments.count == 2)
    }

    @Test func captureRejectsOffscreenRectanglesAndFloatMembershipConflicts() {
        let offscreen = BTRect(x: 0, y: 0, width: 200, height: 200)
        #expect(throws: SavedLayoutValidationError.self) {
            try SavedLayoutCapture.capture(name: "Manual", input: .init(session: .manual,
                bundleIDs: [a: "com.example.Editor"], frames: [a: offscreen], workArea: bounds))
        }
        #expect(throws: SavedLayoutValidationError.self) {
            try SavedLayoutCapture.capture(name: "Adaptive", input: .init(session: .bento(.init(root: .leaf(a))),
                bundleIDs: [a: "com.example.Editor"], frames: [a: bounds], workArea: bounds, deliberateFloatingWindowIDs: [a]))
        }
    }

    @Test func documentedExamplesPassSharedValidator() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("docs/SAVED_LAYOUTS.md"), encoding: .utf8)
        let examples = text.components(separatedBy: "```json\n").dropFirst().map {
            $0.components(separatedBy: "```")[0]
        }
        #expect(examples.count == 3)
        for example in examples {
            let document = try SavedLayoutValidator.decode(Data(example.utf8))
            #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(document)) == document)
        }
    }

    // Isolated Core reproduction: a fixed-size Tabbed capture must change nothing.
    @Test func fixedSizeTabbedCaptureMustBeANoOp() throws {
        let state = try #require(TabbedLayoutState(adopting: BentoLayoutState(root: .leaf(a))))
        let constraints = WindowConstraints(isResizable: false)
        let snapshot = WindowSnapshot(id: a, processIdentifier: 1, frame: BTRect(x: 450, y: 284, width: 300, height: 400),
            displayID: .init(rawValue: "test"), constraints: constraints)
        let placement = try #require(state.placements(in: bounds, windows: [snapshot]).first)
        let value = try SavedLayoutCapture.capture(name: "Fixed", input: .init(session: .tabbed(state),
            bundleIDs: [a: "com.example.Fixed"], frames: [a: placement.frame], workArea: bounds))
        let plan = try SavedLayoutPlanner.plan(value, in: bounds, windows: [
            .init(id: a, bundleID: "com.example.Fixed", frame: placement.frame, constraints: constraints)
        ], currentSession: .tabbed(state))
        #expect(plan.isEmpty)
    }

    @Test func steppedTabbedReapplyMustBeANoOp() throws {
        let value = SavedLayoutDocument(name: "Terminal", mode: .tabbed, layout: .group("main"),
            slots: [.init(id: "term", bundleID: "com.apple.Terminal")],
            groups: [.init(id: "main", slots: ["term"], selected: "term")])
        let initial = try SavedLayoutPlanner.plan(value, in: bounds, windows: [
            .init(id: a, bundleID: "com.apple.Terminal", frame: bounds)])
        let request = try #require(initial.placements.first).frame
        var actual = request
        actual.size.height -= 10
        #expect(SteppedSizeAcceptance.evaluate(requested: request, actual: actual) == .stepped)
        let grid = try #require(SteppedGrid(observed: [actual.size.height - 15, actual.size.height]))
        let again = try SavedLayoutPlanner.plan(value, in: bounds, windows: [
            .init(id: a, bundleID: "com.apple.Terminal", frame: actual)], currentSession: initial.targetSession,
            steppedGrids: [a: [.horizontal: grid]])
        #expect(again.isEmpty)
    }

    @Test func hiddenMinimumReapplyMustBeANoOp() throws {
        let value = SavedLayoutDocument(name: "Hidden", mode: .tabbed,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.empty, .group("main")]),
            slots: [.init(id: "front", bundleID: "com.example.Front"), .init(id: "back", bundleID: "com.example.Back")],
            groups: [.init(id: "main", slots: ["front", "back"], selected: "front")])
        let eligible: [SavedLayoutEligibleWindow] = [
            .init(id: a, bundleID: "com.example.Front", frame: bounds),
            .init(id: b, bundleID: "com.example.Back", frame: bounds, minimumSize: .init(width: 900, height: 80))]
        let first = try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible)
        let settled = try eligible.map { window -> SavedLayoutEligibleWindow in
            var window = window
            window.frame = try #require(first.placements.first { $0.windowID == window.id }).frame
            if window.id == b { window.frame.size.width = 900 }
            return window
        }
        let again = try SavedLayoutPlanner.plan(value, in: bounds, windows: settled, currentSession: first.targetSession)
        #expect(again.isEmpty)
        let hidden = try #require(first.placements.first { $0.windowID == b }).frame
        #expect(hidden.size.width == 900)
        #expect(hidden.maxX <= bounds.maxX)
        guard case let .tabbed(state) = first.targetSession else { Issue.record("Expected Tabbed"); return }
        #expect(state.frames(in: bounds).values.allSatisfy { $0.size.width == 500 })
    }

    // Isolated Core reproduction: a hidden Tabbed minimum between grid steps converges.
    @Test(arguments: [SplitAxis.vertical, .horizontal])
    func hiddenTabbedMinimumBetweenGridStepsConverges(axis: SplitAxis) throws {
        let bounds = BTRect(x: -1000, y: 50, width: 1000, height: 800)
        let value = SavedLayoutDocument(name: "Hidden grid", mode: .tabbed,
            layout: .split(axis: axis, ratios: [0.5, 0.5], children: [.empty, .group("main")]),
            slots: [.init(id: "front", bundleID: "com.example.Front"), .init(id: "back", bundleID: "com.example.Back")],
            groups: [.init(id: "main", slots: ["front", "back"], selected: "front")])
        // Different steps and offsets, with each minimum between two grid lengths.
        for (observed, width, height) in [([904.0, 919], 919.0, 619.0),
                                         ([900.0, 907], 914.0, 613.0),
                                         ([889.0, 913], 913.0, 625.0)] {
            let grid = try #require(SteppedGrid(observed: observed))
            let minimum = axis == .vertical ? BTSize(width: 911, height: 80) : BTSize(width: 80, height: 611)
            var eligible: [SavedLayoutEligibleWindow] = [
                .init(id: a, bundleID: "com.example.Front", frame: bounds),
                .init(id: b, bundleID: "com.example.Back", frame: bounds, minimumSize: minimum)]
            let grids: [WindowID: [SplitAxis: SteppedGrid]] = [b: [axis: grid]]
            let first = try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible, steppedGrids: grids)
            let hidden = try #require(first.placements.first { $0.windowID == b }).frame
            #expect((axis == .vertical ? hidden.size.width : hidden.size.height) == (axis == .vertical ? width : height))
            #expect(grid.contains(axis == .vertical ? hidden.size.width : hidden.size.height))
            #expect(hidden.minX >= bounds.minX && hidden.maxX <= bounds.maxX)
            #expect(hidden.minY >= bounds.minY && hidden.maxY <= bounds.maxY)
            guard case let .tabbed(state) = first.targetSession else { Issue.record("Expected Tabbed"); return }
            #expect(state.frames(in: bounds).values.allSatisfy {
                axis == .vertical ? $0.size.width <= 524 : $0.size.height <= 424
            })
            for i in eligible.indices {
                eligible[i].frame = try #require(first.placements.first { $0.windowID == eligible[i].id }).frame
            }
            // Model the application's accepted grid size, even if the request was between steps.
            if axis == .vertical { eligible[1].frame.size.width = width }
            else { eligible[1].frame.size.height = height }
            for _ in 0..<3 {
                #expect(try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible,
                    currentSession: first.targetSession, steppedGrids: grids).isEmpty)
            }
        }
    }

    @Test(arguments: [SplitAxis.vertical, .horizontal], [false, true])
    func fixedTabbedWindowsIgnoreRememberedGrids(axis: SplitAxis, hidden: Bool) throws {
        let value = SavedLayoutDocument(name: "Fixed grid", mode: .tabbed,
            layout: .split(axis: axis, ratios: [0.5, 0.5], children: [.empty, .group("main")]),
            slots: [.init(id: "fixed", bundleID: "com.example.Fixed"), .init(id: "peer", bundleID: "com.example.Peer")],
            groups: [.init(id: "main", slots: ["fixed", "peer"], selected: hidden ? "peer" : "fixed")])
        var eligible: [SavedLayoutEligibleWindow] = [
            .init(id: a, bundleID: "com.example.Fixed", frame: .init(x: 0, y: 0, width: 300, height: 400),
                constraints: .init(isResizable: false)),
            .init(id: b, bundleID: "com.example.Peer", frame: bounds)]
        let grid = try #require(SteppedGrid(observed: axis == .vertical ? [275, 290] : [375, 390]))
        let grids: [WindowID: [SplitAxis: SteppedGrid]] = [a: [axis: grid]]
        let withoutGrid = try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible)
        let first = try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible, steppedGrids: grids)
        #expect(first.targetSession == withoutGrid.targetSession)
        #expect(first.placements == withoutGrid.placements)
        #expect(try #require(first.placements.first { $0.windowID == a }).frame.size == eligible[0].frame.size)
        for i in eligible.indices {
            let requested = try #require(first.placements.first { $0.windowID == eligible[i].id }).frame
            eligible[i].frame.origin = requested.origin
            if eligible[i].constraints.isResizable { eligible[i].frame.size = requested.size }
        }
        for _ in 0..<3 {
            #expect(try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible,
                currentSession: first.targetSession, steppedGrids: grids).isEmpty)
        }
    }

    @Test(arguments: [SplitAxis.vertical, .horizontal])
    func selectedTabbedSteppedMinimumAtWorkAreaBoundary(axis: SplitAxis) throws {
        let value = SavedLayoutDocument(name: "Grid boundary", mode: .tabbed, layout: .group("main"),
            slots: [.init(id: "term", bundleID: "com.example.Terminal")],
            groups: [.init(id: "main", slots: ["term"], selected: "term")])
        // Last fitting grid lengths for a 1000-by-800 work area, below the 34-point strip.
        for (observed, width, height) in [([20.0, 22], 1000.0, 766.0),
                                         ([71.0, 78], 995.0, 764.0),
                                         ([154.0, 169], 994.0, 754.0),
                                         ([244.0, 268], 988.0, 748.0)] {
            let grid = try #require(SteppedGrid(observed: observed))
            let lastFittingLength = axis == .vertical ? width : height
            var window = SavedLayoutEligibleWindow(id: a, bundleID: "com.example.Terminal", frame: bounds,
                minimumSize: axis == .vertical
                    ? .init(width: lastFittingLength - 0.5, height: 80)
                    : .init(width: 80, height: lastFittingLength - 0.5))
            let grids: [WindowID: [SplitAxis: SteppedGrid]] = [a: [axis: grid]]
            let first = try SavedLayoutPlanner.plan(value, in: bounds, windows: [window], steppedGrids: grids)
            window.frame = try #require(first.placements.first).frame
            #expect((axis == .vertical ? window.frame.size.width : window.frame.size.height) == lastFittingLength)
            #expect(window.frame.minX >= bounds.minX && window.frame.maxX <= bounds.maxX)
            #expect(window.frame.minY >= bounds.minY && window.frame.maxY <= bounds.maxY)
            for _ in 0..<3 {
                #expect(try SavedLayoutPlanner.plan(value, in: bounds, windows: [window],
                    currentSession: first.targetSession, steppedGrids: grids).isEmpty)
            }
            window.minimumSize = axis == .vertical
                ? .init(width: lastFittingLength + 0.5, height: 80)
                : .init(width: 80, height: lastFittingLength + 0.5)
            #expect(throws: SavedLayoutValidationError.self) {
                try SavedLayoutPlanner.plan(value, in: bounds, windows: [window], steppedGrids: grids)
            }
        }
    }

    @Test func hugeWideTreeGetsRejected() {
        let children = Array(repeating: SavedLayoutNode.empty, count: 100_000)
        let value = SavedLayoutDocument(name: "Huge", mode: .bento, layout: .split(axis: .vertical,
            ratios: Array(repeating: 1.0 / Double(children.count), count: children.count), children: children))
        #expect(!SavedLayoutValidator.validate(value).isEmpty)
        #expect(throws: SavedLayoutValidationError.self) { try SavedLayoutValidator.encode(value) }
    }

    @Test func deeplyNestedJSONIsRejectedAndRetained() throws {
        var node = #"{"empty":true}"#
        for _ in 0..<250 {
            node = #"{"split":"vertical","ratios":[0.5,0.5],"children":["# + node + #",{"empty":true}]}"#
        }
        let data = Data((#"{"version":2,"name":"Deep","mode":"bento","slots":[],"layout":"# + node + "}").utf8)
        var draft = SavedLayoutDraft()
        #expect(draft.update(try SavedLayoutValidator.encode(document())))
        #expect(draft.update(data) == false)
        #expect(draft.source == data)
        #expect(draft.lastKnownGood == document())
        #expect(!draft.issues.isEmpty)
    }

    @Test func unknownFieldsAreRejectedAndRetained() throws {
        let data = Data(#"{"version":2,"name":"Extension","mode":"manual","slots":[],"recipe":{"keep":true}}"#.utf8)
        var draft = SavedLayoutDraft()
        #expect(draft.update(try SavedLayoutValidator.encode(document())))
        #expect(draft.update(data) == false)
        #expect(draft.source == data)
        #expect(draft.lastKnownGood == document())
        #expect(draft.issues.first?.path == "$.recipe")
    }

    @Test func nestedSameAxisSplitsAreRejected() {
        let value = SavedLayoutDocument(name: "Nested", mode: .bento, layout: .split(axis: .vertical,
            ratios: [0.5, 0.5], children: [.split(axis: .vertical, ratios: [0.5, 0.5], children: [.empty, .empty]), .empty]))
        #expect(SavedLayoutValidator.validate(value).contains { $0.path == "$.layout.children[0].split" })
    }


    @Test func treeDepthLimitAppliesToImportsAndEditorValues() throws {
        for depth in [16, 17] {
            var node = SavedLayoutNode.empty
            for level in 1..<depth {
                node = .split(axis: level.isMultiple(of: 2) ? .vertical : .horizontal,
                    ratios: [0.5, 0.5], children: [node, .empty])
            }
            let value = SavedLayoutDocument(name: "Depth", mode: .bento, layout: node)
            let data = try JSONEncoder().encode(value)
            #expect(SavedLayoutValidator.validate(value).isEmpty == (depth == 16))
            if depth == 16 { #expect(try SavedLayoutValidator.decode(data) == value) }
            else {
                #expect(throws: SavedLayoutValidationError.self) { try SavedLayoutValidator.decode(data) }
                #expect(throws: SavedLayoutValidationError.self) { try SavedLayoutValidator.encode(value) }
            }
        }
    }

    @Test func totalNodeLimitCountsEmptyPanes() throws {
        for childCount in [63, 64] {
            let value = SavedLayoutDocument(name: "Nodes", mode: .bento, layout: .split(axis: .vertical,
                ratios: Array(repeating: 1.0 / Double(childCount), count: childCount),
                children: Array(repeating: .empty, count: childCount)))
            let data = try JSONEncoder().encode(value)
            #expect(SavedLayoutValidator.validate(value).isEmpty == (childCount == 63))
            if childCount == 63 { #expect(try SavedLayoutValidator.decode(data) == value) }
            else { #expect(throws: SavedLayoutValidationError.self) { try SavedLayoutValidator.decode(data) } }
        }
    }

    @Test func slotLimitAppliesToManualImportsAndEditorValues() throws {
        for count in [64, 65] {
            let ids = (0..<count).map { "slot-\($0)" }
            let value = SavedLayoutDocument(name: "Slots", mode: .manual,
                slots: ids.map { .init(id: $0, bundleID: "com.example.Editor") },
                windows: ids.map { .init(slot: $0, rect: .init(x: 0, y: 0, width: 1, height: 1)) })
            #expect(SavedLayoutValidator.validate(value).isEmpty == (count == 64))
            if count == 64 { #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(value)) == value) }
            else {
                #expect(throws: SavedLayoutValidationError.self) { try SavedLayoutValidator.decode(JSONEncoder().encode(value)) }
            }
        }
    }

    @Test func fileSizeLimitRetainsOversizedSourceAndBoundsEditorExport() throws {
        let original = document()
        let encoded = try SavedLayoutValidator.encode(original)
        var data = encoded + Data(repeating: 32, count: 1_048_576 - encoded.count)
        var draft = SavedLayoutDraft()
        #expect(draft.update(data) == true)
        data.append(32)
        #expect(draft.update(data) == false)
        #expect(draft.source == data)
        #expect(draft.lastKnownGood == original)
        #expect(draft.issues.first?.path == "$")
        let oversized = SavedLayoutDocument(name: String(repeating: "x", count: 1_048_576), mode: .manual)
        #expect(!SavedLayoutValidator.validate(oversized).isEmpty)
        #expect(throws: SavedLayoutValidationError.self) { try SavedLayoutValidator.encode(oversized) }
    }

    @Test func byteDepthScanIgnoresBracketsEscapedQuotesAndBackslashesInStrings() throws {
        var value = document()
        value.name = String(repeating: #"[{\"\\"#, count: 100)
        #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(value)) == value)
    }

    @Test(arguments: ["$.layout", "$.slots[0]", "$.groups[0]", "$.floats[0]", "$.floats[0].rect"])
    func nestedUnknownFieldsAreRejected(path: String) throws {
        let value = SavedLayoutDocument(name: "Keys", mode: .tabbed, layout: .group("main"),
            slots: [.init(id: "a", bundleID: "com.example.Editor"), .init(id: "b", bundleID: "com.example.Other")],
            groups: [.init(id: "main", slots: ["a"], selected: "a")],
            floats: [.init(slot: "b", rect: .init(x: 0, y: 0, width: 0.5, height: 0.5))])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        switch path {
        case "$.layout": object["layout"] = ["group": "main", "extra": true]
        case "$.slots[0]": object["slots"] = [["id": "a", "prefer": [["app": "com.example.Editor"]], "extra": true]]
        case "$.groups[0]": object["groups"] = [["id": "main", "slots": ["a"], "selected": "a", "extra": true]]
        case "$.floats[0]": object["floats"] = [["slot": "b", "extra": true]]
        default: object["floats"] = [["slot": "b", "rect": ["x": 0, "y": 0, "width": 0.5, "height": 0.5, "extra": true]]]
        }
        do {
            _ = try SavedLayoutValidator.decode(JSONSerialization.data(withJSONObject: object))
            Issue.record("Unknown field accepted")
        } catch let error as SavedLayoutValidationError {
            #expect(error.issues.first?.path == path + ".extra")
            #expect(error.issues.first?.message.contains("Unknown field") == true)
        }
    }

    @Test func leafNodesRejectUnusedSplitFields() throws {
        let data = Data(#"{"version":2,"name":"Leaf","mode":"bento","slots":[],"layout":{"empty":true,"ratios":[0.5,0.5]}}"#.utf8)
        do {
            _ = try SavedLayoutValidator.decode(data)
            Issue.record("Unused split field accepted")
        } catch let error as SavedLayoutValidationError { #expect(error.issues.first?.path == "$.layout.ratios") }
    }

    @Test func captureNormalizesSameAxisSplits() throws {
        var state = BentoLayoutState(root: .leaf(a))
        state.root = .partition(.init(axis: .vertical, children: [
            .partition(.init(axis: .vertical, children: [.leaf(a), .vacant(UUID())], ratios: [0.5, 0.5])),
            .vacant(UUID())], ratios: [0.5, 0.5]))
        let value = try SavedLayoutCapture.capture(name: "Normalized", input: .init(session: .bento(state),
            bundleIDs: [a: "com.example.Editor"], frames: [:], workArea: bounds))
        #expect(value.layout == .split(axis: .vertical, ratios: [0.25, 0.25, 0.5], children: [.slot("slot-1"), .empty, .empty]))
        #expect(SavedLayoutValidator.validate(value).isEmpty)
    }

    @Test func steppedGridFitsDividersAndReapplyConverges() throws {
        let value = SavedLayoutDocument(name: "Rows", mode: .tabbed,
            layout: .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.group("main"), .group("other")]),
            slots: [.init(id: "term", bundleID: "com.apple.Terminal"), .init(id: "editor", bundleID: "com.example.Editor")],
            groups: [.init(id: "main", slots: ["term"], selected: "term"), .init(id: "other", slots: ["editor"], selected: "editor")])
        let eligible: [SavedLayoutEligibleWindow] = [.init(id: a, bundleID: "com.apple.Terminal", frame: bounds), .init(id: b, bundleID: "com.example.Editor", frame: bounds)]
        let grid = try #require(SteppedGrid(observed: [356, 371]))
        let grids: [WindowID: [SplitAxis: SteppedGrid]] = [a: [.horizontal: grid]]
        let first = try SavedLayoutPlanner.plan(value, in: bounds, windows: eligible, steppedGrids: grids)
        #expect(first.placements.first { $0.windowID == a }?.frame.size.height == 371)
        #expect(first.placements.first { $0.windowID == b }?.frame.minY == bounds.minY + 405 + TabbedLayoutState.headerHeight)
        let settled = try eligible.map { window -> SavedLayoutEligibleWindow in
            var window = window
            window.frame = try #require(first.placements.first { $0.windowID == window.id }).frame
            return window
        }
        #expect(try SavedLayoutPlanner.plan(value, in: bounds, windows: settled,
            currentSession: first.targetSession, steppedGrids: grids).isEmpty)
    }

    // Isolated Core reproduction: re-applying a manual stepped grid converges.
    @Test func manualSteppedGridReapplyConverges() throws {
        let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
        let bundle = "com.apple.Terminal"
        let value = SavedLayoutDocument(name: "Manual Terminal", mode: .manual,
            slots: [.init(id: "term", bundleID: bundle)],
            windows: [.init(slot: "term", rect: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))])
        let initial = try SavedLayoutPlanner.plan(value, in: bounds, windows: [.init(id: a, bundleID: bundle, frame: bounds)])
        let request = try #require(initial.placements.first).frame
        var actual = request
        actual.size.height -= 10
        let grid = try #require(SteppedGrid(observed: [actual.size.height - 15, actual.size.height]))
        let again = try SavedLayoutPlanner.plan(value, in: bounds, windows: [.init(id: a, bundleID: bundle, frame: actual)], currentSession: initial.targetSession, steppedGrids: [a: [.horizontal: grid]])
        #expect(again.isEmpty)
    }

    @Test func bentoSteppedGridReapplyConverges() throws {
        let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
        let bundle = "com.apple.Terminal"
        let value = SavedLayoutDocument(name: "Adaptive Terminal", mode: .bento, layout: .slot("term"), slots: [.init(id: "term", bundleID: bundle)])
        var actual = bounds
        actual.size.height -= 10
        let grid = try #require(SteppedGrid(observed: [actual.size.height - 15, actual.size.height]))
        let again = try SavedLayoutPlanner.plan(value, in: bounds, windows: [.init(id: a, bundleID: bundle, frame: actual)], steppedGrids: [a: [.horizontal: grid]])
        #expect(again.placements.isEmpty)
    }

    @Test func floatSteppedGridReapplyConverges() throws {
        let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
        let bundle = "com.apple.Terminal"
        let value = SavedLayoutDocument(name: "Float Terminal", mode: .tabbed, layout: .empty,
            slots: [.init(id: "term", bundleID: bundle)],
            floats: [.init(slot: "term", rect: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))])
        let actual = BTRect(x: 100, y: 80, width: 800, height: 630)
        let grid = try #require(SteppedGrid(observed: [615, 630]))
        let again = try SavedLayoutPlanner.plan(value, in: bounds, windows: [.init(id: a, bundleID: bundle, frame: actual)], steppedGrids: [a: [.horizontal: grid]])
        #expect(again.placements.isEmpty)
    }

    @Test func fixedManualWindowKeepsItsRuntimeSize() throws {
        let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
        let small = BTRect(x: 100, y: 100, width: 300, height: 400)
        let value = try SavedLayoutCapture.capture(name: "Fixed", input: .init(session: .manual, bundleIDs: [a: "com.example.Fixed"], frames: [a: small], workArea: bounds))
        let larger = BTRect(x: 0, y: 0, width: 2000, height: 1600)
        let plan = try SavedLayoutPlanner.plan(value, in: larger, windows: [.init(id: a, bundleID: "com.example.Fixed", frame: small, constraints: .init(isResizable: false))])
        let request = try #require(plan.placements.first).frame
        #expect(request.size == small.size)
    }

    @Test func fixedFloatWindowKeepsItsRuntimeSize() throws {
        let small = BTRect(x: 100, y: 100, width: 300, height: 400)
        let value = SavedLayoutDocument(name: "Fixed float", mode: .tabbed, layout: .empty,
            slots: [.init(id: "fixed", bundleID: "com.example.Fixed")],
            floats: [.init(slot: "fixed", rect: .init(x: 0.1, y: 0.125, width: 0.3, height: 0.5))])
        let larger = BTRect(x: 0, y: 0, width: 2000, height: 1600)
        let plan = try SavedLayoutPlanner.plan(value, in: larger, windows: [.init(id: a, bundleID: "com.example.Fixed", frame: small, constraints: .init(isResizable: false))])
        let request = try #require(plan.placements.first).frame
        #expect(request.size == small.size)
    }

    @Test(arguments: [LayoutMode.manual, .bento, .tabbed])
    func steppedMinimumThatCannotFitRejectsPlan(mode: LayoutMode) throws {
        let rectangle = SavedLayoutRectangle(slot: "term", rect: .init(x: 0, y: 0, width: 1, height: 1))
        let value = SavedLayoutDocument(name: "Minimum", mode: mode,
            layout: mode == .manual ? nil : (mode == .bento ? .slot("term") : .empty),
            slots: [.init(id: "term", bundleID: "com.apple.Terminal")],
            windows: mode == .manual ? [rectangle] : [], floats: mode == .tabbed ? [rectangle] : [])
        let grid = try #require(SteppedGrid(observed: [775, 790]))
        // The first grid height above the 795-point minimum is 805; the work area is 800 high.
        #expect(throws: SavedLayoutValidationError.self) {
            try SavedLayoutPlanner.plan(value, in: bounds, windows: [
                .init(id: a, bundleID: "com.apple.Terminal", frame: .init(x: 0, y: 0, width: 300, height: 400),
                    minimumSize: .init(width: 80, height: 795))], steppedGrids: [a: [.horizontal: grid]])
        }
    }

    // Isolated Core reproduction: a rectangle minimum between grid steps converges.
    @Test(arguments: [LayoutMode.manual, .bento, .tabbed], [SplitAxis.horizontal, .vertical])
    func rectangleMinimumBetweenGridStepsConverges(mode: LayoutMode, axis: SplitAxis) throws {
        let bounds = BTRect(x: -1000, y: 50, width: 1000, height: 800)
        let bundle = "com.example.Terminal"
        let grid = try #require(SteppedGrid(observed: [90, 105]))
        let rect = SavedLayoutRectangle(slot: "term", rect: .init(x: 0.1, y: 0.1,
            width: axis == .vertical ? 0.08 : 0.8, height: axis == .horizontal ? 0.1 : 0.8))
        let value = SavedLayoutDocument(name: "Minimum grid", mode: mode,
            layout: mode == .manual ? nil : .empty,
            slots: [.init(id: "term", bundleID: bundle)],
            windows: mode == .manual ? [rect] : [], floats: mode == .manual ? [] : [rect])
        var window = SavedLayoutEligibleWindow(id: a, bundleID: bundle, frame: bounds,
            minimumSize: .init(width: 80, height: 80))
        let first = try SavedLayoutPlanner.plan(value, in: bounds, windows: [window], steppedGrids: [a: [axis: grid]])
        let frame = try #require(first.placements.first).frame
        let expected = BTRect(x: bounds.minX + 100, y: bounds.minY + 80,
            width: axis == .vertical ? 90 : 800, height: axis == .horizontal ? 90 : 640)
        #expect(frame == expected)
        window.frame = expected
        for _ in 0..<3 {
            #expect(try SavedLayoutPlanner.plan(value, in: bounds, windows: [window],
                currentSession: first.targetSession, steppedGrids: [a: [axis: grid]]).isEmpty)
        }
    }

    @Test(arguments: [SplitAxis.horizontal, .vertical])
    func adaptiveMinimumBetweenGridStepsConverges(axis: SplitAxis) throws {
        let bounds = BTRect(x: -1000, y: 50, width: 1000, height: 800)
        let bundle = "com.example.Terminal"
        let grid = try #require(SteppedGrid(observed: [90, 105]))
        let share = axis == .horizontal ? 0.1 : 0.08
        let value = SavedLayoutDocument(name: "Adaptive minimum grid", mode: .bento,
            layout: .split(axis: axis, ratios: [share, 1 - share], children: [.slot("term"), .empty]),
            slots: [.init(id: "term", bundleID: bundle)])
        var window = SavedLayoutEligibleWindow(id: a, bundleID: bundle, frame: bounds,
            minimumSize: .init(width: 80, height: 80))
        let first = try SavedLayoutPlanner.plan(value, in: bounds, windows: [window], steppedGrids: [a: [axis: grid]])
        let frame = try #require(first.placements.first).frame
        let expected = BTRect(x: bounds.minX, y: bounds.minY,
            width: axis == .vertical ? 90 : 1000, height: axis == .horizontal ? 90 : 800)
        #expect(frame == expected)
        window.frame = expected
        for _ in 0..<3 {
            #expect(try SavedLayoutPlanner.plan(value, in: bounds, windows: [window],
                currentSession: first.targetSession, steppedGrids: [a: [axis: grid]]).isEmpty)
        }
    }

    @Test(arguments: [LayoutMode.manual, .bento, .tabbed])
    func fixedRectanglesClampPositionAndRejectSizesThatCannotFit(mode: LayoutMode) throws {
        let rectangle = SavedLayoutRectangle(slot: "fixed", rect: .init(x: 0.8, y: 0.8, width: 0.2, height: 0.2))
        let value = SavedLayoutDocument(name: "Fixed", mode: mode, layout: mode == .manual ? nil : .empty,
            slots: [.init(id: "fixed", bundleID: "com.example.Fixed")],
            windows: mode == .manual ? [rectangle] : [], floats: mode == .manual ? [] : [rectangle])
        let window = SavedLayoutEligibleWindow(id: a, bundleID: "com.example.Fixed",
            frame: .init(x: 0, y: 0, width: 300, height: 400), constraints: .init(isResizable: false))
        let grid = try #require(SteppedGrid(observed: [375, 390]))
        let plan = try SavedLayoutPlanner.plan(value, in: bounds, windows: [window], steppedGrids: [a: [.horizontal: grid]])
        #expect(try #require(plan.placements.first).frame == BTRect(x: 800, y: 450, width: 300, height: 400))
        #expect(throws: SavedLayoutValidationError.self) {
            try SavedLayoutPlanner.plan(value, in: .init(x: 100, y: 50, width: 200, height: 300), windows: [window])
        }
    }

    @Test func compactImportReportsFormattedExportSizeLimit() throws {
        let overhead = try JSONEncoder().encode(SavedLayoutDocument(name: "", mode: .manual)).count
        let value = SavedLayoutDocument(name: String(repeating: "x", count: SavedLayoutValidator.maximumBytes - overhead), mode: .manual)
        let data = try JSONEncoder().encode(value)
        #expect(data.count == SavedLayoutValidator.maximumBytes)
        var draft = SavedLayoutDraft()
        #expect(draft.update(data) == false)
        #expect(draft.source == data)
        #expect(draft.issues.first?.message == "The formatted file must stay within 1 MiB (1,048,576 bytes); this layout is too large.")
    }

    @Test(arguments: ["1e999", "-1e999", String(repeating: "9", count: 1000)])
    func numericOverflowReportsRangeAndRetainsSource(number: String) throws {
        var draft = SavedLayoutDraft()
        #expect(draft.update(try SavedLayoutValidator.encode(document())))
        for field in ["paneGap", "version"] {
            let version = field == "version" ? number : "1"
            let gap = field == "paneGap" ? number : "0"
            let data = Data("{\"version\":\(version),\"name\":\"Range\",\"mode\":\"manual\",\"slots\":[],\"paneGap\":\(gap)}".utf8)
            #expect(draft.update(data) == false)
            #expect(draft.source == data)
            #expect(draft.lastKnownGood == document())
            #expect(draft.issues.first?.message == "A number is outside the supported numeric range. Use finite numbers that fit in a 64-bit floating-point value.")
        }
    }

    @Test func numericTextInsideStringsIsNotAnOverflow() throws {
        let data = Data(#"{"version":2,"name":"1e999 and \"-1e999\"","mode":"manual","slots":[],"paneGap":0}"#.utf8)
        let value = try SavedLayoutValidator.decode(data)
        #expect(value.paneGap == 0)
        #expect(value.name == #"1e999 and "-1e999""#)
    }
}

@Test func savedLayoutFlowPlannerReusesDistinctCurrentDesktopWindows() throws {
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let document = SavedLayoutDocument(name: "Editors", mode: .bento,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("a"), .slot("b")]),
        slots: [.init(id: "a", bundleID: "com.example.Editor"), .init(id: "b", bundleID: "com.example.Editor")])
    let windows = ["three", "one", "two"].map { SavedLayoutEligibleWindow(id: .init(rawValue: $0), bundleID: "com.example.Editor", frame: bounds) }
    let plan = try SavedLayoutPlanner.plan(document, in: bounds, windows: windows)
    #expect(plan.assignments == ["a": WindowID(rawValue: "one"), "b": WindowID(rawValue: "three")])
    #expect(plan.unmatchedWindowIDs == [WindowID(rawValue: "two")])
    let again = try SavedLayoutPlanner.plan(document, in: bounds, windows: windows.reversed())
    #expect(again == plan)
    let partial = try SavedLayoutPlanner.plan(document, in: bounds, windows: Array(windows.prefix(1)))
    #expect(partial.assignments.count == 1)
    #expect(partial.emptySlots == ["b"])
}

@Test func savedLayoutFlowAlreadyMatchingRepeatedAppsKeepsPaneMembership() throws {
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let document = SavedLayoutDocument(name: "Editors", mode: .bento,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("a"), .slot("b")]),
        slots: [.init(id: "a", bundleID: "com.example.Editor"), .init(id: "b", bundleID: "com.example.Editor")])
    var windows = ["z", "a"].map { SavedLayoutEligibleWindow(id: .init(rawValue: $0), bundleID: "com.example.Editor", frame: bounds) }
    let first = try SavedLayoutPlanner.plan(document, in: bounds, windows: windows,
        choices: ["a": windows[0].id, "b": windows[1].id])
    for index in windows.indices { windows[index].frame = first.placements.first { $0.windowID == windows[index].id }!.frame }
    let again = try SavedLayoutPlanner.plan(document, in: bounds, windows: windows, currentSession: first.targetSession)
    #expect(again.isEmpty)
    #expect(again.assignments == first.assignments)
}

@Test func savedLayoutFlowRoundedFloatingFrameIsAlreadyPlaced() throws {
    let bounds = BTRect(x: 1210, y: 30, width: 2560, height: 1410)
    let id = WindowID(rawValue: "float")
    let document = SavedLayoutDocument(name: "Rounded float", mode: .bento, layout: .empty,
        slots: [.init(id: "float", bundleID: "com.example.Editor")],
        floats: [.init(slot: "float", rect: .init(x: 0.6, y: 0.6, width: 0.25, height: 0.25))])
    let window = SavedLayoutEligibleWindow(id: id, bundleID: "com.example.Editor",
        frame: .init(x: 2746, y: 876, width: 640, height: 353))
    let current = try SavedLayoutPlanner.plan(document, in: bounds, windows: [window]).targetSession
    let plan = try SavedLayoutPlanner.plan(document, in: bounds, windows: [window], currentSession: current)
    #expect(plan.isEmpty)
    var moved = window
    moved.frame.origin.x += 4
    let repair = try SavedLayoutPlanner.plan(document, in: bounds, windows: [moved], currentSession: current)
    #expect(repair.placements.count == 1)
}
