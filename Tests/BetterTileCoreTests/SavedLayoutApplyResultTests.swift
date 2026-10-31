import Foundation
import Testing
@testable import BetterTileCore

@Suite struct SavedLayoutApplyResultTests {
    let bounds = BTRect(x: 100, y: 50, width: 1000, height: 800)
    let a = WindowID(rawValue: "runtime-a")
    let b = WindowID(rawValue: "runtime-b")
    let c = WindowID(rawValue: "runtime-c")

    func eligible(_ extra: [(WindowID, String, BTRect)] = []) -> [SavedLayoutEligibleWindow] {
        [.init(id: a, bundleID: "com.example.Editor", frame: BTRect(x: 120, y: 60, width: 400, height: 300)),
         .init(id: b, bundleID: "com.apple.Safari", frame: BTRect(x: 600, y: 60, width: 400, height: 300)),
         .init(id: c, bundleID: "com.apple.Notes", frame: BTRect(x: 300, y: 400, width: 300, height: 200))]
    }

    @Test func titleAndDetailNameWhatHappened() {
        var result = SavedLayoutApplyResult(placed: 3, unplaced: 1)
        #expect(result.title(layout: "Desk") == "Desk applied")
        #expect(result.detail == "3 placed · 1 skipped")
        result.unplaced = 2
        #expect(result.detail == "3 placed · 2 skipped")
        result.unplaced = 1
        result.issues = [.init(.notRunning, "Mail is not running. Skipped."), .init(.severalWindows, "Choose")]
        #expect(result.title(layout: "Desk") == "Desk applied with 2 issues")
        result.issues.removeLast()
        #expect(result.title(layout: "Desk") == "Desk applied with 1 issue")
        #expect(!result.isClean)
        #expect(result.message == "3 placed · 1 skipped. Mail is not running. Skipped.")
        #expect(SavedLayoutApplyResult(placed: 2).detail == "2 placed")
    }

    @Test func manualCaptureChecksEveryWindowAndLetsTheUserLeaveOneOut() throws {
        let windows = eligible()
        #expect(SavedLayoutCaptureSelection.members(of: .manual).isEmpty)
        #expect(SavedLayoutCaptureSelection.defaultChecked(session: .manual, windows: windows) == [a, b, c])
        let all = try SavedLayoutCaptureSelection.capture(name: "Manual", session: .manual, windows: windows,
                                                          checked: [a, b, c], workArea: bounds)
        #expect(all.mode == .manual)
        #expect(all.windows.count == 3)
        let some = try SavedLayoutCaptureSelection.capture(name: "Manual", session: .manual, windows: windows,
                                                           checked: [a, c], workArea: bounds)
        #expect(Set(some.slots.compactMap(\.preferredAppForFixture)) == ["com.example.Editor", "com.apple.Notes"])
        #expect(some.floats.isEmpty)
    }

    @Test func adaptiveCaptureKeepsMembersAndAddsOnlyCheckedWindowsAsFloats() throws {
        let state = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, children: [.leaf(a), .leaf(b)])))
        let session = SavedLayoutSession.bento(state)
        let windows = eligible()
        #expect(SavedLayoutCaptureSelection.members(of: session) == [a, b])
        #expect(SavedLayoutCaptureSelection.defaultChecked(session: session, windows: windows) == [a, b])
        let plain = try SavedLayoutCaptureSelection.capture(name: "Adaptive", session: session, windows: windows,
                                                            checked: [a, b], workArea: bounds)
        #expect(plain.mode == .bento)
        #expect(plain.slots.count == 2)
        #expect(plain.floats.isEmpty)
        // A member cannot be left out: the tree is the layout.
        let leftOut = try SavedLayoutCaptureSelection.capture(name: "Adaptive", session: session, windows: windows,
                                                              checked: [], workArea: bounds)
        #expect(leftOut.slots.count == 2)
        let withFloat = try SavedLayoutCaptureSelection.capture(name: "Adaptive", session: session, windows: windows,
                                                                checked: [a, b, c], workArea: bounds)
        #expect(withFloat.slots.count == 3)
        #expect(withFloat.floats.count == 1)
        #expect(withFloat.slots.first { $0.id == withFloat.floats[0].slot }?.preferredAppForFixture == "com.apple.Notes")
    }

    @Test func tabbedCaptureKeepsGroupsAndAddsCheckedFloat() throws {
        var state = TabbedLayoutState(preset: .columns)
        state.reconcile(windowIDs: [a, b], removed: [], focused: a)
        state.move(b, to: state.panes[1].id)
        let session = SavedLayoutSession.tabbed(state)
        let windows = eligible()
        #expect(SavedLayoutCaptureSelection.members(of: session) == [a, b])
        let plain = try SavedLayoutCaptureSelection.capture(name: "Tabs", session: session, windows: windows,
                                                            checked: [a, b], workArea: bounds)
        #expect(plain.mode == .tabbed)
        #expect(plain.groups.count == 2)
        #expect(plain.floats.isEmpty)
        let withFloat = try SavedLayoutCaptureSelection.capture(name: "Tabs", session: session, windows: windows,
                                                                checked: [a, b, c], workArea: bounds)
        #expect(withFloat.groups.count == 2)
        #expect(withFloat.floats.count == 1)
        #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(withFloat)) == withFloat)
    }

    @Test func captureClipsAFloatThatReachesPastTheWorkAreaAndRejectsOneOutsideIt() throws {
        let session = SavedLayoutSession.bento(.init(root: .leaf(a)))
        var windows = eligible()
        windows[1].frame = BTRect(x: 900, y: 600, width: 500, height: 500)
        let clipped = try SavedLayoutCaptureSelection.capture(name: "Clipped", session: session, windows: windows,
                                                              checked: [a, b], workArea: bounds)
        let rect = try #require(clipped.floats.first?.rect)
        #expect(rect.x + rect.width <= 1.000001)
        #expect(rect.y + rect.height <= 1.000001)
        windows[1].frame = BTRect(x: 5000, y: 5000, width: 200, height: 200)
        #expect(throws: SavedLayoutValidationError.self) {
            try SavedLayoutCaptureSelection.capture(name: "Outside", session: session, windows: windows,
                                                    checked: [a, b], workArea: bounds)
        }
    }

    @Test func capturedDocumentKeepsTheVersionOneFileFormat() throws {
        let session = SavedLayoutSession.bento(.init(root: .leaf(a)))
        let document = try SavedLayoutCaptureSelection.capture(name: "Format", session: session, windows: eligible(),
                                                               checked: [a, c], workArea: bounds)
        let text = String(decoding: try SavedLayoutValidator.encode(document), as: UTF8.self)
        #expect(document.version == 2)
        for forbidden in ["runtime-", "title", "display", "space", "Desktop"] {
            #expect(!text.contains(forbidden))
        }
        #expect(try SavedLayoutValidator.decode(Data(text.utf8)) == document)
    }

    @Test func aDesktopIsAnIdentityOfDisplayAndSpace() {
        let one = SavedLayoutDesktop(displayID: .init(rawValue: "d"), spaceID: .init(rawValue: 1))
        #expect(one == SavedLayoutDesktop(displayID: .init(rawValue: "d"), spaceID: .init(rawValue: 1)))
        #expect(one != SavedLayoutDesktop(displayID: .init(rawValue: "d"), spaceID: .init(rawValue: 2)))
    }

    @Test func captureLeavesOutMembersThatHaveNoAppIdentifier() throws {
        let unknown = WindowID(rawValue: "runtime-unknown")
        let adaptive = SavedLayoutSession.bento(.init(root: .partition(BentoPartition(axis: .vertical,
            children: [.leaf(a), .leaf(unknown), .leaf(b)]))))
        let document = try SavedLayoutCaptureSelection.capture(name: "Adaptive", session: adaptive, windows: eligible(),
                                                               checked: [a, b], workArea: bounds)
        #expect(document.slots.count == 2)
        var tabs = TabbedLayoutState(preset: .columns)
        tabs.reconcile(windowIDs: [a, unknown, b], removed: [], focused: a)
        let tabbed = try SavedLayoutCaptureSelection.capture(name: "Tabbed", session: .tabbed(tabs), windows: eligible(),
                                                             checked: [a, b], workArea: bounds)
        #expect(tabbed.slots.compactMap(\.preferredAppForFixture).sorted() == ["com.apple.Safari", "com.example.Editor"])
    }
}

@Suite struct SavedLayoutMovedPresentationTests {
    @Test func movesAreSeparateFromPlacedAndOnlyCommittedSlotsCount() {
        var result = SavedLayoutApplyResult(placedSlots: ["a", "b", "c"])
        result.movedSlots = ["c", "rolled-back"]
        result.recordSlots(["a", "b", "c"])
        #expect(result.presentation(layout: "Desk").summary == "2 placed · 1 moved from another display")
        #expect(result.presentation(layout: "Desk").slots["c"]?.text == "Moved from another display")
        result.placedSlots = ["c"]
        result.issues = [.init(.other, "Skipped.", slotID: "a"), .init(.other, "Skipped.", slotID: "b")]
        result.recordSlots(["a", "b", "c"])
        #expect(result.presentation(layout: "Desk").summary == "1 moved from another display · 2 skipped")
        result.placedSlots = []
        result.issues.append(.init(.couldNotFit, "Rolled back.", slotID: "c"))
        result.recordSlots(["a", "b", "c"])
        #expect(!result.presentation(layout: "Desk").summary.contains("moved"))
    }
}
