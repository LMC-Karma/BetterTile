import Foundation
import Testing
@testable import BetterTileCore

/// Seeded random edits, file round trips, and Apply plans. Each failure names its seed and step.
@Suite struct SavedLayoutStressTests {
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func chance(_ p: Double) -> Bool { unit() < p }
        mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }
    }

    private static let bundles = ["com.example.a", "com.example.b", "com.example.c", "com.example.d"]

    /// Random ratios that sum to 1. Some are extreme.
    private func ratios(_ count: Int, _ g: inout Generator) -> [Double] {
        var raw = (0..<count).map { _ in g.chance(0.15) ? 1e-5 : 0.05 + g.unit() }
        let sum = raw.reduce(0, +)
        raw = raw.map { $0 / sum }
        raw[count - 1] = 1 - raw.dropLast().reduce(0, +)
        return raw
    }

    private func randomTree(leaves: Int, axis: SplitAxis, _ g: inout Generator) -> SavedLayoutNode {
        guard leaves > 1 else { return .empty }
        let count = g.int(2...min(leaves, 3))
        var sizes = Array(repeating: 1, count: count)
        for _ in 0..<(leaves - count) { sizes[g.int(0...(count - 1))] += 1 }
        let other: SplitAxis = axis == .vertical ? .horizontal : .vertical
        return .split(axis: axis, ratios: ratios(count, &g),
                      children: sizes.map { randomTree(leaves: $0, axis: other, &g) })
    }

    /// Fills empty leaves with slots (Adaptive) or groups (Tabbed). Some stay empty.
    private func randomDocument(_ g: inout Generator) -> SavedLayoutDocument {
        let mode: LayoutMode = g.pick([.bento, .tabbed, .manual])
        var document = SavedLayoutDocument(name: "Stress", mode: mode, paneGap: Double(g.int(0...12)))
        var counter = 0
        func fresh(_ prefix: String) -> String { counter += 1; return "\(prefix)-\(counter)" }
        if mode == .manual {
            for _ in 0..<g.int(0...6) {
                let slot = fresh("slot")
                document.slots.append(.init(id: slot, bundleID: g.pick(Self.bundles)))
                let w = 0.05 + g.unit() * 0.95, h = 0.05 + g.unit() * 0.95
                let rect = NormalizedRect(x: g.unit() * (1 - w), y: g.unit() * (1 - h), width: w, height: h)
                if g.chance(0.8) { document.windows.append(.init(slot: slot, rect: rect)) }
                else { document.floats.append(.init(slot: slot, rect: rect)) }
            }
            return document
        }
        func fill(_ node: SavedLayoutNode) -> SavedLayoutNode {
            switch node {
            case let .split(axis, ratios, children): return .split(axis: axis, ratios: ratios, children: children.map(fill))
            default:
                guard g.chance(0.8) else { return .empty }
                if mode == .bento {
                    let slot = fresh("slot")
                    document.slots.append(.init(id: slot, bundleID: g.pick(Self.bundles)))
                    return .slot(slot)
                }
                let group = fresh("group")
                let tabs = (0..<g.int(0...2)).map { _ in fresh("slot") }
                for tab in tabs { document.slots.append(.init(id: tab, bundleID: g.pick(Self.bundles))) }
                document.groups.append(.init(id: group, slots: tabs, selected: tabs.isEmpty ? nil : g.pick(tabs)))
                return .group(group)
            }
        }
        document.layout = fill(randomTree(leaves: g.int(1...6), axis: g.pick([.vertical, .horizontal]), &g))
        for _ in 0..<(g.chance(0.3) ? g.int(1...2) : 0) {
            let slot = fresh("float")
            document.slots.append(.init(id: slot, bundleID: g.pick(Self.bundles)))
            document.floats.append(.init(slot: slot, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3 + g.unit() * 0.5, height: 0.4)))
        }
        return document
    }

    private func expectSharesSumToOne(_ node: SavedLayoutNode?, _ context: String) {
        guard case let .split(_, ratios, children)? = node else { return }
        #expect(abs(ratios.reduce(0, +) - 1) <= 1e-6, "\(context): ratios \(ratios)")
        #expect(ratios.allSatisfy { $0 > 0 && $0 < 1 }, "\(context): ratios \(ratios)")
        children.forEach { expectSharesSumToOne($0, context) }
    }

    @Test func randomDocumentsRoundTripThroughTheFileFormat() throws {
        for seed in 0..<400 {
            var g = Generator(state: UInt64(seed))
            let document = randomDocument(&g)
            let issues = SavedLayoutValidator.validate(document)
            #expect(issues.isEmpty, "seed \(seed): generator built an invalid document \(issues)")
            guard issues.isEmpty else { continue }
            let data = try SavedLayoutValidator.encode(document)
            let decoded = try SavedLayoutValidator.decode(data)
            #expect(decoded == document, "seed \(seed)")
            #expect(try SavedLayoutValidator.encode(decoded) == data, "seed \(seed): encoding is not stable")
            // Corrupt bytes: the decoder must reject the file or return a valid document, never crash.
            for _ in 0..<20 {
                var bytes = [UInt8](data)
                for _ in 0..<g.int(1...4) {
                    let index = g.int(0...(bytes.count - 1))
                    switch g.int(0...3) {
                    case 0: bytes[index] = UInt8(truncatingIfNeeded: g.next())
                    case 1: bytes.remove(at: index)
                    case 2: bytes.insert(g.pick(Array("{}[],:\"0e9-".utf8)), at: index)
                    default: bytes = Array(bytes.prefix(index))
                    }
                    if bytes.isEmpty { bytes = [123] }
                }
                if let mutated = try? SavedLayoutValidator.decode(Data(bytes)) {
                    #expect(SavedLayoutValidator.validate(mutated).isEmpty, "seed \(seed): decoded an invalid document")
                }
            }
        }
    }

    @Test func randomCanvasEditsKeepTheDocumentValid() throws {
        for seed in 0..<300 {
            var g = Generator(state: UInt64(seed) &+ 10_000)
            var document = randomDocument(&g)
            guard document.mode != .manual else { continue }
            var counter = 0
            let makeID: (String) -> String = { counter += 1; return "\($0)-new-\(counter)" }
            for step in 0..<40 {
                guard let root = document.layout else { break }
                let leaves = SavedLayoutCanvas.leaves(root, paneGap: document.paneGap)
                let dividers = SavedLayoutCanvas.dividers(root, paneGap: document.paneGap)
                let leaf = g.pick(leaves).path
                let extreme = g.pick([-5, 0, 1e-9, 0.0001, 0.5, 0.9999, 1, 7, g.unit()])
                var outcome: SavedLayoutOutcome?
                var tree: SavedLayoutNode?
                let kind = g.int(0...8)
                switch kind {
                case 0: outcome = SavedLayoutCanvas.splitting(leaf, axis: g.pick([.vertical, .horizontal]), in: document)
                case 1: outcome = SavedLayoutCanvas.removingPane(leaf, from: document)
                case 2:
                    if let node = SavedLayoutCanvas.node(at: leaf, in: root) {
                        outcome = SavedLayoutCanvas.removingApps(SavedLayoutCanvas.slotIDs(in: node, document: document), from: document)
                    }
                case 3:
                    if let d = dividers.isEmpty ? nil : g.pick(dividers) {
                        tree = try SavedLayoutCanvas.movingDivider(in: root, path: d.path, index: d.index,
                            to: d.before + extreme * d.pair, paneGap: document.paneGap)
                    }
                case 4:
                    if let d = dividers.isEmpty ? nil : g.pick(dividers) {
                        tree = try SavedLayoutCanvas.equalizingDivider(in: root, path: d.path, index: d.index, paneGap: document.paneGap)
                    }
                case 5:
                    if let d = dividers.isEmpty ? nil : g.pick(dividers),
                       case let .split(_, ratios, _)? = SavedLayoutCanvas.node(at: d.path, in: root) {
                        tree = try? SavedLayoutCanvas.settingShare(in: root, path: d.path, child: g.int(0...(ratios.count - 1)),
                            to: extreme, paneGap: document.paneGap)
                    }
                case 6: outcome = SavedLayoutCanvas.applyingPreset(g.pick([.single, .columns, .rows, .focus, .grid]), to: document)
                default:
                    let item: SavedLayoutDragItem = g.chance(0.5) ? .pane(g.pick(leaves).path) : .app(bundleID: g.pick(Self.bundles))
                    let side = g.pick(SavedLayoutSide.allCases)
                    let target: SavedLayoutDropTarget = g.pick([.pane(leaf), .paneEdge(leaf, side), .canvasEdge(side), .palette])
                    outcome = SavedLayoutCanvas.plan(item, onto: target, in: document, makeID: makeID).outcome
                }
                var next = document
                if let tree { next.layout = tree }
                else if case let .change(edit)? = outcome { next = edit.document }
                else { continue }
                let context = "seed \(seed) step \(step) kind \(kind)"
                let issues = SavedLayoutValidator.validate(next)
                #expect(issues.isEmpty, "\(context): \(issues) in \(String(describing: next.layout)) from \(String(describing: root))")
                expectSharesSumToOne(next.layout, context)
                guard issues.isEmpty else { break }
                document = next
            }
        }
    }

    @Test func randomPlansAssignEachSlotOnceAndEachWindowOnce() throws {
        let workArea = BTRect(x: 0, y: 25, width: 1440, height: 875)
        for seed in 0..<400 {
            var g = Generator(state: UInt64(seed) &+ 20_000)
            let document = randomDocument(&g)
            var windows: [SavedLayoutEligibleWindow] = []
            for bundle in Self.bundles + ["com.example.other"] {
                for index in 0..<g.int(0...3) {
                    let minimum = g.chance(0.2) ? BTSize(width: 400 + g.unit() * 800, height: 300 + g.unit() * 500)
                                                : BTSize(width: 120, height: 80)
                    windows.append(.init(id: WindowID(rawValue: "\(bundle)#\(index)"), bundleID: bundle,
                        frame: BTRect(x: g.unit() * 800, y: 25 + g.unit() * 400, width: 300 + g.unit() * 500, height: 200 + g.unit() * 400),
                        constraints: WindowConstraints(minimumSize: minimum, isResizable: !g.chance(0.1))))
                }
            }
            // Random explicit choices for some slots, as the window chooser would send.
            var choices: [String: WindowID] = [:]
            var taken = Set<WindowID>()
            for slot in document.slots where g.chance(0.3) {
                if let window = windows.filter({ $0.bundleID == slot.preferredAppForFixture && !taken.contains($0.id) }).first {
                    choices[slot.id] = window.id; taken.insert(window.id)
                }
            }
            let context = "seed \(seed) mode \(document.mode)"
            let plan: SavedLayoutApplyPlan
            do {
                plan = try SavedLayoutPlanner.plan(document, in: workArea, windows: windows, choices: choices,
                                                   currentSession: g.chance(0.5) ? .manual : nil)
            } catch is SavedLayoutValidationError { continue }
            let assigned = Set(plan.assignments.keys)
            let unresolved = plan.emptySlots
            #expect(assigned.count + unresolved.count == document.slots.count, "\(context): counts")
            #expect(assigned.isDisjoint(with: unresolved), "\(context): a slot is both placed and unresolved")
            #expect(Set(plan.assignments.values).count == plan.assignments.count, "\(context): a window has two slots")
            for (slot, window) in choices { #expect(plan.assignments[slot] == window, "\(context): choice ignored") }
            let placed = plan.placements.map(\.windowID)
            #expect(Set(placed).count == placed.count, "\(context): a window is placed twice")
            let tabbedExtras = plan.extras.compactMap { id, destination -> WindowID? in
                if case .tab = destination { return id }
                if destination == .addedAsPane { return id }
                return nil
            }
            #expect(Set(placed).isSubset(of: Set(plan.assignments.values).union(tabbedExtras)), "\(context): unaccounted window placed")
            #expect(Set(plan.unmatchedWindowIDs).isDisjoint(with: Set(plan.assignments.values)), "\(context)")
            for placement in plan.placements {
                #expect(placement.frame.size.width.isFinite && placement.frame.size.height.isFinite, "\(context)")
            }
            if case let .bento(state) = plan.targetSession, let root = state.root {
                func check(_ node: BentoNode) {
                    if case let .partition(p) = node {
                        #expect(abs(p.ratios.reduce(0, +) - 1) <= 1e-6, "\(context): fitted ratios \(p.ratios)")
                        p.children.forEach(check)
                    }
                }
                check(root)
            }
        }
    }
}
