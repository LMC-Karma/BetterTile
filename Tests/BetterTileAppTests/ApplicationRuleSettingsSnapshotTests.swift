import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

/// Offline Per-App Rules snapshots. PNGs are written only when `BT_SNAPSHOT_DIR` is set.
@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct ApplicationRuleSettingsSnapshotTests {
    nonisolated static let snapshotDirectory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"]

    enum State: String, CaseIterable {
        case threeRules, empty, oneRule, sixRules, longNames, missingApp, accessibilityOff
    }

    struct Variant: CustomTestStringConvertible {
        var state: State, dark: Bool, width: Double
        var testDescription: String { "\(state.rawValue) \(dark ? "dark" : "light") \(Int(width))" }
    }

    nonisolated static let variants: [Variant] = snapshotDirectory == nil
        ? [Variant(state: .threeRules, dark: false, width: 770)]
        : State.allCases.flatMap { state in
            [false, true].flatMap { dark in [980.0, 1280].map { Variant(state: state, dark: dark, width: $0) } }
        }

    private static let textEdit = ApplicationChoice(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit",
                                                     url: URL(filePath: "/System/Applications/TextEdit.app"))
    private static let safari = ApplicationChoice(bundleIdentifier: "com.apple.Safari", name: "Safari",
                                                   url: URL(filePath: "/Applications/Safari.app"))
    private static let notes = ApplicationChoice(bundleIdentifier: "com.apple.Notes", name: "Notes",
                                                  url: URL(filePath: "/System/Applications/Notes.app"))

    @Test(arguments: [true, false], [980.0, 1070, 1280])
    func settingsWindowKeepsRulesWithinVisibleBounds(permission: Bool, width: Double) throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        system.windows.removeAll()
        system.permission = permission
        let model = makeModel(system: system)
        defer { model.shutdown() }
        let view = NSHostingView(rootView: SettingsTestFactory.makeSettingsView(
            model: model, openSetup: {}, selection: .applicationRules
        )
            .environment(\.accessibilityEnabled, true)
            .environment(\.colorScheme, .light))
        let appearance = NSAppearance(named: .aqua)
        view.appearance = appearance
        let bounds = NSRect(x: 0, y: 0, width: width, height: 640)
        let window = OffscreenTestWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = view
        defer { window.close() }

        func check(_ state: String) throws {
            window.setContentSize(bounds.size)
            turnNativeRunLoop(layout: view)
            let fitted = view.fittingSize
            #expect(fitted.height > 0 && fitted.height <= bounds.height, "\(state): fitting height must fit Settings")
            #expect(fitted.width > 0 && fitted.width <= bounds.width, "\(state): fitting width must fit Settings")
            #expect(view.intrinsicContentSize.width <= bounds.width, "\(state): ideal width must fit Settings")
            let idealHeight = view.intrinsicContentSize.height
            #expect(idealHeight > 0 && idealHeight <= bounds.height, "\(state): ideal height must fit Settings")
            #expect(view.frame.height <= bounds.height, "\(state): content must fit Settings")

            // Read only the test process's hosted controls, without live Accessibility queries.
            func attribute(_ object: NSObject, _ selector: Selector) -> Any? {
                guard object.responds(to: selector) else { return nil }
                return object.perform(selector)?.takeUnretainedValue()
            }
            var seen: Set<ObjectIdentifier> = []
            func elements(_ object: NSObject) -> [NSObject] {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
                let children = attribute(object, #selector(NSAccessibilityProtocol.accessibilityChildren)) as? [NSObject] ?? []
                return [object] + children.flatMap(elements)
            }
            let button = try #require(elements(view).first {
                attribute($0, #selector(NSAccessibilityProtocol.accessibilityLabel)) as? String == "Add Rule…"
            })
            let frame = try #require(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let visible = window.convertToScreen(bounds)
            #expect(frame.width > 0 && frame.height > 0)
            #expect(visible.contains(frame), "\(state): Add Rule must stay visible")
            if Self.snapshotDirectory != nil {
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try write(bitmap, name: "rules-settings-\(state)-permission-\(permission)-\(Int(width))")
            }
        }

        try check("empty")
        model.setRule(.excludeFromBento, for: Self.textEdit.id)
        try check("one-rule")
        // The longest participation title, in the row summary ("Off · …") and the detail picker.
        model.setRuleEnabled(false, for: Self.textEdit.id)
        try check("one-rule-off")
        model.clearRule(for: Self.textEdit.id)
        try check("last-rule-removed")
        #expect(system.frameWriteCounts.isEmpty)
    }

    /// At the minimum Settings width the row's participation summary is too long for one line. It must
    /// wrap rather than cut off "and Tabbed". Text recognition reads only the row, left of its switch,
    /// so the detail picker's copy of the title cannot satisfy the check.
    @Test(arguments: [true, false])
    func ruleRowShowsTheWholeTitleAtTheMinimumWidth(enabled: Bool) async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.setRule(.excludeFromBento, for: Self.textEdit.id)
        model.setRuleEnabled(enabled, for: Self.textEdit.id)
        let host = try SettingsSnapshotHost(SettingsTestFactory.makeSettingsView(
            model: model, openSetup: {}, selection: .applicationRules
        ), dark: false, width: 980, height: 640, fitHeight: false)
        defer { host.close() }
        func switches(_ view: NSView) -> [NSSwitch] {
            ((view as? NSSwitch).map { [$0] } ?? []) + view.subviews.flatMap(switches)
        }
        func rowSwitch() -> NSSwitch? {
            switches(host.view).min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        }
        // The row's switch and the detail's Enabled switch.
        try await waitForSettingsUI("the rule row and its detail", in: host.view) { switches(host.view).count == 2 }
        host.settle()
        let toggle = try #require(rowSwitch())
        let frame = host.view.convert(toggle.bounds, from: toggle)
        let top = host.view.isFlipped ? frame.minY : host.view.bounds.height - frame.maxY
        // The page looks up app names in a task after its first drawing; until then the row shows the bundle
        // identifier. Read the row again, a bounded number of times, until it shows the looked-up name.
        var text = ""
        for attempt in 0 ..< 10 where !text.contains("TextEdit") || text.contains("com.apple") {
            if attempt > 0 { host.settle() }
            let bitmap = try host.render()
            let scale = Double(bitmap.pixelsWide) / host.view.bounds.width
            // From the end of the sidebar to the switch, over the height of a two-line row.
            let row = CGRect(x: 220 * scale, y: (top + frame.height / 2 - 30) * scale,
                             width: (frame.minX - 220) * scale, height: 60 * scale)
            let image = try #require(bitmap.cgImage?.cropping(to: row.integral))
            text = try await snapshotRecognizedLines(in: image).joined(separator: " ")
        }
        #expect(text.contains("TextEdit"), "The crop must hold the rule row: \(text)")
        #expect(text.contains("Exclude from Adaptive"), "\(text)")
        #expect(text.contains("and Tabbed"), "The row must show the whole title: \(text)")
        #expect(text.contains("Off") == !enabled, "\(text)")
    }

    /// Hovering a rule's summary shows the summary, the rule title. The app's bundle identifier must not be
    /// the help text. Reads only this process's hosted views, through their accessibility help.
    @Test(arguments: [true, false])
    func ruleSummaryHelpShowsTheRuleTitle(enabled: Bool) async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.setRule(.excludeFromBento, for: Self.textEdit.id)
        model.setRuleEnabled(enabled, for: Self.textEdit.id)
        let host = try SettingsSnapshotHost(SettingsTestFactory.makeSettingsView(
            model: model, openSetup: {}, selection: .applicationRules
        ).environment(\.accessibilityEnabled, true), dark: false, width: 980, height: 640, fitHeight: false)
        defer { host.close() }
        func attribute(_ object: NSObject, _ selector: Selector) -> String? {
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue() as? String
        }
        func elements(_ object: NSObject, _ seen: inout Set<ObjectIdentifier>) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = object.responds(to: #selector(NSAccessibilityProtocol.accessibilityChildren))
                ? object.perform(#selector(NSAccessibilityProtocol.accessibilityChildren))?.takeUnretainedValue() as? [NSObject] ?? []
                : []
            let subviews = (object as? NSView)?.subviews ?? []
            return [object] + (children + subviews).flatMap { elements($0, &seen) }
        }
        let summary = enabled ? ApplicationRule.excludeFromBento.title : "Off · \(ApplicationRule.excludeFromBento.title)"
        func summaryElement() -> NSObject? {
            var seen: Set<ObjectIdentifier> = []
            // SwiftUI exposes a Text's string as its accessibility value.
            return elements(host.view, &seen).first {
                attribute($0, #selector(NSAccessibilityProtocol.accessibilityValue)) == summary
            }
        }
        try await waitForSettingsUI("the rule summary", in: host.view) { summaryElement() != nil }
        let element = try #require(summaryElement())
        let help = attribute(element, #selector(NSAccessibilityProtocol.accessibilityHelp))
        #expect(help == summary, "The summary's help must be its text, got \(help ?? "nil")")
        #expect(help?.contains(Self.textEdit.id) != true, "The bundle identifier must not be the help text")
    }

    @Test(arguments: variants)
    func rendersRules(variant: Variant) throws {
        let system = FakeAppWindowSystem()
        system.windows[0].bundleIdentifier = Self.notes.id
        system.windows[0].title = "A note for today"
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.singleWindowPlacement = nil
        switch variant.state {
        case .threeRules, .accessibilityOff:
            model.configuration.applicationRules.set(.excludeFromBento, for: Self.safari.id)
            model.configuration.applicationRules.set(.ignoreEverywhere, for: Self.textEdit.id)
            model.configuration.applicationRules.set(.excludeFromBento, for: Self.notes.id)
            model.configuration.applicationRules.setEnabled(false, for: Self.notes.id)
            model.watchdog()
        case .oneRule:
            model.configuration.applicationRules.set(.excludeFromBento, for: Self.textEdit.id)
        case .sixRules, .longNames:
            for index in 0..<6 {
                model.configuration.applicationRules.set(.excludeFromBento, for: "com.example.app-\(index)")
            }
        case .empty:
            break
        case .missingApp:
            model.configuration.applicationRules.set(.excludeFromBento, for: "com.example.NotInstalled")
        }
        if variant.state == .accessibilityOff {
            system.permission = false
            _ = model.refreshPermission()
        }
        let configuration = model.configuration
        let fixtureApps = Dictionary(uniqueKeysWithValues: (0..<6).map { index in
            let id = "com.example.app-\(index)"
            let name = variant.state == .longNames
                ? "Application \(index + 1) with an exceptionally long descriptive name for professional projects"
                : "Application \(index + 1)"
            return (id, ApplicationChoice(bundleIdentifier: id, name: name, url: Self.textEdit.url))
        })
        let page = ApplicationRuleSettings(model: model, resolveApplication: { id in
            fixtureApps[id] ?? [Self.textEdit, Self.safari, Self.notes].first { $0.id == id }
        })
        let content = VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(destination: .applicationRules)
                .padding(.horizontal, SettingsSpacing.s6)
                .padding(.top, SettingsSpacing.s6)
                .padding(.bottom, SettingsSpacing.s4)
            page
        }
        let host = try SettingsSnapshotHost(content, dark: variant.dark,
                                            width: variant.width, height: 640, fitHeight: false)
        defer { host.close() }
        let bitmap = try host.render()
        #expect(bitmap.pixelsWide >= Int(variant.width))
        #expect(bitmap.pixelsHigh >= 640)
        #expect(model.configuration == configuration, "Rendering must not change rules")
        #expect(system.frameWriteCounts.isEmpty)
        try write(bitmap, name: "rules-\(variant.state.rawValue)-\(variant.dark ? "dark" : "light")-\(Int(variant.width))")
    }

    struct SheetVariant: CustomTestStringConvertible {
        var participation: Bool, dark: Bool
        var testDescription: String { "\(participation ? "participation" : "picker") \(dark ? "dark" : "light")" }
    }

    nonisolated static let sheetVariants: [SheetVariant] = snapshotDirectory == nil
        ? [SheetVariant(participation: true, dark: false)]
        : [false, true].flatMap { participation in
            [false, true].map { SheetVariant(participation: participation, dark: $0) }
        }

    @Test(arguments: sheetVariants)
    func rendersAddRuleSheet(variant: SheetVariant) async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        let recent = RecentApplications(defaults: MemoryDefaults())
        recent.record(Self.textEdit.id)
        let installed = [Self.textEdit, Self.safari, Self.notes]
        let running = [Self.safari]
        let sheet = AddApplicationRuleSheet(makePicker: { exclusions, onChoose in
            ApplicationPicker(exclusions: exclusions, installedApplications: { installed },
                              runningApplications: { running }, recentApplications: recent,
                              resolveApplication: { _ in nil }, onChoose: onChoose)
        }, model: model, application: variant.participation ? Self.textEdit : nil, onAdd: { _ in
            Issue.record("Rendering must not choose an app")
        })
        let host = try SettingsSnapshotHost(sheet, dark: variant.dark, width: 420, height: 520, fitHeight: false)
        defer { host.close() }
        let bitmap = try host.render()
        #expect(bitmap.pixelsWide >= 420)
        #expect(bitmap.pixelsHigh >= 520)
        #expect(model.configuration.applicationRules.isEmpty)
        if variant.participation {
            // The panel has a fixed size, so its bitmap size proves nothing about fit. Read the drawn text:
            // the longest title with its badge, the last choice and the buttons must all be visible.
            let lines = try await snapshotRecognizedLines(in: #require(bitmap.cgImage))
            let text = lines.joined(separator: " ")
            for expected in ["Exclude from Adaptive and Tabbed", "Suggested", "If a window already belongs to a Tabbed pane",
                             "Manage Normally", "Back", "Cancel", "Add Rule"] {
                #expect(text.contains(expected), "\(expected) must be visible: \(lines)")
            }
        }
        try write(bitmap, name: "rules-add-\(variant.participation ? "participation" : "picker")-\(variant.dark ? "dark" : "light")")
    }

    private func write(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let directory = Self.snapshotDirectory else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
