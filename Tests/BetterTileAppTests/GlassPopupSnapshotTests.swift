import AppKit
import BetterTileCore
import CoreImage
import SwiftUI
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

/// Every popup, chooser and search surface, rendered offscreen in its real host.
///
/// AppKit cannot draw native glass into a bitmap: `NSGlassEffectView` paints an opaque fallback
/// and system materials paint nothing. Each capture therefore leaves out the native glass and draws
/// a blur of a synthetic desktop where the glass is. The plate, rim and content are real drawing.
/// With `BT_SNAPSHOT_DIR` set, each case also writes that composite as a PNG.
@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct GlassPopupSnapshotTests {
    enum Surface: String, CaseIterable, CustomTestStringConvertible {
        case ruleSheet
        var testDescription: String { rawValue }
        /// Settings pages are opaque; popup content above glass must stay clear.
        var isOverMaterial: Bool { true }
    }

    enum Mode: String, CaseIterable, CustomTestStringConvertible {
        case glass, reduceTransparency = "rt"
        var testDescription: String { rawValue }
    }

    struct Variant: CustomTestStringConvertible {
        var surface: Surface, dark: Bool, mode: Mode
        var testDescription: String { "\(surface.rawValue) \(dark ? "dark" : "light") \(mode.rawValue)" }
        var name: String { "\(surface.rawValue)-\(dark ? "dark" : "light")-\(mode.rawValue)" }
    }

    nonisolated static let variants: [Variant] = Surface.allCases.flatMap { surface in
        [false, true].flatMap { dark in Mode.allCases.map { Variant(surface: surface, dark: dark, mode: $0) } }
    }

    /// On a loaded runner each readiness poll can take far longer than its step, because it draws the
    /// popup twice and reads its text. Readiness must count polls, not elapsed time, so slow polls
    /// still reach the two identical drawings it needs.
    @Test func readinessKeepsItsPollBudgetWhenEveryPollIsSlow() async throws {
        let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 120, height: 80),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        window.contentView = root
        var polls = 0
        try await GlassPopupScene.ready(root, timeout: .milliseconds(400)) {
            polls += 1
            Thread.sleep(forTimeInterval: 0.1) // real-time: stands in for a main actor slowed by a loaded runner
            return polls >= 8
        }
        #expect(polls >= 9, "The second identical drawing needs one more poll")
    }

    @Test func readinessObservesContentInsteadOfAnAnimatingBackdrop() async throws {
        let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 120, height: 80),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = ChangingDrawingView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let content = NSView(frame: NSRect(x: 10, y: 10, width: 100, height: 60))
        root.addSubview(content)
        window.contentView = root
        var polls = 0
        try await GlassPopupScene.ready(root, in: content, timeout: .milliseconds(100)) {
            polls += 1
            root.shade += 1 // Native glass may redraw while the actual controls are already stable.
            root.needsDisplay = true
            return true
        }
        #expect(polls == 2, "Two matching content drawings must suffice even while the backdrop changes")
    }

    /// A readiness failure must say whether the picture never settled or the content never appeared, and
    /// how many polls of the budget it used, so a slow runner can be told apart from a changing picture.
    @Test(arguments: [true, false])
    func readinessFailureSaysWhyItStopped(contentAppears: Bool) async throws {
        let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 120, height: 80),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = ChangingDrawingView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        window.contentView = root
        let explained = MatchedIssue()
        let expected = contentAppears ? "the drawing was still changing at the last poll" : "the expected content never appeared"
        try await withKnownIssue("readiness gives up") {
            try await GlassPopupScene.ready(root, timeout: .milliseconds(100)) {
                root.shade += 1
                root.needsDisplay = true
                return contentAppears
            }
        } matching: { issue in
            if issue.error is CancellationError { return true }
            let text = String(describing: issue)
            if text.contains("Not ready after 6 of 6 polls: \(expected)") { explained.seen = true; return true }
            return false
        }
        #expect(explained.seen)
    }

    @Test(arguments: variants)
    func popupRootPaintsNoOpaqueFillWhenTransparencyIsAllowed(_ variant: Variant) async throws {
        let scene = try await GlassPopupScene.make(variant.surface, dark: variant.dark,
                                                   reduceTransparency: variant.mode == .reduceTransparency)
        defer { scene.close() }
        let content = scene.capture(includingGlass: false)
        let surface = scene.capture(includingGlass: true)
        // Search fields deliberately own an opaque semantic surface. Check the rest
        // of the popup for accidental fills, including margins alongside the field.
        let fields = panelViews(scene.root, NSSearchField.self).map { field in
            let rect = field.convert(field.bounds, to: scene.root)
            return NSRect(x: rect.minX, y: scene.root.isFlipped ? rect.minY : scene.root.bounds.height - rect.maxY,
                          width: rect.width, height: rect.height)
        }
        if [GlassPopupSnapshotTests.Surface.ruleSheet].contains(variant.surface) {
            #expect(GlassPixels(content).inkedRowShare >= 0.2, "\(variant.name): capture lost picker content")
        }
        if variant.surface.isOverMaterial {
            // Over glass or its opaque fallback, content paints no band of its own.
            let rows = GlassPixels.solidNeutralRows(content, excluding: fields)
            #expect(rows.isEmpty, "\(variant.name): \(rows.count) rows paint an opaque neutral fill, first at \(rows.first ?? -1) px")
        } else {
            // On the opaque Settings page, the palette uses the Settings card fill, not a text background.
            let appearance = scene.root.effectiveAppearance
            let card = try #require(GlassPixels.resolved(SettingsColor.group, over: .windowBackgroundColor, in: appearance))
            #expect(GlassPixels.rows(content, matching: card).count >= 16, "\(variant.name): no card-filled rows")
            let text = try #require(GlassPixels.resolved(Color(nsColor: .textBackgroundColor), over: .windowBackgroundColor, in: appearance))
            let page = try #require(GlassPixels.resolved(.clear, over: .windowBackgroundColor, in: appearance))
            if !GlassPixels.close(text, card), !GlassPixels.close(text, page) {
                #expect(GlassPixels.rows(content, matching: text).isEmpty, "\(variant.name): text background rows")
            }
        }
        if variant.mode == .reduceTransparency, scene.hasGlass {
            // The fallback is an opaque system surface, not a thinner plate.
            #expect(GlassPixels.opaqueShare(surface, inset: scene.surfaceInset) > 0.99, "\(variant.name)")
        } else if scene.hasGlass {
            // The mean includes the plate, rim and opaque content. Keep the same 0.15
            // headroom above the compiled floor in each appearance; the backdrop stays visible.
            let coverage = GlassPixels.meanAlpha(surface, inset: scene.surfaceInset, excluding: fields)
            let limit = variant.dark ? 0.50 : 0.35
            #expect(coverage < limit, "\(variant.name): the surface covers \(coverage) of the backdrop")
        }
        #expect(scene.hasGlass == variant.surface.isOverMaterial, "\(variant.name)")
        if let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            let folder = URL(filePath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = try #require(GlassBackdrop.composite(surface, scene: scene))
            try #require(image.representation(using: .png, properties: [:]))
                .write(to: folder.appending(path: variant.name + ".png"))
            // The layer the pixel check reads: content alone, with every glass view hidden.
            let contentFolder = folder.appending(path: "content")
            try FileManager.default.createDirectory(at: contentFolder, withIntermediateDirectories: true)
            try #require(content.representation(using: .png, properties: [:]))
                .write(to: contentFolder.appending(path: variant.name + ".png"))
        }
    }
}

/// One surface in the host the app uses, kept alive until the capture ends.
@MainActor final class GlassPopupScene {
    let root: NSView
    private let window: NSWindow?
    private let keepAlive: [AnyObject]
    private let onClose: () -> Void
    /// Glass shapes in root coordinates, top-left origin.
    var glassShapes: [(rect: NSRect, radius: CGFloat)] {
        return descendants(root).compactMap { $0 as? OverlayGlassView }.filter { !$0.isHidden && $0.showsGlass }.map { view in
            let frame = view.convert(view.bounds, to: root)
            let top = root.isFlipped ? frame.minY : root.bounds.height - frame.maxY
            return (NSRect(x: frame.minX, y: top, width: frame.width, height: frame.height), view.cornerRadius)
        }
    }
    var hasGlass: Bool { !descendants(root).compactMap { $0 as? OverlayGlassView }.isEmpty }
    /// Corner radius of the outer surface, so the opaque check skips the transparent corners.
    let surfaceInset: CGFloat
    let pageBackground: NSColor?
    let reduceTransparency: Bool

    private init(root: NSView, window: NSWindow?, keepAlive: [AnyObject] = [], surfaceInset: CGFloat, reduceTransparency: Bool,
                 pageBackground: NSColor? = nil, onClose: @escaping () -> Void = {}) {
        self.root = root; self.window = window; self.keepAlive = keepAlive; self.onClose = onClose
        self.surfaceInset = surfaceInset; self.pageBackground = pageBackground
        self.reduceTransparency = reduceTransparency
    }

    func close() {
        (keepAlive.first { $0 is SettingsPickerController } as? SettingsPickerController)?.dismiss()
        window?.contentView = nil
        window?.close()
        onClose()
    }

    /// Real drawing without native glass. `includingGlass` controls the frost and rim.
    func capture(includingGlass: Bool) -> NSBitmapImageRep { Self.capture(root, includingGlass: includingGlass) }

    static func capture(_ root: NSView, includingGlass: Bool) -> NSBitmapImageRep {
        let glassViews = descendants(root).compactMap { $0 as? OverlayGlassView }
        root.layoutSubtreeIfNeeded()
        // Cache real controls before detaching native glass. Moving its contentView for
        // drawing makes AppKit reset its layout and can produce an empty, false-green capture.
        let parts = glassViews.map { view in
            (plate: includingGlass ? drawing(view.plate) : nil,
             plateRect: view.plate.convert(view.plate.bounds, to: root),
             content: view.popupContent.map(drawing),
             contentRect: view.popupContent.map { $0.convert($0.bounds, to: root) })
        }
        let detached = glassViews.filter { $0.glass.superview === $0 }
        detached.forEach { $0.glass.removeFromSuperview() }
        let hidden = glassViews.map { ($0, $0.isHidden) }
        glassViews.forEach { $0.isHidden = true }
        defer {
            for (view, wasHidden) in hidden { view.isHidden = wasHidden }
            for view in detached { view.addSubview(view.glass, positioned: .below, relativeTo: nil) }
        }
        let base = drawing(root)
        let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        output.size = base.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        defer { NSGraphicsContext.restoreGraphicsState() }
        func draw(_ bitmap: NSBitmapImageRep, in rect: NSRect) {
            let destination = root.isFlipped
                ? NSRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
            bitmap.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        // Preserve the app's stacking: frost, pane chrome outside glass, then popup content.
        for part in parts { if let plate = part.plate { draw(plate, in: part.plateRect) } }
        draw(base, in: root.bounds)
        for part in parts {
            if let content = part.content, let rect = part.contentRect { draw(content, in: rect) }
        }
        return output
    }

    // MARK: Fixtures

    private static func app(_ id: String, _ name: String, _ path: String) -> ApplicationChoice {
        ApplicationChoice(bundleIdentifier: id, name: name, url: URL(filePath: path))
    }
    static let notes = app("com.apple.Notes", "Notes", "/System/Applications/Notes.app")
    static let mail = app("com.apple.mail", "Mail", "/System/Applications/Mail.app")
    static let terminal = app("com.apple.Terminal", "Terminal", "/System/Applications/Utilities/Terminal.app")
    static let calendar = app("com.apple.iCal", "Calendar", "/System/Applications/Calendar.app")
    static let textEdit = app("com.apple.TextEdit", "TextEdit", "/System/Applications/TextEdit.app")
    static let calculator = app("com.apple.calculator", "Calculator", "/System/Applications/Calculator.app")
    static let preview = app("com.apple.Preview", "Preview", "/System/Applications/Preview.app")
    static let installed = [notes, mail, terminal, calendar, textEdit, calculator, preview]

    static func make(_ surface: GlassPopupSnapshotTests.Surface, dark: Bool, reduceTransparency: Bool) async throws -> GlassPopupScene {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let recent = RecentApplications(defaults: MemoryDefaults())
        recent.record(terminal.id); recent.record(notes.id)
        func swiftUI(_ view: some View) -> NSHostingView<AnyView> {
            NSHostingView(rootView: AnyView(view
                .environment(\._accessibilityReduceTransparency, reduceTransparency)
                // Builds the accessibility tree that readiness reads. Lazy list rows stay out of it.
                .environment(\.accessibilityEnabled, true)))
        }
        func hosted(_ view: NSView, size: NSSize) -> NSWindow {
            let window = OffscreenTestWindow(contentRect: NSRect(origin: NSPoint(x: 12000, y: 0), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            view.frame = NSRect(origin: .zero, size: size)
            window.contentView = view
            applyDisplayOptions(view, reduceTransparency: reduceTransparency)
            return window
        }

        switch surface {
        case .ruleSheet:
            let model = makeModel(system: FakeAppWindowSystem())
            let makePicker: (Set<String>, @escaping (ApplicationChoice) -> Void) -> ApplicationPicker = { exclusions, choose in
                ApplicationPicker(exclusions: exclusions, installedApplications: { installed }, runningApplications: { [mail] },
                                  recentApplications: recent, resolveApplication: { _ in nil }, onChoose: choose)
            }
            let host = swiftUI(AddApplicationRuleSheet(makePicker: makePicker, model: model, onAdd: { _ in }))
            let size = NSSize(width: 420, height: 520)
            let parent = hosted(NSView(), size: NSSize(width: 980, height: 700))
            let controller = SettingsPickerController(content: host, size: size, appearance: .init(), onDismiss: {})
            controller.present(over: parent)
            controller.panel.appearance = appearance
            let root = try #require(controller.panel.contentView)
            applyDisplayOptions(root, reduceTransparency: reduceTransparency)
            #expect(controller.panel.parent === parent)
            #expect(controller.panel.backgroundColor == .clear)
            #expect(!controller.panel.isOpaque)
            try await ready(root, showing: "Search apps", rowsDrawn: 0.2, in: host) { root.bounds.size == size }
            return GlassPopupScene(root: root, window: parent, keepAlive: [controller], surfaceInset: 12,
                                   reduceTransparency: reduceTransparency, onClose: { model.shutdown() })
        }
    }

    private static func applyDisplayOptions(_ root: NSView, reduceTransparency: Bool) {
        for case let view as OverlayGlassView in descendants(root) {
            view.displayOptions = { (reduceTransparency, false) }
            view.refreshAppearance()
        }
    }

    /// Wait for the expected state, drawn content and two matching content captures.
    /// The explicit content view excludes native glass, whose independent redraws do not
    /// describe SwiftUI readiness. Its geometry in the root must settle as well.
    static func ready(_ root: NSView, showing text: String? = nil, rowsDrawn: Double = 0, in content: NSView? = nil,
                              timeout: Duration = .seconds(5), _ condition: () -> Bool = { true }) async throws {
        var previous: GlassPixels?
        var previousGeometry: [NSRect]?
        var drawn = 0.0
        // Counts that tell a slow runner from a picture that never settles when the budget runs out.
        var polls = 0, drawings = 0, lastUnmet: Int?, lastChange: Int?
        // `waitFor` counts polling steps, not elapsed time, so a stalled main actor cannot use up the budget.
        let settled = await waitFor(timeout: timeout) {
            polls += 1
            root.layoutSubtreeIfNeeded()
            guard root.bounds.width > 0, root.bounds.height > 0,
                  (content ?? root).bounds.width > 0, (content ?? root).bounds.height > 0,
                  condition(), text.map({ text in texts(in: root).contains { $0.contains(text) } }) ?? true else {
                previous = nil
                lastUnmet = polls
                return false
            }
            let subject = content ?? root
            let pixels = GlassPixels(drawing(subject))
            let geometry = [root.bounds, subject.convert(subject.bounds, to: root)]
            drawings += 1
            drawn = rowsDrawn > 0 ? pixels.inkedRowShare : 0
            if let previous, previous != pixels || previousGeometry != geometry { lastChange = polls }
            defer { previous = pixels; previousGeometry = geometry }
            return pixels == previous && previousGeometry == geometry && drawn >= rowsDrawn
        }
        if settled { return }
        let budget = Int((timeout / .milliseconds(20)).rounded(.up)) + 1
        let verdict = drawings == 0 ? "the expected content never appeared"
            : lastUnmet == polls ? "the expected content was missing at the last poll"
            : lastChange == polls ? "the drawing was still changing at the last poll"
            : drawn < rowsDrawn ? "too few drawn rows"
            : "no two consecutive drawings matched"
        let unmet = lastUnmet.map(String.init) ?? "none", changed = lastChange.map(String.init) ?? "none"
        let summary = "Not ready after \(polls) of \(budget) polls: \(verdict). Compared \(drawings) drawings; "
            + "content last unmet at poll \(unmet), drawing last changed at poll \(changed)."
        let frames = descendants(root).filter { $0 is OverlayGlassView || $0 is NSGlassEffectView || $0.subviews.contains(where: { $0 === content }) }.map { "\(type(of: $0)): \($0.frame), bounds \($0.bounds), auto \($0.translatesAutoresizingMaskIntoConstraints)" }
        Issue.record("\(summary) Expected \(text ?? "a stable picture"), \(rowsDrawn) drawn, last \(drawn); root \(root.frame), content \(String(describing: content?.frame)); frames \(frames); showing \(texts(in: root).filter { !$0.isEmpty })")
        throw CancellationError()
    }

    /// The view's own drawing, as AppKit caches it. Native glass draws its offscreen fallback here.
    private static func drawing(_ view: NSView) -> NSBitmapImageRep {
        view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        return bitmap
    }

    /// Visible strings: AppKit labels and fields, and SwiftUI text through the accessibility tree.
    static func texts(in root: NSView) -> [String] {
        var seen: Set<ObjectIdentifier> = []
        var found: [String] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let field = object as? NSTextField { found.append(field.stringValue) }
            for selector in [#selector(NSAccessibilityProtocol.accessibilityLabel), #selector(NSAccessibilityProtocol.accessibilityValue)]
            where object.responds(to: selector) {
                if let value = object.perform(selector)?.takeUnretainedValue() as? String { found.append(value) }
            }
            for selector in [#selector(NSAccessibilityProtocol.accessibilityChildren), #selector(NSAccessibilityProtocol.accessibilityContents)]
            where object.responds(to: selector) {
                (object.perform(selector)?.takeUnretainedValue() as? [NSObject])?.forEach(visit)
            }
            (object as? NSView)?.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func descendants(_ view: NSView) -> [NSView] { Self.descendants(view) }
}

/// Premultiplied 8-bit RGBA in sRGB, top row first.
struct GlassPixels: Equatable {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ bitmap: NSBitmapImageRep) {
        let (width, height) = (bitmap.pixelsWide, bitmap.pixelsHigh)
        self.width = width; self.height = height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.bytes = bytes
    }

    /// Straight (unpremultiplied) components of one pixel, 0…1.
    func pixel(x: Int, y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let i = (y * width + x) * 4
        let a = Double(bytes[i + 3]) / 255
        guard a > 0 else { return (0, 0, 0, 0) }
        return (Double(bytes[i]) / 255 / a, Double(bytes[i + 1]) / 255 / a, Double(bytes[i + 2]) / 255 / a, a)
    }

    /// Pixel rows where an opaque, neutral fill covers most of the width: a solid grey or black band.
    /// Text, icons, accent highlights and narrow buttons never cover that much of a row.
    static func solidNeutralRows(_ bitmap: NSBitmapImageRep, coverage: Double = 0.6, excluding rects: [NSRect] = []) -> [Int] {
        let pixels = GlassPixels(bitmap)
        let scale = CGFloat(pixels.width) / bitmap.size.width
        let rows = (0..<pixels.height).filter { y in
            var solid = 0, total = 0
            for x in 0..<pixels.width {
                let point = NSPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                if rects.contains(where: { $0.contains(point) }) { continue }
                total += 1
                let p = pixels.pixel(x: x, y: y)
                if p.a >= 0.85, max(p.r, p.g, p.b) - min(p.r, p.g, p.b) <= 0.06 { solid += 1 }
            }
            return total > 0 && Double(solid) >= coverage * Double(total)
        }
        // Glass can adapt the native Divider to opaque. A one-point separator is
        // expected; a filled header or sheet surface is a taller band.
        let separatorPixels = Int(ceil(Double(bitmap.pixelsHigh) / Double(bitmap.size.height)))
        var bands: [[Int]] = []
        for row in rows {
            if bands.last?.last == row - 1 { bands[bands.count - 1].append(row) }
            else { bands.append([row]) }
        }
        return bands.filter { $0.count > separatorPixels }.flatMap { $0 }
    }

    /// Share of pixel rows with any mostly opaque pixel.
    var inkedRowShare: Double {
        let inked = (0..<height).filter { y in (0..<width).contains { x in bytes[(y * width + x) * 4 + 3] >= 128 } }
        return height == 0 ? 0 : Double(inked.count) / Double(height)
    }

    /// Pixel rows where one opaque colour, within 2/255, covers `coverage` of the width.
    static func rows(_ bitmap: NSBitmapImageRep, matching color: (r: Double, g: Double, b: Double),
                     coverage: Double = 0.6) -> [Int] {
        let pixels = GlassPixels(bitmap)
        return (0..<pixels.height).filter { y in
            var matching = 0
            for x in 0..<pixels.width {
                let p = pixels.pixel(x: x, y: y)
                if p.a >= 0.99, close((p.r, p.g, p.b), color) { matching += 1 }
            }
            return Double(matching) >= coverage * Double(pixels.width)
        }
    }

    static func close(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Bool {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) <= 2.0 / 255
    }

    /// A SwiftUI colour drawn over an opaque page colour, as the 8-bit sRGB pixel AppKit produces.
    @MainActor static func resolved(_ color: Color, over page: NSColor, in appearance: NSAppearance) -> (r: Double, g: Double, b: Double)? {
        let host = NSHostingView(rootView: Rectangle().fill(color).background(Color(nsColor: page)).frame(width: 8, height: 8))
        // Hosted like the scenes, so SwiftUI resolves system colours the same way.
        let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 8, height: 8), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        let pixels = GlassPixels(bitmap)
        let p = pixels.pixel(x: pixels.width / 2, y: pixels.height / 2)
        return p.a >= 0.99 ? (p.r, p.g, p.b) : nil
    }

    /// Mean opacity inside the surface, away from its rounded corners.
    static func meanAlpha(_ bitmap: NSBitmapImageRep, inset: CGFloat, excluding rects: [NSRect] = []) -> Double {
        let pixels = GlassPixels(bitmap)
        let scale = Double(pixels.width) / Double(bitmap.size.width)
        let margin = Int((Double(inset) * scale).rounded(.up)) + 1
        var sum = 0.0, total = 0
        for y in margin..<max(margin, pixels.height - margin) {
            for x in margin..<max(margin, pixels.width - margin) {
                let point = NSPoint(x: (Double(x) + 0.5) / scale, y: (Double(y) + 0.5) / scale)
                if rects.contains(where: { $0.contains(point) }) { continue }
                total += 1
                sum += pixels.pixel(x: x, y: y).a
            }
        }
        return total == 0 ? 0 : sum / Double(total)
    }

    /// Share of pixels inside the surface, away from its rounded corners, that are opaque.
    static func opaqueShare(_ bitmap: NSBitmapImageRep, inset: CGFloat) -> Double {
        let pixels = GlassPixels(bitmap)
        let scale = Double(pixels.width) / Double(bitmap.size.width)
        let margin = Int((Double(inset) * scale).rounded(.up)) + 1
        var opaque = 0, total = 0
        for y in margin..<max(margin, pixels.height - margin) {
            for x in margin..<max(margin, pixels.width - margin) {
                total += 1
                if pixels.pixel(x: x, y: y).a >= 0.98 { opaque += 1 }
            }
        }
        return total == 0 ? 0 : Double(opaque) / Double(total)
    }
}

/// A synthetic desktop behind each surface: a saturated wallpaper, a white document and a dark terminal.
@MainActor enum GlassBackdrop {
    static let margin: CGFloat = 24

    static func composite(_ surface: NSBitmapImageRep, scene: GlassPopupScene) -> NSBitmapImageRep? {
        let size = NSSize(width: surface.size.width + margin * 2, height: surface.size.height + margin * 2)
        let scale = Double(surface.pixelsWide) / Double(surface.size.width)
        guard let backdrop = backdrop(size: size, scale: scale),
              let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // Points, so the context maps them to the pixel grid.
        output.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: output) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cg = context.cgContext
        cg.draw(backdrop, in: CGRect(origin: .zero, size: size))
        let blurred = blur(backdrop, radius: 18 * scale)
        scene.root.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let page = scene.pageBackground {
                page.setFill()
                NSRect(x: margin, y: margin, width: surface.size.width, height: surface.size.height).fill()
            }
            for shape in scene.glassShapes {
                // Top-left shape coordinates to the bottom-left context.
                let rect = NSRect(x: margin + shape.rect.minX, y: margin + surface.size.height - shape.rect.maxY,
                                  width: shape.rect.width, height: shape.rect.height)
                let path = NSBezierPath(roundedRect: rect, xRadius: shape.radius, yRadius: shape.radius)
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                if let blurred { cg.draw(blurred, in: CGRect(origin: .zero, size: size)) }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        surface.draw(in: NSRect(x: margin, y: margin, width: surface.size.width, height: surface.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return output
    }

    private static func backdrop(size: NSSize, scale: Double) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let colors = [NSColor.systemBlue.cgColor, NSColor.systemPurple.cgColor, NSColor.systemOrange.cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        // A white document on the left and a dark terminal on the right, both with text.
        let document = CGRect(x: size.width * 0.04, y: size.height * 0.30, width: size.width * 0.46, height: size.height * 0.62)
        let terminal = CGRect(x: size.width * 0.56, y: size.height * 0.08, width: size.width * 0.40, height: size.height * 0.55)
        context.setFillColor(NSColor.white.cgColor); context.fill(document)
        context.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor); context.fill(terminal)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for (frame, color) in [(document, NSColor.black), (terminal, NSColor(srgbRed: 0.4, green: 1, blue: 0.5, alpha: 1))] {
            var y = frame.maxY - 22
            while y > frame.minY + 6 {
                ("Synthetic window content 0123456789" as NSString).draw(at: NSPoint(x: frame.minX + 8, y: y),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: color])
                y -= 20
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func blur(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image).clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}

/// Draws a different shade on every display, so its drawing never settles.
private final class ChangingDrawingView: NSView {
    var shade = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: CGFloat(shade % 50) / 50, alpha: 1).setFill()
        bounds.fill()
    }
}

/// Records, from the known-issue matcher, that the expected explanation appeared.
private final class MatchedIssue: @unchecked Sendable {
    var seen = false
}
