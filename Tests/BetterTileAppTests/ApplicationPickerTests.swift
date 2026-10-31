import AppKit
import SwiftUI
import BetterTileMacOS
import Foundation
import Synchronization
import Testing
@testable import BetterTileApp

private func appChoice(_ id: String, _ name: String, path: String? = nil) -> ApplicationChoice {
    ApplicationChoice(bundleIdentifier: id, name: name, url: URL(filePath: path ?? "/Applications/\(name).app"))
}

@Test(.appTestApplication) func appCatalogEnumeratesUtilitiesAndSkipsMalformedAndNestedBundles() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func bundle(_ path: String, metadata: [String: String]) throws {
        let contents = root.appending(path: path).appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var metadata = metadata
        metadata["CFBundleExecutable"] = "TestExecutable"
        let executable = contents.appending(path: "MacOS/TestExecutable")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }
    try bundle("Editor.app", metadata: ["CFBundleIdentifier": "test.editor", "CFBundleDisplayName": "Editor Display"])
    try bundle("Utilities/Helper.app", metadata: ["CFBundleIdentifier": "test.helper", "CFBundleName": "Utility"])
    try bundle("Editor.app/Contents/Helpers/Private.app", metadata: ["CFBundleIdentifier": "test.nested"])
    try bundle("MissingIdentifier.app", metadata: [:])
    try bundle("BlankIdentifier.app", metadata: ["CFBundleIdentifier": "  "])
    try bundle("Fallback.app", metadata: ["CFBundleIdentifier": "test.fallback"])
    try bundle(".Hidden.app", metadata: ["CFBundleIdentifier": "test.hidden"])
    try bundle("NotAnApp.bundle", metadata: ["CFBundleIdentifier": "test.notapp"])
    let malformed = root.appending(path: "Malformed.app/Contents")
    try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
    try Data("not a plist".utf8).write(to: malformed.appending(path: "Info.plist"))

    let apps = ApplicationCatalog.enumerate(directories: [root, root, root.appending(path: "Absent")])
    #expect(apps.map(\.id) == ["test.editor", "test.fallback", "test.helper"])
    // Finder names follow the bundle folders for these unregistered fixtures.
    #expect(apps.map(\.name) == ["Editor", "Fallback", "Helper"])
    #expect(apps.last?.url.resolvingSymlinksInPath().path == root.appending(path: "Utilities/Helper.app").resolvingSymlinksInPath().path)
    #expect(ApplicationCatalog.application(at: root.appending(path: "NotAnApp.bundle")) == nil)
    #expect(ApplicationCatalog.application(at: root.appending(path: "Malformed.app")) == nil)
}

private struct CatalogFixture {
    enum Executable { case regular, missing, nonExecutable, directory, symlink }
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    func application(_ path: String, executable kind: Executable = .regular, wrapper: Bool = false) throws -> URL {
        let url = root.appending(path: path)
        let contents = wrapper ? url.appending(path: "Wrapper/Inner.app") : url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let executable = contents.appending(path: wrapper ? "TestExecutable" : "MacOS/TestExecutable")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch kind {
        case .missing: break
        case .directory:
            try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: true)
        case .regular, .nonExecutable, .symlink:
            let target = kind == .symlink ? contents.appending(path: "RealExecutable") : executable
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: kind == .nonExecutable ? 0o644 : 0o755],
                                                 ofItemAtPath: target.path)
            if kind == .symlink {
                try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: target)
            }
        }
        let metadata = ["CFBundleIdentifier": "test.fixture", "CFBundleName": "Fixture",
                        "CFBundleExecutable": "TestExecutable", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        if wrapper {
            try FileManager.default.createSymbolicLink(atPath: url.appending(path: "WrappedBundle").path,
                                                       withDestinationPath: "Wrapper/Inner.app")
        }
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test(.appTestApplication, arguments: [CatalogFixture.Executable.missing, .nonExecutable, .directory])
private func appCatalogRejectsInvalidExecutables(executable: CatalogFixture.Executable) throws {
    let fixture = CatalogFixture()
    defer { fixture.remove() }
    let url = try fixture.application("Invalid.app", executable: executable)
    #expect(ApplicationCatalog.application(at: url) == nil)
    #expect(ApplicationCatalog.enumerate(directories: [fixture.root]).isEmpty)
}

@Test(.appTestApplication) func appCatalogAcceptsSymlinkedExecutable() throws {
    let fixture = CatalogFixture()
    defer { fixture.remove() }
    let url = try fixture.application("Linked.app", executable: .symlink)
    #expect(ApplicationCatalog.application(at: url)?.url == url)
    #expect(ApplicationCatalog.enumerate(directories: [fixture.root]).map { $0.url.resolvingSymlinksInPath().path } == [url.resolvingSymlinksInPath().path])
}

@Test(.appTestApplication) func appCatalogAcceptsWrapperForEnumerationAndBrowse() throws {
    let fixture = CatalogFixture()
    defer { fixture.remove() }
    let url = try fixture.application("Student.app", wrapper: true)
    let bundle = try #require(Bundle(url: url))
    #expect(bundle.bundleIdentifier == "test.fixture")
    #expect(bundle.executableURL != nil)
    #expect(!FileManager.default.fileExists(atPath: url.appending(path: "Contents/Info.plist").path))
    let choice = ApplicationCatalog.application(at: url)
    #expect(choice?.id == "test.fixture")
    #expect(choice?.name == "Student")
    #expect(choice?.url == url)
    let enumerated = ApplicationCatalog.enumerate(directories: [fixture.root])
    #expect(enumerated.map(\.id) == ["test.fixture"])
    #expect(enumerated.map { $0.url.resolvingSymlinksInPath().path } == [url.resolvingSymlinksInPath().path])
}

@Test(.appTestApplication) func appCatalogBrowseAcceptsApplicationOutsideScanRoots() throws {
    let fixture = CatalogFixture()
    defer { fixture.remove() }
    let url = try fixture.application("External/Editor.app")
    let scanRoot = fixture.root.appending(path: "Applications")
    try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
    #expect(ApplicationCatalog.enumerate(directories: [scanRoot]).isEmpty)
    let choice = try #require(ApplicationCatalog.application(at: url))
    #expect(choice.url == url)
    #expect(ApplicationPickerModel.validationMessage(for: choice, excluding: []) == nil)
}

@Test(.appTestApplication) func installedAppCatalogExpiresAtFiveMinutes() async {
    let clock = Mutex(Date(timeIntervalSince1970: 0))
    let scans = Mutex(0)
    let catalog = InstalledApplicationCatalog(now: { clock.withLock { $0 } }, load: {
        let count = scans.withLock { $0 += 1; return $0 }
        return [appChoice("test.scan.\(count)", "Scan \(count)")]
    })
    let first = await catalog.applications()
    #expect(first.map(\.id) == ["test.scan.1"])
    clock.withLock { $0 = Date(timeIntervalSince1970: 299.999) }
    #expect(await catalog.applications() == first)
    #expect(scans.withLock { $0 } == 1)
    clock.withLock { $0 = Date(timeIntervalSince1970: 300) }
    #expect(await catalog.applications().map(\.id) == ["test.scan.2"])
    #expect(scans.withLock { $0 } == 2)
    #expect(await catalog.applications().map(\.id) == ["test.scan.2"])
    #expect(scans.withLock { $0 } == 2)
}

private actor CatalogScanProbe {
    private(set) var calls = 0
    private var blocked = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    let started: AsyncStream<Void>.Continuation

    init(started: AsyncStream<Void>.Continuation) { self.started = started }

    func load() async -> [ApplicationChoice] {
        calls += 1
        let count = calls
        started.yield(())
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        return [appChoice("test.scan.\(count)", "Scan \(count)")]
    }

    func release() {
        blocked = false
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private func enteredCatalogRequest(
    _ catalog: isolated InstalledApplicationCatalog, signal: AsyncStream<Void>.Continuation
) async -> [ApplicationChoice] {
    signal.yield(())
    // Stay on the catalog actor until applications() reaches its suspension.
    return await catalog.applications()
}

@Test(.appTestApplication) func installedAppCatalogSharesConcurrentScanAndExpiresFromCompletion() async {
    let clock = Mutex(Date(timeIntervalSince1970: 0))
    let (started, scanStarted) = AsyncStream<Void>.makeStream()
    let probe = CatalogScanProbe(started: scanStarted)
    let catalog = InstalledApplicationCatalog(now: { clock.withLock { $0 } }, load: { await probe.load() })
    let first = Task { await catalog.applications() }
    var starts = started.makeAsyncIterator()
    _ = await starts.next()
    // Even a scan lasting longer than the cache lifetime must be shared.
    clock.withLock { $0 = Date(timeIntervalSince1970: 600) }
    let (entered, requestEntered) = AsyncStream<Void>.makeStream()
    let second = Task { await enteredCatalogRequest(catalog, signal: requestEntered) }
    var requests = entered.makeAsyncIterator()
    _ = await requests.next()
    await probe.release()
    #expect(await first.value.map(\.id) == ["test.scan.1"])
    #expect(await second.value == first.value)
    #expect(await probe.calls == 1)
    clock.withLock { $0 = Date(timeIntervalSince1970: 899.999) }
    #expect(await catalog.applications() == first.value)
    #expect(await probe.calls == 1)
    clock.withLock { $0 = Date(timeIntervalSince1970: 900) }
    #expect(await catalog.applications().map(\.id) == ["test.scan.2"])
    #expect(await probe.calls == 2)
}

// Native controls stay unordered. Events go only to this process's field editor.
@MainActor private final class PickerPanelProbe: NSOpenPanel {
    var owner: NSWindow?
    var beganWithoutOwner = false
    var completion: ((NSApplication.ModalResponse) -> Void)?
    var beginCount = 0
    var cancelCount = 0
    var chosenURL: URL?
    override var url: URL? { chosenURL }

    override func cancel(_ sender: Any?) {
        cancelCount += 1
        complete(.cancel)
    }

    func complete(_ response: NSApplication.ModalResponse) {
        let callback = completion
        completion = nil
        callback?(response)
    }

    override func begin(completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        beginCount += 1
        beganWithoutOwner = true
        completion = handler
    }

    override func beginSheetModal(for window: NSWindow,
                                  completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        beginCount += 1
        owner = window
        completion = handler
    }
}

@MainActor private func pickerSubviews<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { pickerSubviews($0, of: type) }
}

@MainActor private func pickerAccessibilityElements(_ root: NSObject) -> [NSObject] {
    var seen: Set<ObjectIdentifier> = []
    func visit(_ object: NSObject) -> [NSObject] {
        guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
        // Scroll views expose their rows as contents rather than children.
        let children = [#selector(NSAccessibilityProtocol.accessibilityChildren),
                        #selector(NSAccessibilityProtocol.accessibilityContents)].flatMap { selector -> [NSObject] in
            guard object.responds(to: selector) else { return [] }
            return object.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? []
        }
        let subviews = (object as? NSView)?.subviews ?? []
        return [object] + (children + subviews).flatMap(visit)
    }
    return visit(root)
}

@MainActor private func pickerElement(_ label: String, in view: NSView) throws -> NSObject {
    let selector = #selector(NSAccessibilityProtocol.accessibilityLabel)
    return try #require(pickerAccessibilityElements(view).first {
        $0.responds(to: selector)
            && $0.perform(selector)?.takeUnretainedValue() as? String == label
    })
}

@MainActor private func pickerContainsText(_ text: String, in view: NSView) -> Bool {
    pickerAccessibilityElements(view).contains { element in
        [#selector(NSAccessibilityProtocol.accessibilityLabel),
         #selector(NSAccessibilityProtocol.accessibilityValue)].contains { selector in
            element.responds(to: selector)
                && (element.perform(selector)?.takeUnretainedValue() as? String)?.contains(text) == true
        }
    }
}

@MainActor private final class NativePickerHarness {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    let panel: PickerPanelProbe
    let recent: RecentApplications
    var chosen: ApplicationChoice?
    var choiceCount = 0
    var readiness: ApplicationPickerReadiness?

    init(installed: [ApplicationChoice], running: [ApplicationChoice] = [],
         recent recentIdentifiers: [String] = [],
         resolve: @escaping @Sendable (String) -> ApplicationChoice? = { _ in nil },
         exclusions: Set<String> = [],
         loadInstalled: (@MainActor () async -> [ApplicationChoice])? = nil,
         ruleModel: BetterTileModel? = nil,
         windows: ((ApplicationChoice) -> [ApplicationPickerWindow]?)? = nil,
         onChooseWindow: ((ApplicationChoice, ApplicationPickerWindow) -> Void)? = nil) {
        _ = NSApplication.shared
        recent = RecentApplications(defaults: MemoryDefaults())
        for identifier in recentIdentifiers.reversed() { recent.record(identifier) }
        let recent = recent
        panel = PickerPanelProbe()
        let probe = panel
        window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 500, height: 480),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        var receive: ((ApplicationChoice) -> Void)?
        var observe: ((ApplicationPickerReadiness) -> Void)?
        let makePicker: (Set<String>, @escaping (ApplicationChoice) -> Void) -> ApplicationPicker = { excluded, choose in
            var picker = ApplicationPicker(exclusions: excluded, installedApplications: loadInstalled ?? { installed },
                              runningApplications: { running }, recentApplications: recent,
                              resolveApplication: resolve, makeOpenPanel: { probe },
                              windows: windows, onChooseWindow: onChooseWindow, onChoose: choose)
            picker.onPresentationChange = { observe?($0) }
            return picker
        }
        let content: AnyView
        if let ruleModel {
            content = AnyView(AddApplicationRuleSheet(makePicker: makePicker, model: ruleModel, onAdd: { _ in }))
        } else {
            content = AnyView(makePicker(exclusions) { receive?($0) })
        }
        host = NSHostingView(rootView: AnyView(content.environment(\.accessibilityEnabled, true)))
        receive = { [weak self] application in
            self?.chosen = application
            self?.choiceCount += 1
        }
        observe = { [weak self] in self?.readiness = $0 }
        window.contentView = PopupGlassHost(content: host)
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        do {
            try await waitForSettingsUI("the expected picker state", in: host, timeout: .seconds(5), until: condition)
        } catch {
            Issue.record("Picker did not reach expected state: \(String(describing: readiness))")
            throw error
        }
        #expect(!window.isVisible && !window.isKeyWindow && !panel.isVisible, Comment(rawValue: keyWindowDiagnostics(window)))
    }

    /// Waits until the picker's published rows, highlight and loading state stay the same for several
    /// layout opportunities in a row. Some tests hold the catalog loading on purpose.
    func settle() async throws {
        var previous: ApplicationPickerReadiness?
        var unchanged = 0
        try await waitForSettingsUI("the picker to finish updating", in: host) {
            unchanged = readiness != nil && readiness == previous ? unchanged + 1 : 0
            previous = readiness
            return unchanged >= 3
        }
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(window)))
        #expect(!panel.isVisible)
    }

    func search(_ query: String) async throws -> NSTextView {
        let field = try #require(pickerSubviews(host, of: NSTextField.self).first { $0.isEditable })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(query, replacementRange: editor.selectedRange())
        try await settle()
        return editor
    }

    func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code))
        try withNativeEventLoop { self.window.sendEvent(event) }
    }

    func press(_ label: String) throws {
        let element = try pickerElement(label, in: host)
        let selector = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
        try #require(element.responds(to: selector))
        typealias Press = @convention(c) (NSObject, Selector) -> Bool
        let press = unsafeBitCast(element.method(for: selector), to: Press.self)
        #expect(press(element, selector))
    }

    func close() {
        panel.complete(.cancel)
        window.close()
    }
}

@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct ApplicationPickerNativeTests {
    @Test(arguments: [false, true]) func inlineWindowsUseReturnAndLeftReturnsToApp(useWindow: Bool) async throws {
        let app = appChoice("test.safari", "Safari")
        let window = ApplicationPickerWindow(id: "one", title: "Start Page")
        var used: ApplicationPickerWindow?
        let harness = NativePickerHarness(installed: [app], running: [app], windows: { _ in [window] },
            onChooseWindow: { _, window in used = window })
        defer { harness.close() }
        try await harness.settle()
        _ = try await harness.search("Safari")
        try harness.key("\u{F703}", code: 124)
        try await harness.settle()
        try harness.key("\u{F701}", code: 125)
        try await harness.settle()
        if !useWindow {
            try harness.key("\u{F702}", code: 123)
            try await harness.settle()
        }
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(used == (useWindow ? window : nil))
        #expect(harness.chosen == (useWindow ? nil : app))
    }

    @Test func inlineWindowsShowAllThenReturnChoosesAWindow() async throws {
        let app = appChoice("test.safari", "Safari")
        let windows = (1...8).map { ApplicationPickerWindow(id: "w\($0)", title: "Window \($0)") }
        var used: ApplicationPickerWindow?
        let harness = NativePickerHarness(installed: [app], windows: { _ in windows }, onChooseWindow: { _, window in used = window })
        defer { harness.close() }
        try await harness.settle()
        _ = try await harness.search("Safari")
        try harness.key("\u{F703}", code: 124)
        try await harness.settle()
        for _ in 0..<6 {
            try harness.key("\u{F701}", code: 125)
            try await harness.settle()
        }
        try harness.key("\r", code: 36)
        try await harness.settle()
        for _ in 0..<7 {
            try harness.key("\u{F701}", code: 125)
            try await harness.settle()
        }
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(used == windows[6])
        #expect(harness.chosen == nil)
    }

    @Test func addRuleBodyInitiallyFocusesSearchAndAcceptsTyping() async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        let harness = NativePickerHarness(installed: [appChoice("test.alpha", "Alpha")], ruleModel: model)
        defer { harness.close(); model.shutdown() }
        try await harness.settle()
        let field = try #require(pickerSubviews(harness.host, of: NSTextField.self).first { $0.isEditable })
        #expect(field is NSSearchField)
        #expect(field.accessibilityLabel() == "Search apps")
        try harness.press("Browse…")
        #expect(harness.panel.owner === harness.window)
        harness.panel.complete(.cancel)
        #expect(harness.window.firstResponder is NSTextView)
        #expect(harness.window.firstResponder === field.currentEditor())
        try harness.key("z", code: 6)
        try await harness.settle()
        #expect(field.stringValue == "z")
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(pickerSubviews(harness.host, of: NSTextField.self).contains { $0 === field })
    }

    @Test func addRuleBodyBackRecreatesFocusedSearchAndAcceptsTyping() async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        let harness = NativePickerHarness(installed: [appChoice("test.alpha", "Alpha")], ruleModel: model)
        defer { harness.close(); model.shutdown() }
        try await harness.settle()
        try harness.key("Alpha", code: 0)
        try await harness.settle()
        let originalField = try #require(pickerSubviews(harness.host, of: NSTextField.self).first { $0.isEditable })
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(pickerSubviews(harness.host, of: NSTextField.self).allSatisfy { !$0.isEditable })
        try harness.press("Back")
        try await harness.settle()
        let field = try #require(pickerSubviews(harness.host, of: NSTextField.self).first { $0.isEditable })
        #expect(field !== originalField)
        #expect(harness.window.firstResponder is NSTextView)
        #expect(harness.window.firstResponder === field.currentEditor())
        try harness.key("z", code: 6)
        try await harness.settle()
        #expect(field.stringValue == "z")
        // The Add Rule step recorded the choice, so Alpha now leads the list as Recent.
        #expect(harness.recent.bundleIdentifiers == ["test.alpha"])
    }

    @Test func initialFocusDoesNotRepeatOnLoadingUpdatesOrWindowReattachment() async throws {
        let gate = PickerCatalogGate()
        let harness = NativePickerHarness(installed: [], running: [appChoice("test.alpha", "Alpha")],
                                          loadInstalled: { await gate.load() })
        defer { gate.release([]); harness.close() }
        try await harness.settle()
        let field = try #require(pickerSubviews(harness.host, of: NSTextField.self).first { $0.isEditable })
        let editor = try #require(field.currentEditor())
        try harness.key("\u{F701}", code: 125)
        try await harness.settle()
        // The keyboard highlight moves; focus stays in the search field.
        #expect(harness.window.firstResponder === editor)
        gate.release([appChoice("test.beta", "Beta")])
        try await harness.settle()
        #expect(harness.window.firstResponder === editor)
        #expect(pickerSubviews(harness.host, of: NSTextField.self).contains { $0 === field })

        let other = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 500, height: 480),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let container = NSView(frame: other.contentView!.bounds)
        let otherField = NSTextField(string: "Other window")
        otherField.isEditable = true
        container.addSubview(otherField)
        other.contentView = container
        #expect(other.makeFirstResponder(otherField))
        let otherEditor = try #require(otherField.currentEditor())
        harness.window.contentView = nil
        #expect(field.window == nil)
        #expect(other.firstResponder === otherEditor)
        container.addSubview(harness.host)
        try await harness.settle()
        #expect(field.window === other)
        #expect(other.firstResponder === otherEditor)
        harness.host.removeFromSuperview()
        try await harness.settle()
        #expect(field.window == nil)
        #expect(other.firstResponder === otherEditor)
        #expect(!other.isVisible)
        #expect(!other.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(other)))
    }

    @Test func separatePickerOwnersKeepBrowseCallbacksAndCancellationIsolated() async throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        let valid = try fixture.application("Valid.app")
        let first = NativePickerHarness(installed: [])
        let second = NativePickerHarness(installed: [])
        defer { first.close(); second.close() }
        try await first.settle()
        try await second.settle()
        try first.press("Browse…")
        try second.press("Browse…")
        #expect(first.panel.owner === first.window)
        #expect(second.panel.owner === second.window)
        let lateCompletion = try #require(first.panel.completion)
        first.panel.chosenURL = valid
        first.host.rootView = AnyView(EmptyView())
        try await first.settle()
        lateCompletion(.OK)
        #expect(first.chosen == nil)
        #expect(first.panel.cancelCount == 1)
        #expect(second.panel.cancelCount == 0)
        second.panel.chosenURL = valid
        second.panel.complete(.OK)
        #expect(second.chosen?.id == "test.fixture")
        #expect(second.choiceCount == 1)
        #expect(second.recent.bundleIdentifiers == ["test.fixture"])
    }

    @Test func runningResultCanBeChosenWhileInstalledCatalogLoads() async throws {
        let gate = PickerCatalogGate()
        let harness = NativePickerHarness(installed: [], running: [appChoice("test.alpha", "Alpha")],
                                          loadInstalled: { await gate.load() })
        defer { gate.release([]); harness.close() }
        try await harness.settle()
        try #require(gate.waiter != nil)
        try harness.key("\u{F701}", code: 125)
        try await harness.settle()
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(harness.chosen?.id == "test.alpha")
        #expect(harness.choiceCount == 1)
    }

    @Test func browseUsesPickerSheetOwnerInsteadOfUnownedPanel() async throws {
        let harness = NativePickerHarness(installed: [])
        defer { harness.close() }
        // The real sheet API is recorded, so this cannot verify compositor stacking.
        try await harness.settle()
        try harness.press("Browse…")
        try await harness.settle()
        #expect(!harness.panel.beganWithoutOwner)
        #expect(harness.panel.owner === harness.window)
        #expect(harness.window.level == .floating)
        #expect(harness.chosen == nil)
    }

    @Test(arguments: ["AirPort", "TextEdit"])
    func searchHighlightsFirstResultSoReturnChoosesIt(query: String) async throws {
        let airport = appChoice("test.airport", "AirPort Utility")
        let textEdit = appChoice("test.textedit", "TextEdit")
        let harness = NativePickerHarness(installed: [airport], running: [textEdit])
        defer { harness.close() }
        try await harness.settle()
        let editor = try await harness.search(query)
        #expect(harness.window.firstResponder === editor)
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(harness.window.firstResponder === editor)
        #expect(harness.chosen?.id == (query == "AirPort" ? airport.id : textEdit.id))
        #expect(harness.choiceCount == 1)
    }

    @Test func recentSectionLeadsKeyboardOrder() async throws {
        let alpha = appChoice("test.alpha", "Alpha")
        let zulu = appChoice("test.zulu", "Zulu")
        let harness = NativePickerHarness(installed: [alpha, zulu], recent: ["test.zulu", "test.missing"])
        defer { harness.close() }
        // The installed scan can finish before the detached missing-Recent lookup.
        // Wait for completed loading AND the actual Recent-first navigation order.
        try await harness.waitUntil {
            harness.readiness?.isLoading == false
                && harness.readiness?.rowIDs == ["Recent:test.zulu", "All Apps:test.alpha", "All Apps:test.zulu"]
                && harness.window.firstResponder is NSTextView
        }
        try harness.key("\u{F701}", code: 125)
        try await harness.waitUntil { harness.readiness?.highlight == "Recent:test.zulu" }
        try harness.key("\r", code: 36)
        try await harness.waitUntil { harness.choiceCount == 1 }
        #expect(harness.chosen?.id == zulu.id)
        #expect(harness.recent.bundleIdentifiers == ["test.zulu", "test.missing"])
    }

    @Test func recentAppOutsideScanResolvesOnceOffTheMainActorAfterTheScan() async throws {
        let gate = PickerCatalogGate()
        let elsewhere = appChoice("test.elsewhere", "Elsewhere", path: "/Volumes/Apps/Elsewhere.app")
        let lookups = Mutex<[(String, Bool)]>([])
        let harness = NativePickerHarness(installed: [], recent: ["test.elsewhere"], resolve: { id in
            lookups.withLock { $0.append((id, Thread.isMainThread)) }
            return id == elsewhere.id ? elsewhere : nil
        }, loadInstalled: { await gate.load() })
        defer { gate.release([]); harness.close() }
        try await harness.settle()
        #expect(lookups.withLock { $0.isEmpty })
        gate.release([appChoice("test.alpha", "Alpha")])
        try await harness.settle()
        // The lookup runs off the main actor; give its result time to reach the view under load.
        for _ in 0..<10 where lookups.withLock({ $0.isEmpty }) { try await harness.settle() }
        for _ in 0..<5 { try await harness.settle() }
        #expect(lookups.withLock { $0.map(\.0) } == ["test.elsewhere"])
        #expect(lookups.withLock { $0.allSatisfy { !$0.1 } })
        try harness.key("\u{F701}", code: 125)
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(harness.chosen?.id == elsewhere.id)
    }

    @Test func browseCancelCanReopenAndPickerRemovalCancelsPendingPanel() async throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        let valid = try fixture.application("Late.app")
        let harness = NativePickerHarness(installed: [])
        defer { harness.close() }
        try await harness.settle()
        try harness.press("Browse…")
        try await harness.settle()
        #expect(harness.panel.beginCount == 1)
        try harness.press("Browse…")
        try await harness.settle()
        #expect(harness.panel.beginCount == 1)
        harness.panel.complete(.cancel)
        try harness.press("Browse…")
        try await harness.settle()
        #expect(harness.panel.beginCount == 2)
        harness.panel.chosenURL = valid
        let staleCompletion = try #require(harness.panel.completion)
        harness.host.rootView = AnyView(EmptyView())
        try await harness.settle()
        #expect(harness.panel.cancelCount == 1)
        staleCompletion(.OK)
        #expect(harness.chosen == nil)
    }

    @Test func browseCompletionUsesCatalogValidationAndExclusions() async throws {
        let fixture = CatalogFixture()
        defer { fixture.remove() }
        let valid = try fixture.application("External.app")
        let invalid = try fixture.application("Invalid.app", executable: .missing)
        let harness = NativePickerHarness(installed: [])
        defer { harness.close() }
        try await harness.settle()
        try harness.press("Browse…")
        try await harness.settle()
        harness.panel.chosenURL = invalid
        harness.panel.complete(.OK)
        try await harness.settle()
        #expect(harness.chosen == nil)
        #expect(pickerContainsText("This application has no bundle identifier. Choose another application.", in: harness.host))
        try harness.press("Browse…")
        try await harness.settle()
        harness.panel.chosenURL = valid
        harness.panel.complete(.OK)
        #expect(harness.chosen?.id == "test.fixture")

        let excluded = NativePickerHarness(installed: [], exclusions: ["test.fixture"])
        defer { excluded.close() }
        try await excluded.settle()
        try excluded.press("Browse…")
        try await excluded.settle()
        excluded.panel.chosenURL = valid
        excluded.panel.complete(.OK)
        try await excluded.settle()
        #expect(excluded.chosen == nil)
        #expect(excluded.recent.bundleIdentifiers.isEmpty)
        #expect(pickerContainsText("This application is already included. Choose another application.", in: excluded.host))
    }

    @Test func noResultsOffersBrowseAndSearchCanRecover() async throws {
        let airport = appChoice("test.airport", "AirPort Utility")
        let textEdit = appChoice("test.textedit", "TextEdit")
        let harness = NativePickerHarness(installed: [airport, textEdit])
        defer { harness.close() }
        try await harness.settle()
        let editor = try await harness.search("no matching app")
        #expect(pickerContainsText("No apps match “no matching app”", in: harness.host))
        try harness.key("\u{F701}", code: 125)
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(harness.window.firstResponder === editor)
        #expect(harness.chosen == nil)
        try harness.press("Browse…")
        #expect(harness.panel.owner === harness.window)
        harness.panel.complete(.cancel)
        _ = try await harness.search("TextEdit")
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(harness.chosen?.id == textEdit.id)
    }

    @Test func returnWithoutHighlightDoesNothing() async throws {
        let harness = NativePickerHarness(installed: [appChoice("test.airport", "AirPort Utility")])
        defer { harness.close() }
        try await harness.settle()
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(harness.chosen == nil)
        let editor = try await harness.search("")
        try harness.key("\u{F700}", code: 126)
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(harness.window.firstResponder === editor)
        #expect(harness.chosen == nil)
    }

    @Test func loadingSearchWaitsForResultsBeforeChoosing() async throws {
        let gate = PickerCatalogGate()
        let airport = appChoice("test.airport", "AirPort Utility")
        let harness = NativePickerHarness(installed: [], loadInstalled: { await gate.load() })
        defer { gate.release([]); harness.close() }
        try await harness.settle()
        try #require(gate.waiter != nil)
        let editor = try await harness.search("AirPort")
        #expect(!pickerContainsText("No apps match", in: harness.host))
        try harness.key("\u{F701}", code: 125)
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(harness.window.firstResponder === editor)
        #expect(harness.chosen == nil)
        gate.release([airport])
        try await harness.settle()
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(harness.chosen?.id == airport.id)
    }

    @Test func arrowsMoveTheHighlightThroughResults() async throws {
        let first = appChoice("test.first", "Editor A")
        let second = appChoice("test.second", "Editor B")
        let harness = NativePickerHarness(installed: [second, first])
        defer { harness.close() }
        try await harness.settle()
        _ = try await harness.search("Editor")
        try harness.key("\u{F701}", code: 125)
        try await harness.settle()
        try harness.key("\u{F700}", code: 126)
        try await harness.settle()
        try harness.key("\u{F701}", code: 125)
        try await harness.settle()
        try harness.key("\u{F701}", code: 125)
        try await harness.settle()
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(harness.chosen?.id == second.id)
    }

    @Test(arguments: ["", "Al"])
    func scanFinishingDuringCompositionPreservesEditorAndMarkedText(committed: String) async throws {
        let gate = PickerCatalogGate()
        let harness = NativePickerHarness(installed: [], loadInstalled: { await gate.load() })
        defer { gate.release([]); harness.close() }
        try await harness.settle()
        try #require(gate.waiter != nil)
        let field = try #require(pickerSubviews(harness.host, of: NSTextField.self).first { $0.isEditable })
        let editor = try #require(field.currentEditor() as? NSTextView)
        if !committed.isEmpty {
            try harness.key(committed, code: 0)
            try await harness.settle()
        }
        #expect(field.stringValue == committed)
        let marked = committed.isEmpty ? "Alpha" : "pha"
        editor.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0),
                             replacementRange: editor.selectedRange())
        try await harness.settle()
        #expect(editor.hasMarkedText())
        #expect(editor.string == "Alpha")
        gate.release([appChoice("test.albatross", "Albatross"), appChoice("test.alpha", "Alpha")])
        try await harness.settle()
        #expect(harness.window.firstResponder === editor)
        #expect(field.currentEditor() === editor)
        #expect(editor.hasMarkedText())
        #expect(editor.string == "Alpha")
        try harness.key("\u{F701}", code: 125)
        try await harness.settle()
        #expect(harness.window.firstResponder === editor)
        #expect(editor.hasMarkedText())
        #expect(editor.string == "Alpha")
        #expect(harness.chosen == nil)
        editor.insertText(marked, replacementRange: editor.markedRange())
        try await harness.settle()
        #expect(!editor.hasMarkedText())
        #expect(field.stringValue == "Alpha")
        // Both apps match the old binding; only Alpha matches the committed search.
        #expect(!pickerContainsText("Albatross", in: harness.host))
        #expect(pickerContainsText("Alpha", in: harness.host))
        try harness.key("\r", code: 36)
        try await harness.settle()
        #expect(harness.chosen?.id == "test.alpha")
        #expect(harness.choiceCount == 1)
    }

    @Test func searchPreservesNativeEditingAndMarkedText() async throws {
        let harness = NativePickerHarness(installed: [appChoice("test.airport", "AirPort Utility")])
        defer { harness.close() }
        try await harness.settle()
        let editor = try await harness.search("AirPort")
        try harness.key("\u{F702}", code: 123)
        try harness.key("\u{7f}", code: 51)
        try harness.key("\u{F703}", code: 124)
        try harness.key("x", code: 7)
        try await harness.settle()
        #expect(editor.string == "AirPotx")
        #expect(harness.window.firstResponder === editor)
        #expect(harness.chosen == nil)
        editor.selectAll(nil)
        editor.setMarkedText("AirPort", selectedRange: NSRange(location: 7, length: 0),
                             replacementRange: editor.selectedRange())
        #expect(editor.hasMarkedText())
        try harness.key("\u{F701}", code: 125)
        try await harness.settle()
        #expect(harness.window.firstResponder === editor)
        #expect(harness.chosen == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func searchGlyphsKeepContrastOnTheSemanticFieldSurface(dark: Bool, clear: Bool) async throws {
        _ = NSApplication.shared
        let previous = NSApp.appearance
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        NSApp.appearance = appearance
        defer { NSApp.appearance = previous }
        let harness = NativePickerHarness(installed: [appChoice("test.alpha", "Alpha")])
        defer { harness.close() }
        harness.window.appearance = appearance
        try await harness.settle()
        let field = try #require(pickerSubviews(harness.host, of: NSSearchField.self).first)
        let cell = try #require(field.cell as? ApplicationPickerSearchCell)
        if clear { _ = try await harness.search("Alpha") }
        let rect = clear ? cell.cancelButtonRect(forBounds: field.bounds) : cell.searchButtonRect(forBounds: field.bounds)
        let cg = try #require(CGContext(data: nil, width: Int(field.bounds.width * 2),
            height: Int(field.bounds.height * 2), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.scaleBy(x: 2, y: 2)
        let graphics = NSGraphicsContext(cgContext: cg, flipped: field.isFlipped)
        appearance.performAsCurrentDrawingAppearance { field.displayIgnoringOpacity(field.bounds, in: graphics) }
        let bytes = try #require(cg.data).assumingMemoryBound(to: UInt8.self)
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        var surface: NSColor!
        appearance.performAsCurrentDrawingAppearance { surface = NSColor.textBackgroundColor.usingColorSpace(.sRGB) }
        let backdrop = [surface.redComponent, surface.greenComponent, surface.blueComponent].map { Double($0) }
        let background = linear(backdrop[0]) * 0.2126 + linear(backdrop[1]) * 0.7152 + linear(backdrop[2]) * 0.0722
        var peakContrast = 1.0
        for y in Int(rect.minY * 2)..<Int(rect.maxY * 2) {
            for x in Int(rect.minX * 2)..<Int(rect.maxX * 2) {
            let i = y * cg.bytesPerRow + x * 4
            let alpha = Double(bytes[i + 3]) / 255
            guard alpha > 0.1 else { continue }
            let rgb = (0..<3).map { Double(bytes[i + $0]) / 255 }
            let composed = zip(rgb, backdrop).map { linear($0 + $1 * (1 - alpha)) }
            let ink = composed[0] * 0.2126 + composed[1] * 0.7152 + composed[2] * 0.0722
            peakContrast = max(peakContrast, (max(ink, background) + 0.05) / (min(ink, background) + 0.05))
        } }
        // The magnifier is ours; the clear cell retains AppKit's native drawing and action.
        #expect(peakContrast >= 3, "Search glyph contrast over the semantic field surface: \(peakContrast)")
        print("POPUP_SEARCH dark=\(dark) clear=\(clear) contrast=\(peakContrast)")
        if let directory = ProcessInfo.processInfo.environment["BT_PANEL_PIXEL_DIR"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bitmap = NSBitmapImageRep(cgImage: try #require(cg.makeImage()))
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("search-\(clear ? "clear" : "magnifier")-\(dark ? "dark" : "light").png"))
        }
    }

    /// The field fills its visible capsule, so the window's hit test sends a click at any edge or
    /// corner to the field, and the clear button still clears. An earlier field was 16 pt tall in a 28 pt capsule.
    @Test func searchCapsuleIsTheFieldsClickTarget() async throws {
        let harness = NativePickerHarness(installed: [appChoice("test.alpha", "Alpha")])
        defer { harness.close() }
        try await harness.settle()
        let field = try #require(pickerSubviews(harness.host, of: NSSearchField.self).first)
        let cell = try #require(field.cell as? ApplicationPickerSearchCell)
        #expect(field.bounds.height == SettingsSpacing.s6 + SettingsSpacing.s1)
        let root = try #require(harness.window.contentView)
        func target(_ point: NSPoint) -> NSView? {
            root.hitTest(root.superview?.convert(field.convert(point, to: nil), from: nil) ?? .zero)
        }
        // The visible capsule: the search height, centred on the field. The harness window clips the
        // picker's outer 2 pt, so test what the window shows.
        let height = SettingsSpacing.s6 + SettingsSpacing.s1
        let capsule = NSRect(x: field.bounds.minX, y: field.bounds.midY - height / 2, width: field.bounds.width, height: height)
        let b = capsule.intersection(field.convert(root.bounds, from: root))
        let edges = [NSPoint(x: b.minX + 1, y: b.minY + 1), NSPoint(x: b.maxX - 1, y: b.minY + 1),
                     NSPoint(x: b.minX + 1, y: b.maxY - 1), NSPoint(x: b.maxX - 1, y: b.maxY - 1),
                     NSPoint(x: b.midX, y: b.minY + 0.5), NSPoint(x: b.midX, y: b.maxY - 0.5),
                     NSPoint(x: b.minX + 0.5, y: b.midY), NSPoint(x: b.maxX - 0.5, y: b.midY)]
        for focused in [false, true] {
            // Unfocused, and while the field editor is up.
            if focused { #expect(harness.window.makeFirstResponder(field)) } else { harness.window.makeFirstResponder(nil) }
            for point in edges {
                let hit = target(point)
                #expect(hit === field || hit?.isDescendant(of: field) == true, "\(point) hit \(hit.map { type(of: $0) } as Any)")
            }
        }
        // The magnifier, text and cancel button sit in a band centred in the capsule.
        let text = cell.searchTextRect(forBounds: field.bounds)
        #expect(abs(text.midY - field.bounds.midY) <= 1)
        #expect(text.minX >= field.bounds.minX + ApplicationPickerSearchCell.horizontalInset)
        _ = try await harness.search("Al")
        #expect(field.stringValue == "Al")
        let cancel = cell.cancelButtonRect(forBounds: field.bounds)
        #expect(abs(cancel.midY - field.bounds.midY) <= 1)
        #expect(b.contains(cancel))
        #expect(target(NSPoint(x: cancel.midX, y: cancel.midY)) === field)
        let clear = try #require(cell.cancelButtonCell)
        _ = (clear.target as? NSObject)?.perform(clear.action, with: clear)
        try await harness.settle()
        #expect(field.stringValue.isEmpty)
        #expect(harness.window.firstResponder === field.currentEditor())
    }
}

@MainActor private final class PickerCatalogGate {
    var waiter: CheckedContinuation<[ApplicationChoice], Never>?
    func load() async -> [ApplicationChoice] {
        await withCheckedContinuation { waiter = $0 }
    }
    func release(_ apps: [ApplicationChoice]) {
        let pending = waiter
        waiter = nil
        pending?.resume(returning: apps)
    }
}
