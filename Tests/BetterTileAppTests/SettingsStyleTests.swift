import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication) struct SettingsStyleTokenTests {
    @Test func radiiAreConcentric() {
        #expect(SettingsRadius.window == 16)
        #expect(SettingsRadius.panel == 12)
        #expect(SettingsRadius.sidebar == SettingsRadius.window - SettingsMetrics.sidebarInset)
        #expect(SettingsRadius.sidebar == 10)
        #expect(SettingsRadius.inner == 8)
        #expect(SettingsRadius.control == 6)
        #expect(SettingsRadius.mini == 4)
    }

    @Test func spacingIsOnTheFourPointGrid() {
        let steps = [SettingsSpacing.s1, SettingsSpacing.s2, SettingsSpacing.s3, SettingsSpacing.s4,
                     SettingsSpacing.s5, SettingsSpacing.s6, SettingsSpacing.s8]
        #expect(steps == [4, 8, 12, 16, 20, 24, 32])
    }

    @Test func stepperValuesStayInsideTheirRange() {
        #expect(StepperRow.clamped(5, to: 0 ... 12) == 5)
        #expect(StepperRow.clamped(-3, to: 0 ... 12) == 0)
        #expect(StepperRow.clamped(40, to: 0 ... 12) == 12)
        #expect(StepperRow.clamped(.nan, to: 2 ... 12) == 2)
        #expect(StepperRow.clamped(.infinity, to: 2 ... 12) == 2)
    }
}

@MainActor @Suite(.appTestApplication, .serialized) struct SettingsStyleBehaviorTests {
    @Test func stepperValuesAreSpokenWithTheirUnit() {
        #expect(StepperRow.spokenValue(5, unit: "pt") == "5 points")
        #expect(StepperRow.spokenValue(1, unit: "pt") == "1 point")
        #expect(StepperRow.spokenValue(0.12, unit: "s", fractionDigits: 2) == "0.12 seconds")
        #expect(StepperRow.spokenValue(80, unit: "%") == "80 percent")
        #expect(StepperRow.spokenValue(3, unit: "") == "3")
    }

    @Test func rowControlsAreNamedByTheRowTitle() throws {
        let content = SettingsGroup {
            SettingsRow("Launch at login") {
                Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow("New window side", caption: "Where a new window joins the layout.") {
                Picker("", selection: .constant(0)) { Text("Automatic").tag(0) }.labelsHidden()
            }
            StepperRow("Pane gap", value: .constant(5), in: 0 ... 12, unit: "pt")
        }
        let host = try SettingsSnapshotHost(content.environment(\.accessibilityEnabled, true), dark: false, width: 500)
        defer { host.close() }
        let elements = accessibilityElements(host.view)
        let toggle = try #require(elements.first { role($0) == NSAccessibility.Role.checkBox.rawValue })
        #expect(titleElementValue(toggle) == "Launch at login")
        let popUp = try #require(elements.first { role($0) == NSAccessibility.Role.popUpButton.rawValue })
        #expect(titleElementValue(popUp) == "New window side")
        // The number field and stepper reach VoiceOver as one adjustable element.
        let stepper = try #require(elements.first { role($0) == NSAccessibility.Role.slider.rawValue })
        #expect(string(stepper, #selector(NSAccessibilityProtocol.accessibilityLabel)) == "Pane gap")
        #expect(string(stepper, #selector(NSAccessibilityProtocol.accessibilityValueDescription)) == "5 points")
    }

    @Test(arguments: [true, false])
    func resetIsDisabledAtDefaults(isAtDefault: Bool) throws {
        let footer = GroupFooter(help: "Help text.", isAtDefault: isAtDefault, reset: {})
        let host = try SettingsSnapshotHost(footer.environment(\.accessibilityEnabled, true), dark: false, width: 500)
        defer { host.close() }
        let button = try #require(accessibilityElements(host.view).first {
            string($0, #selector(NSAccessibilityProtocol.accessibilityLabel)) == "Reset to Default"
        })
        let selector = #selector(NSAccessibilityProtocol.isAccessibilityEnabled)
        typealias Call = @convention(c) (NSObject, Selector) -> Bool
        let enabled = unsafeBitCast(button.method(for: selector), to: Call.self)(button, selector)
        #expect(enabled == !isAtDefault)
    }

    @Test func noticesInsideAGroupUseTheInnerRadius() throws {
        #expect(NoticeBanner.cornerRadius(insideGroup: false) == SettingsRadius.panel)
        #expect(NoticeBanner.cornerRadius(insideGroup: true) == SettingsRadius.inner)
        let recorded = InsideGroupRecord()
        let content = VStack {
            InsideGroupProbe(name: "outside", record: recorded)
            SettingsGroup { InsideGroupProbe(name: "inside", record: recorded) }
        }
        let host = try SettingsSnapshotHost(content, dark: false, width: 300)
        defer { host.close() }
        #expect(recorded.values == ["outside": false, "inside": true])
    }

    @Test(arguments: [1, 3])
    func groupsDrawOneSeparatorBetweenEachPairOfRows(rows: Int) throws {
        let content = SettingsGroup {
            ForEach(0 ..< rows, id: \.self) { _ in Color.clear.frame(height: 40) }
        }
        .padding(20)
        let host = try SettingsSnapshotHost(content, dark: false, width: 300)
        defer { host.close() }
        let bitmap = try host.render()
        let scale = Double(bitmap.pixelsWide) / 300
        // Scan down the middle of the group, inside its border, and count the darker runs.
        let x = Int(150 * scale)
        var runs = 0
        var inRun = false
        for y in Int(24 * scale) ..< Int((20 + Double(rows) * 40 - 4) * scale) {
            let white = (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1) > 0.99
            if !white, !inRun { runs += 1 }
            inRun = !white
        }
        #expect(runs == rows - 1)
    }
}

@MainActor private final class InsideGroupRecord {
    var values: [String: Bool] = [:]
}

private struct InsideGroupProbe: View {
    let name: String
    let record: InsideGroupRecord
    @Environment(\.settingsInsideGroup) private var insideGroup

    var body: some View {
        Color.clear.frame(height: 10).onAppear { record.values[name] = insideGroup }
    }
}

@MainActor private func accessibilityElements(_ root: NSObject) -> [NSObject] {
    var seen: Set<ObjectIdentifier> = []
    func walk(_ object: NSObject) -> [NSObject] {
        guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
        let children = [#selector(NSAccessibilityProtocol.accessibilityChildren),
                        #selector(NSAccessibilityProtocol.accessibilityChildrenInNavigationOrder)].flatMap { selector -> [NSObject] in
            guard object.responds(to: selector) else { return [] }
            return object.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? []
        }
        return [object] + children.flatMap(walk)
    }
    return walk(root)
}

@MainActor private func string(_ object: NSObject, _ selector: Selector) -> String? {
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue() as? String
}

@MainActor private func role(_ object: NSObject) -> String? {
    string(object, #selector(NSAccessibilityProtocol.accessibilityRole))
}

/// The text of the element that names `object` for VoiceOver (its AXTitleUIElement).
@MainActor private func titleElementValue(_ object: NSObject) -> String? {
    let selector = #selector(NSAccessibilityProtocol.accessibilityTitleUIElement)
    guard object.responds(to: selector),
          let title = object.perform(selector)?.takeUnretainedValue() as? NSObject
    else { return nil }
    return string(title, #selector(NSAccessibilityProtocol.accessibilityValue))
        ?? string(title, #selector(NSAccessibilityProtocol.accessibilityLabel))
}

/// Offline snapshots of the Settings design-system components and of each settings page.
///
/// A plain test run renders one component sample as a smoke test. Set `BT_SNAPSHOT_DIR` to write
/// PNGs for the full matrix: light and dark, the content width of a 980 pt window and of a wide window,
/// and, for Window Layout, Liquid Glass on and off.
@MainActor @Suite(.appTestApplication, .serialized) struct SettingsStyleSnapshotTests {
    nonisolated static let snapshotDirectory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"]
    /// Detail widths beside the 210 pt sidebar in a 980 pt window and in a 1280 pt window.
    nonisolated static let contentWidths: [Double] = [770, 1070]

    struct Variant: CustomTestStringConvertible {
        var dark: Bool, width: Double
        var testDescription: String { "\(dark ? "dark" : "light") \(Int(width))" }
    }

    nonisolated static let componentVariants: [Variant] = snapshotDirectory == nil
        ? [Variant(dark: false, width: 770)]
        : [false, true].flatMap { dark in contentWidths.map { Variant(dark: dark, width: $0) } }

    @Test(arguments: componentVariants)
    func rendersEveryComponent(variant: Variant) throws {
        let host = try SettingsSnapshotHost(SettingsStyleSample(), dark: variant.dark, width: variant.width)
        defer { host.close() }
        let bitmap = try host.render()
        #expect(bitmap.pixelsWide >= Int(variant.width))
        #expect(host.view.fittingSize.height > 600)
        try write(bitmap, name: "components-\(variant.testDescription.replacingOccurrences(of: " ", with: "-"))")
    }

    enum Page: String, CaseIterable {
        case general, windowLayout, snapZones, menuBar, layoutWheel, applicationRules
    }

    @Test(.enabled(if: snapshotDirectory != nil, "Writes page PNGs only when BT_SNAPSHOT_DIR is set."))
    func rendersEveryPage() throws {
        for page in Page.allCases {
            for dark in [false, true] {
                for width in Self.contentWidths {
                    for glass in page == .windowLayout ? [true, false] : [true] {
                        let model = makeModel(system: FakeAppWindowSystem())
                        defer { model.shutdown() }
                        model.updateConfiguration { $0.overlayAppearance.useLiquidGlass = glass }
                        let host = try SettingsSnapshotHost(pageView(page, model: model), dark: dark, width: width, height: 1800)
                        defer { host.close() }
                        let suffix = page == .windowLayout ? (glass ? "-glass" : "-solid") : ""
                        try write(host.render(), name: "page-\(page.rawValue)-\(dark ? "dark" : "light")-\(Int(width))\(suffix)")
                    }
                }
            }
        }
    }

    @Test(.enabled(if: snapshotDirectory != nil, "Writes window PNGs only when BT_SNAPSHOT_DIR is set."))
    func rendersTheSettingsWindow() throws {
        for dark in [false, true] {
            for size in [NSSize(width: 980, height: 640), NSSize(width: 1280, height: 800)] {
                let model = makeModel(system: FakeAppWindowSystem())
                defer { model.shutdown() }
                let host = try SettingsSnapshotHost(SettingsTestFactory.makeSettingsView(model: model, openSetup: {}), dark: dark,
                                            width: size.width, height: size.height, fitHeight: false)
                defer { host.close() }
                try write(host.render(), name: "window-general-\(dark ? "dark" : "light")-\(Int(size.width))")
            }
        }
    }

    private func pageView(_ page: Page, model: BetterTileModel) -> AnyView {
        switch page {
        case .general:
            AnyView(SettingsTestFactory.makeGeneralSettingsPage(
                model: model, openSetup: {}, search: "", openShortcuts: {}, openSnapZones: {}
            ))
        case .windowLayout: AnyView(WindowLayoutSettings(model: model))
        case .snapZones: AnyView(ZoneSettings(model: model))
        case .menuBar: AnyView(MenuBarSettings(model: model))
        case .layoutWheel: AnyView(LayoutWheelSettings(model: model))
        case .applicationRules: AnyView(ApplicationRuleSettings(model: model))
        }
    }

    private func write(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let directory = Self.snapshotDirectory else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent(name + ".png"))
    }
}

/// Hosts a SwiftUI view in a borderless window so it can render offline. Page snapshot tests share it.
@MainActor struct SettingsSnapshotHost {
    let view: NSHostingView<AnyView>
    let window: NSWindow

    /// - Parameter fitHeight: Shrinks the window to the view's fitting height (at least 200 pt).
    init(_ content: some View, dark: Bool, width: Double, height: Double = 1600, fitHeight: Bool = true) throws {
        _ = NSApplication.shared
        let rooted = content
            .frame(width: width)
            .frame(maxHeight: fitHeight ? nil : height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        view = NSHostingView(rootView: AnyView(rooted))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.appearance = appearance
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window = OffscreenTestWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = view
        settle()
        if fitHeight {
            let fitted = view.fittingSize.height
            if fitted > 0, fitted < height {
                window.setContentSize(NSSize(width: width, height: max(200, fitted)))
                view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
                settle()
            }
        }
    }

    /// Several layout passes with the run loop turning between them, so `.task` and geometry work land.
    func settle() {
        turnNativeRunLoop(layout: view)
    }

    func render() throws -> NSBitmapImageRep {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        let appearance = view.appearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        return bitmap
    }

    func close() {
        window.close()
    }
}

/// A sample page that uses every component once, for the design-system snapshot.
private struct SettingsStyleSample: View {
    @State private var launchAtLogin = true
    @State private var showDockIcon = false
    @State private var appearance = 0
    @State private var paneGap = 1.0
    @State private var dividerWidth = 1

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s5) {
            SettingsPageHeader(title: "Design System", subtitle: "Every component in the Settings style, drawn at real size.")
            NoticeBanner(
                .problem,
                title: "Accessibility access needed",
                message: "Allow BetterTile to inspect, move and resize windows. macOS shows its prompt only once.",
                action: .init(title: "Request Access…", isPrimary: true) {}
            )
            HStack(alignment: .top, spacing: SettingsSpacing.s3) {
                StatusCard("Accessibility", systemImage: "checkmark.circle.fill", value: "Granted",
                           caption: "Windows can move and resize.", tint: SettingsColor.green)
                StatusCard("Default mode", systemImage: "rectangle.split.2x2", value: "Adaptive",
                           caption: "New desktops start here.", tint: .accentColor)
                StatusCard("Updates", systemImage: "arrow.clockwise", value: "1.9 available",
                           caption: "Released Oct 18.", tint: SettingsColor.gray, valueTint: SettingsColor.orange)
                StatusCard("Shortcuts", systemImage: "keyboard", value: "On",
                           caption: "41 actions.", tint: SettingsColor.purple)
            }
            SettingsGroup("Startup", aside: "4 settings") {
                SettingsRow("Launch at login") {
                    Toggle("Launch at login", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Show Dock icon", caption: "Also lists BetterTile in Cmd-Tab.") {
                    Toggle("Show Dock icon", isOn: $showDockIcon).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                StepperRow("Pane gap", caption: "Space between Adaptive panes.", value: $paneGap, in: 0 ... 12, unit: "pt")
                NoticeBanner(.info, title: "Notice inside a group",
                             message: "Uses the inner radius (8 pt) instead of the panel radius (12 pt).")
                    .padding(SettingsSpacing.s3)
            } footer: {
                GroupFooter(help: "Help text, left aligned.", reset: {})
            }
            SettingsGroup("Divider width") {
                LazyVGrid(columns: PictureChoice<EmptyView>.gridColumns, spacing: SettingsSpacing.s3) {
                    ForEach(Array(["Thin", "Standard", "Wide"].enumerated()), id: \.offset) { index, title in
                        PictureChoice(title, detail: "\(4 + index * 4) pt", badge: index == 1 ? "Today" : nil,
                                      isSelected: dividerWidth == index, action: { dividerWidth = index }) {
                            Capsule()
                                .fill(SettingsColor.fillStrong)
                                .frame(width: CGFloat(4 + index * 4))
                                .padding(.vertical, SettingsSpacing.s2)
                        }
                    }
                }
                .padding(SettingsSpacing.s3)
            } footer: {
                GroupFooter(help: "Picture choices replace sliders for a few values.", isAtDefault: true, reset: {})
            }
            HStack(spacing: SettingsSpacing.s2) {
                ForEach(SettingsDestination.allCases) { destination in
                    SidebarTile(icon: destination.icon, color: destination.tileColor)
                }
                HelpText("Sidebar tiles: 20 pt, mini radius (4 pt).")
            }
            NoticeBanner(.warning, title: "macOS tiling also reacts to drags",
                         message: "Turn off macOS window tiling to avoid two previews.",
                         action: .init(title: "Open Desktop & Dock Settings…") {},
                         secondaryAction: .init(title: "Dismiss") {})
        }
        .padding(28)
    }
}
