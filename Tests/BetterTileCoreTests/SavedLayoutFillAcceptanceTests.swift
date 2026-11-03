// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation
import Testing
@testable import BetterTileCore

/// Acceptance tests for the Saved Layouts fill pipeline: preference ranking, distance tie breaks,
/// extra windows, tabs and determinism. The first groups follow five worked setups; the last group
/// holds extra cases.
@Suite struct SavedLayoutFillAcceptanceTests {
    static let workArea = BTRect(x: 0, y: 0, width: 1000, height: 800)

    enum App {
        static let preview = "com.apple.Preview"
        static let pages = "com.apple.iWork.Pages"
        static let safari = "com.apple.Safari"
        static let chrome = "com.google.Chrome"
        static let arc = "company.thebrowser.Browser"
        static let finder = "com.apple.finder"
        static let notes = "com.apple.Notes"
        static let mail = "com.apple.mail"
        static let music = "com.apple.Music"
        static let xcode = "com.apple.dt.Xcode"
        static let vsCode = "com.microsoft.VSCode"
        static let terminal = "com.apple.Terminal"
        static let slack = "com.tinyspeck.slackmacgap"
    }

    /// Browser = Safari, Chrome, Arc. Coding = Xcode, VS Code.
    static let appGroups = AppGroupsDocument(groups: [
        AppGroup(name: "Browser", apps: [.init(name: "Safari", bundleID: App.safari),
                                         .init(name: "Google Chrome", bundleID: App.chrome),
                                         .init(name: "Arc", bundleID: App.arc)]),
        AppGroup(name: "Coding", apps: [.init(name: "Xcode", bundleID: App.xcode),
                                        .init(name: "Visual Studio Code", bundleID: App.vsCode)]),
    ])

    // MARK: Helpers

    /// A frame from normalized work-area coordinates (x, y, width, height), top-left origin.
    static func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> BTRect {
        BTRect(x: x * workArea.size.width, y: y * workArea.size.height,
               width: width * workArea.size.width, height: height * workArea.size.height)
    }

    /// Frames that do not decide a row. Its centre is the work-area centre.
    static let anywhere = frame(0.4, 0.4, 0.2, 0.2)

    /// Windows listed front to back: the first is frontmost (frontRank 0).
    static func windows(_ specs: [(String, String, BTRect?)]) -> [SavedLayoutEligibleWindow] {
        specs.enumerated().map { index, spec in
            var window = SavedLayoutEligibleWindow(id: .init(rawValue: spec.0), bundleID: spec.1, frame: spec.2 ?? anywhere)
            window.frontRank = index
            return window
        }
    }

    static func id(_ raw: String) -> WindowID { .init(rawValue: raw) }

    static func plan(_ document: SavedLayoutDocument, _ windows: [SavedLayoutEligibleWindow],
                     groups: AppGroupsDocument = appGroups, resolved: [AppGroupEntry: String] = [:],
                     choices: [String: WindowID] = [:]) throws -> SavedLayoutApplyPlan {
        try SavedLayoutPlanner.plan(document, in: workArea, windows: windows,
                                    appGroups: groups, resolvedBundleIDs: resolved, choices: choices)
    }

    static func bento(_ plan: SavedLayoutApplyPlan) -> BentoLayoutState? {
        if case let .bento(state) = plan.targetSession { state } else { nil }
    }

    static func tabbed(_ plan: SavedLayoutApplyPlan) -> TabbedLayoutState? {
        if case let .tabbed(state) = plan.targetSession { state } else { nil }
    }

    static func vacancies(_ node: BentoNode?) -> Int {
        guard let node else { return 0 }
        switch node {
        case .leaf: return 0
        case .vacant: return 1
        case let .partition(partition): return partition.children.map(vacancies).reduce(0, +)
        }
    }

    static func placed(_ plan: SavedLayoutApplyPlan, _ raw: String) -> Bool {
        plan.placements.contains { $0.windowID == id(raw) }
    }

    // MARK: Layouts used by the worked setups

    /// Setup 1 "Homework": L 60 % | RT over RB. L = Preview › Pages › @Browser, RT = @Browser, RB = Finder › Notes.
    /// Flattened: L = Preview 0, Pages 1, Safari 2, Chrome 3, Arc 4; RT = Safari 0, Chrome 1, Arc 2; RB = Finder 0, Notes 1.
    static func homework(extraWindows: SavedLayoutExtraWindows = .float) -> SavedLayoutDocument {
        SavedLayoutDocument(name: "Homework", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.6, 0.4], children: [
                .slot("L"),
                .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("RT"), .slot("RB")]),
            ]),
            slots: [.init(id: "L", prefer: [.app(App.preview), .app(App.pages), .group("Browser")]),
                    .init(id: "RT", prefer: [.group("Browser")]),
                    .init(id: "RB", prefer: [.app(App.finder), .app(App.notes)])],
            extraWindows: extraWindows)
    }

    /// Setup 2 "Coding", Tabbed "Main + 2". Main = @Coding, RT = @Browser, RB = Terminal › Notes.
    /// One slot per pane; group IDs name the panes.
    static let coding = SavedLayoutDocument(name: "Coding", mode: .tabbed,
        layout: .split(axis: .vertical, ratios: [0.6, 0.4], children: [
            .group("g-main"),
            .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.group("g-rt"), .group("g-rb")]),
        ]),
        slots: [.init(id: "main", prefer: [.group("Coding")]),
                .init(id: "rt", prefer: [.group("Browser")]),
                .init(id: "rb", prefer: [.app(App.terminal), .app(App.notes)])],
        groups: [.init(id: "g-main", slots: ["main"], selected: "main"),
                 .init(id: "g-rt", slots: ["rt"], selected: "rt"),
                 .init(id: "g-rb", slots: ["rb"], selected: "rb")])

    /// Setup 3 "Writing": Adaptive 50/50, no preferences.
    static func writing(extraWindows: SavedLayoutExtraWindows = .float) -> SavedLayoutDocument {
        SavedLayoutDocument(name: "Writing", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("L"), .slot("R")]),
            slots: [.init(id: "L"), .init(id: "R")], extraWindows: extraWindows)
    }

    /// Setup 4 "Two browsers": Adaptive 50/50, both panes prefer @Browser.
    static let twoBrowsers = SavedLayoutDocument(name: "Two browsers", mode: .bento,
        layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("L"), .slot("R")]),
        slots: [.init(id: "L", prefer: [.group("Browser")]), .init(id: "R", prefer: [.group("Browser")])])

    /// Setup 5 "Reference", Manual: main prefers Xcode, ref prefers @Browser.
    static let reference = SavedLayoutDocument(name: "Reference", mode: .manual,
        slots: [.init(id: "main", prefer: [.app(App.xcode)]), .init(id: "ref", prefer: [.group("Browser")])],
        windows: [.init(slot: "main", rect: .init(x: 0.15, y: 0.1, width: 0.7, height: 0.8)),
                  .init(slot: "ref", rect: .init(x: 0.7, y: 0, width: 0.3, height: 0.35))])

    // MARK: Setup 1, Adaptive, extras float

    @Test func homeworkAllFirstChoices() throws {
        let plan = try Self.plan(Self.homework(), Self.windows([
            ("preview", App.preview, nil), ("safari", App.safari, nil), ("finder", App.finder, nil)]))
        #expect(plan.assignments == ["L": Self.id("preview"), "RT": Self.id("safari"), "RB": Self.id("finder")])
        #expect(plan.slotReasons == ["L": .preferred(rank: 0), "RT": .preferred(rank: 0), "RB": .preferred(rank: 0)])
        #expect(plan.emptySlots.isEmpty)
        #expect(plan.extras.isEmpty)
    }

    @Test func homeworkBestAvailableRanks() throws {
        let plan = try Self.plan(Self.homework(), Self.windows([
            ("pages", App.pages, nil), ("chrome", App.chrome, nil), ("notes", App.notes, nil)]))
        #expect(plan.assignments == ["L": Self.id("pages"), "RT": Self.id("chrome"), "RB": Self.id("notes")])
        #expect(plan.slotReasons == ["L": .preferred(rank: 1), "RT": .preferred(rank: 1), "RB": .preferred(rank: 1)])
    }

    /// The largest pane stays empty when the open windows prefer the small panes.
    @Test func homeworkLargestPaneStaysEmpty() throws {
        let plan = try Self.plan(Self.homework(), Self.windows([("safari", App.safari, nil), ("finder", App.finder, nil)]))
        #expect(plan.assignments == ["RT": Self.id("safari"), "RB": Self.id("finder")])
        #expect(plan.emptySlots == ["L"])
        #expect(plan.slotReasons["L"] == .empty)
        let state = try #require(Self.bento(plan))
        #expect(Self.vacancies(state.root) == 1)
        #expect(Set(state.root?.windowIDs ?? []) == [Self.id("safari"), Self.id("finder")])
    }

    /// Most first choices first. A plain rank sum ties (L Safari 2 + RT Chrome 1 = L Chrome 3 + RT Safari 0)
    /// and distance would keep Safari in L. Group order says Safari wins the Browser pane.
    @Test func homeworkMostFirstChoicesBeatDistance() throws {
        let plan = try Self.plan(Self.homework(), Self.windows([
            ("safari", App.safari, Self.frame(0, 0, 0.6, 1)),
            ("chrome", App.chrome, Self.frame(0.6, 0, 0.4, 0.5)),
            ("finder", App.finder, nil)]))
        #expect(plan.assignments == ["L": Self.id("chrome"), "RT": Self.id("safari"), "RB": Self.id("finder")])
        #expect(plan.slotReasons == ["L": .preferred(rank: 3), "RT": .preferred(rank: 0), "RB": .preferred(rank: 0)])
    }

    @Test func homeworkUnpreferredWindowTakesTheFreePane() throws {
        let plan = try Self.plan(Self.homework(), Self.windows([
            ("safari", App.safari, nil), ("mail", App.mail, nil), ("finder", App.finder, nil)]))
        #expect(plan.assignments == ["L": Self.id("mail"), "RT": Self.id("safari"), "RB": Self.id("finder")])
        #expect(plan.slotReasons["L"] == .largestFreeSlot)
        #expect(plan.extras.isEmpty)
    }

    @Test func homeworkOneWindow() throws {
        let plan = try Self.plan(Self.homework(), Self.windows([("preview", App.preview, nil)]))
        #expect(plan.assignments == ["L": Self.id("preview")])
        #expect(plan.emptySlots == ["RT", "RB"])
        #expect(plan.slotReasons == ["L": .preferred(rank: 0), "RT": .empty, "RB": .empty])
        #expect(Self.vacancies(try #require(Self.bento(plan)).root) == 2)
    }

    /// Preferred windows fill every pane; the frontmost unpreferred window floats where it is (only Tabbed turns extras into tabs).
    @Test func homeworkExtrasFloatWhereTheyAre() throws {
        let plan = try Self.plan(Self.homework(), Self.windows([
            ("mail", App.mail, nil), ("preview", App.preview, nil), ("safari", App.safari, nil),
            ("finder", App.finder, nil), ("music", App.music, Self.frame(0.1, 0.1, 0.3, 0.3))]))
        #expect(plan.assignments == ["L": Self.id("preview"), "RT": Self.id("safari"), "RB": Self.id("finder")])
        #expect(plan.extras == [Self.id("mail"): .floating, Self.id("music"): .floating])
        let state = try #require(Self.bento(plan))
        #expect(state.floatingWindowIDs.isSuperset(of: [Self.id("mail"), Self.id("music")]))
        #expect(!Self.placed(plan, "mail") && !Self.placed(plan, "music"))
    }

    // MARK: Setup 2, Tabbed, extras become tabs

    /// Chrome joins the pane whose preferences list it (RT). Slack has no match and joins the nearest pane by
    /// centre (Main: d² 0.04 vs 0.1525). The frontmost window that becomes
    /// an extra tab is the selected tab of its pane, so Xcode is the hidden tab in Main.
    @Test func codingExtrasBecomeTabsAndFrontmostStaysVisible() throws {
        let plan = try Self.plan(Self.coding, Self.windows([
            ("slack", App.slack, Self.frame(0.3, 0.3, 0.4, 0.4)), ("xcode", App.xcode, nil),
            ("safari", App.safari, nil), ("terminal", App.terminal, nil), ("chrome", App.chrome, nil)]))
        #expect(plan.assignments == ["main": Self.id("xcode"), "rt": Self.id("safari"), "rb": Self.id("terminal")])
        #expect(plan.extras == [Self.id("chrome"): .tab(groupID: "g-rt", reason: .listedApp),
                                Self.id("slack"): .tab(groupID: "g-main", reason: .nearestPane)])
        let state = try #require(Self.tabbed(plan))
        let main = try #require(state.pane(containing: Self.id("xcode")))
        #expect(main.tabs.contains(Self.id("slack")))
        #expect(main.selected == Self.id("slack"))
        let rt = try #require(state.pane(containing: Self.id("safari")))
        #expect(rt.tabs.contains(Self.id("chrome")))
        #expect(rt.selected == Self.id("safari"))
        #expect(state.pane(containing: Self.id("terminal"))?.tabs == [Self.id("terminal")])
    }

    /// Tabs within a pane are ordered front to back.
    @Test func codingTabsAreOrderedFrontToBack() throws {
        let plan = try Self.plan(Self.coding, Self.windows([
            ("slack", App.slack, Self.frame(0.3, 0.3, 0.4, 0.4)), ("xcode", App.xcode, nil),
            ("safari", App.safari, nil), ("terminal", App.terminal, nil), ("chrome", App.chrome, nil)]))
        let state = try #require(Self.tabbed(plan))
        #expect(state.pane(containing: Self.id("xcode"))?.tabs == [Self.id("slack"), Self.id("xcode")])
        #expect(state.pane(containing: Self.id("safari"))?.tabs == [Self.id("safari"), Self.id("chrome")])
    }

    /// A preferred window that loses its pane fills a free pane before it becomes a tab.
    @Test func codingFreePanesFillBeforeTabs() throws {
        let plan = try Self.plan(Self.coding, Self.windows([
            ("vscode", App.vsCode, Self.frame(0.6, 0.5, 0.4, 0.5)), ("xcode", App.xcode, nil), ("safari", App.safari, nil)]))
        #expect(plan.assignments == ["main": Self.id("xcode"), "rt": Self.id("safari"), "rb": Self.id("vscode")])
        #expect(plan.slotReasons == ["main": .preferred(rank: 0), "rt": .preferred(rank: 0), "rb": .largestFreeSlot])
        #expect(plan.extras.isEmpty)
    }

    /// In Tabbed, Main stays an empty pane.
    @Test func codingMainStaysAnEmptyPane() throws {
        let plan = try Self.plan(Self.coding, Self.windows([("chrome", App.chrome, nil), ("notes", App.notes, nil)]))
        #expect(plan.assignments == ["rt": Self.id("chrome"), "rb": Self.id("notes")])
        #expect(plan.emptySlots == ["main"])
        let state = try #require(Self.tabbed(plan))
        #expect(state.panes.count == 3)
        #expect(state.panes.filter(\.tabs.isEmpty).count == 1)
        #expect(Set(state.selectedWindowIDs) == [Self.id("chrome"), Self.id("notes")])
    }

    // MARK: Setup 3, no preferences

    /// The frontmost window takes the nearest of the equally largest panes, so nothing moves.
    /// Safari is nearer to L than Mail (d² 0 vs 0.065), so Mail is the extra and floats.
    @Test func writingFrontmostTakesTheNearestLargestPane() throws {
        let plan = try Self.plan(Self.writing(), Self.windows([
            ("pages", App.pages, Self.frame(0.5, 0, 0.5, 1)), ("safari", App.safari, Self.frame(0, 0, 0.5, 1)),
            ("mail", App.mail, Self.frame(0.3, 0.2, 0.4, 0.5))]))
        #expect(plan.assignments == ["L": Self.id("safari"), "R": Self.id("pages")])
        #expect(plan.slotReasons == ["L": .nearestPosition, "R": .largestFreeSlot])
        #expect(plan.extras == [Self.id("mail"): .floating])
        #expect(plan.placements.isEmpty)
    }

    @Test func writingExtrasAsPanesUseTheNormalInsert() throws {
        let plan = try Self.plan(Self.writing(extraWindows: .addAsPanes), Self.windows([
            ("pages", App.pages, Self.frame(0.5, 0, 0.5, 1)), ("safari", App.safari, Self.frame(0, 0, 0.5, 1)),
            ("mail", App.mail, Self.frame(0.3, 0.2, 0.4, 0.5))]))
        #expect(plan.assignments == ["L": Self.id("safari"), "R": Self.id("pages")])
        #expect(plan.extras == [Self.id("mail"): .addedAsPane])
        let state = try #require(Self.bento(plan))
        #expect(Set(state.root?.windowIDs ?? []) == [Self.id("pages"), Self.id("safari"), Self.id("mail")])
        #expect(!state.floatingWindowIDs.contains(Self.id("mail")))
    }

    // MARK: Setup 4, same app or group in two panes

    @Test func twoBrowsersSameAppTwiceGoesByPosition() throws {
        let plan = try Self.plan(Self.twoBrowsers, Self.windows([
            ("safari-a", App.safari, Self.frame(0, 0, 0.5, 1)), ("safari-b", App.safari, Self.frame(0.5, 0, 0.5, 1)),
            ("notes", App.notes, nil)]))
        #expect(plan.assignments == ["L": Self.id("safari-a"), "R": Self.id("safari-b")])
        #expect(plan.extras == [Self.id("notes"): .floating])
    }

    /// Both assignments use ranks {0, 1}; distance decides, so nothing moves.
    @Test func twoBrowsersEqualRanksGoByPosition() throws {
        let plan = try Self.plan(Self.twoBrowsers, Self.windows([
            ("safari", App.safari, Self.frame(0.5, 0, 0.5, 1)), ("chrome", App.chrome, Self.frame(0, 0, 0.5, 1))]))
        #expect(plan.assignments == ["L": Self.id("chrome"), "R": Self.id("safari")])
        #expect(plan.slotReasons == ["L": .preferred(rank: 1), "R": .preferred(rank: 0)])
    }

    // MARK: Setup 5, Manual

    @Test func referenceManualExtrasStayWhereTheyAre() throws {
        let plan = try Self.plan(Self.reference, Self.windows([
            ("xcode", App.xcode, nil), ("safari", App.safari, nil), ("mail", App.mail, nil)]))
        #expect(plan.assignments == ["main": Self.id("xcode"), "ref": Self.id("safari")])
        #expect(plan.extras == [Self.id("mail"): .untouched])
        #expect(!Self.placed(plan, "mail"))
    }

    @Test func referenceUnpreferredWindowTakesTheLargestFreeRectangle() throws {
        let plan = try Self.plan(Self.reference, Self.windows([("mail", App.mail, nil), ("safari", App.safari, nil)]))
        #expect(plan.assignments == ["main": Self.id("mail"), "ref": Self.id("safari")])
        #expect(plan.slotReasons == ["main": .largestFreeSlot, "ref": .preferred(rank: 0)])
    }

    // MARK: Extra cases

    /// A cut inside equal slots fills the slots nearest the windows (same reasoning as the frontmost
    /// window taking the nearest largest pane). With 2 windows in the middle and right of 3 equal
    /// columns, nothing moves and C1 stays empty.
    @Test func equalSlotsNearestTheWindowsAreFilled() throws {
        let third = 1.0 / 3
        let document = SavedLayoutDocument(name: "Three", mode: .bento,
            layout: .split(axis: .vertical, ratios: [third, third, third], children: [.slot("C1"), .slot("C2"), .slot("C3")]),
            slots: [.init(id: "C1"), .init(id: "C2"), .init(id: "C3")])
        let plan = try Self.plan(document, Self.windows([
            ("a", App.pages, Self.frame(2 * third, 0, third, 1)), ("b", App.safari, Self.frame(third, 0, third, 1))]))
        #expect(plan.assignments == ["C2": Self.id("b"), "C3": Self.id("a")])
        #expect(plan.emptySlots == ["C1"])
        #expect(plan.slotReasons == ["C1": .empty, "C2": .nearestPosition, "C3": .largestFreeSlot])
    }

    /// Name-only App Group entries count only once the App layer resolves them.
    @Test func resolvedGroupEntriesTakePart() throws {
        let arc = AppGroupEntry(name: "Arc")
        let groups = AppGroupsDocument(groups: [AppGroup(name: "Browser", apps: [
            .init(name: "Safari", bundleID: App.safari), .init(name: "Google Chrome", bundleID: App.chrome), arc])])
        let windows = Self.windows([("arc", App.arc, nil)])
        // Resolved: Arc is RT rank 2 and L rank 4. More early ranks win, so RT.
        let resolved = try Self.plan(Self.homework(), windows, groups: groups, resolved: [arc: App.arc])
        #expect(resolved.assignments == ["RT": Self.id("arc")])
        #expect(resolved.slotReasons["RT"] == .preferred(rank: 2))
        // Unresolved: Arc matches no preference and takes the largest free pane.
        let unresolved = try Self.plan(Self.homework(), windows, groups: groups)
        #expect(unresolved.assignments == ["L": Self.id("arc")])
        #expect(unresolved.slotReasons["L"] == .largestFreeSlot)
    }

    /// An unknown group is skipped: no error, and its pane behaves as if the item were absent.
    @Test func unknownGroupIsSkipped() throws {
        var document = Self.homework()
        document.slots[1].prefer = [.group("Reading")]
        let plan = try Self.plan(document, Self.windows([("safari", App.safari, nil)]))
        #expect(plan.assignments == ["L": Self.id("safari")])
        #expect(plan.slotReasons["L"] == .preferred(rank: 2))
    }

    /// An explicit Choose Window choice wins over preferences.
    @Test func explicitChoiceWins() throws {
        let windows = Self.windows([("safari", App.safari, nil), ("chrome", App.chrome, nil)])
        let plan = try Self.plan(Self.homework(), windows, choices: ["L": Self.id("safari")])
        #expect(plan.assignments == ["L": Self.id("safari"), "RT": Self.id("chrome")])
        #expect(plan.slotReasons["L"] == .chosen)
        #expect(plan.slotReasons["RT"] == .preferred(rank: 1))
    }

    /// With "Add extra windows as panes", Adaptive holds at most six windows; the rest float.
    @Test func extrasAsPanesStopAtSix() throws {
        var specs: [(String, String, BTRect?)] = [("w0", App.pages, Self.frame(0, 0, 0.5, 1)),
                                                  ("w1", App.safari, Self.frame(0.5, 0, 0.5, 1))]
        for index in 2..<8 { specs.append(("w\(index)", App.notes, Self.frame(0.05 * Double(index), 0.1, 0.3, 0.3))) }
        let plan = try Self.plan(Self.writing(extraWindows: .addAsPanes), Self.windows(specs))
        #expect(plan.assignments == ["L": Self.id("w0"), "R": Self.id("w1")])
        let state = try #require(Self.bento(plan))
        #expect(state.root?.windowIDs.count == 6)
        #expect(plan.extras.values.filter { $0 == .addedAsPane }.count == 4)
        #expect(plan.extras.values.filter { $0 == .floating }.count == 2)
    }

    /// Determinism: the order of the input array does not matter; only frontRank does.
    @Test(arguments: ["homework", "coding", "writing"]) func inputOrderDoesNotChangeThePlan(row: String) throws {
        let (document, windows): (SavedLayoutDocument, [SavedLayoutEligibleWindow]) = switch row {
        case "homework": (Self.homework(), Self.windows([("safari", App.safari, Self.frame(0, 0, 0.6, 1)),
                                                  ("chrome", App.chrome, Self.frame(0.6, 0, 0.4, 0.5)), ("finder", App.finder, nil)]))
        case "coding": (Self.coding, Self.windows([("slack", App.slack, Self.frame(0.3, 0.3, 0.4, 0.4)), ("xcode", App.xcode, nil),
                                              ("safari", App.safari, nil), ("terminal", App.terminal, nil), ("chrome", App.chrome, nil)]))
        default: (Self.writing(), Self.windows([("pages", App.pages, Self.frame(0.5, 0, 0.5, 1)),
                                               ("safari", App.safari, Self.frame(0, 0, 0.5, 1)), ("mail", App.mail, Self.frame(0.3, 0.2, 0.4, 0.5))]))
        }
        let forward = try Self.plan(document, windows)
        let reversed = try Self.plan(document, windows.reversed())
        #expect(forward == reversed)
        #expect(try Self.plan(document, windows) == forward)
    }

    /// Every slot has a reason, and every eligible window is either assigned or an extra, never both.
    @Test func everySlotHasAReasonAndEveryWindowIsAccountedFor() throws {
        let windows = Self.windows([
            ("mail", App.mail, nil), ("preview", App.preview, nil), ("safari", App.safari, nil),
            ("finder", App.finder, nil), ("music", App.music, nil)])
        let plan = try Self.plan(Self.homework(), windows)
        #expect(Set(plan.slotReasons.keys) == ["L", "RT", "RB"])
        let accounted = Set(plan.assignments.values).union(plan.extras.keys)
        #expect(accounted == Set(windows.map(\.id)))
        #expect(Set(plan.assignments.values).isDisjoint(with: plan.extras.keys))
    }
}
