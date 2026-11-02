import AppKit
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor
@Suite(.macOSTestApplication)
struct LayoutGlyphViewTests {
    @Test func templateImageIsATemplateCachedPerSizeAndWeight() {
        let glyph = LayoutGlyph.layout(.columns)
        let image = glyph.templateImage(canvasSize: 16.4, weight: .regular)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 16.4, height: 16.4))
        #expect(glyph.templateImage(canvasSize: 16.4, weight: .regular) === image)
        #expect(glyph.templateImage(canvasSize: 17.7, weight: .regular) !== image)
        #expect(glyph.templateImage(canvasSize: 16.4, weight: .semibold) !== image)
        #expect(LayoutGlyph.layout(.rows).templateImage(canvasSize: 16.4, weight: .regular) !== image)
        // Linked mode reads as Manual, so both share one image.
        #expect(LayoutGlyph.mode(.linked).templateImage(canvasSize: 16.4)
            === LayoutGlyph.mode(.manual).templateImage(canvasSize: 16.4))
    }

    /// Draws `image` into a bitmap with the given pixel size, one pixel per point.
    private func rasterize(_ image: NSImage, pixels: Int) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    @Test func strokeIsNeverUnderOneDevicePixelAndStraightEdgesStayCrispAtOneX() throws {
        // 13 points at 1x: 0.8125 pt is raised to one pixel, and the edges snap to pixel centres, so
        // every pixel on a straight edge is fully covered or untouched. A blurred edge would show
        // partial coverage in the middle column, which crosses only the top and bottom edges.
        let bitmap = try rasterize(LayoutGlyph.layout(.single).templateImage(canvasSize: 13), pixels: 13)
        var covered = 0
        for y in 0 ..< 13 {
            let alpha = try #require(bitmap.colorAt(x: 6, y: y)).alphaComponent
            #expect(alpha > 0.99 || alpha < 0.01, "Row \(y) has partial coverage \(alpha)")
            if alpha > 0.99 { covered += 1 }
        }
        #expect(covered == 2, "One crisp one-pixel row for the top edge and one for the bottom edge")

        // The same drawing for every icon, size, scale and weight keeps its stroke at one device pixel or more.
        for glyph in LayoutGlyph.all {
            for scale in [1.0, 2.0, 3.0] {
                let drawing = glyph.drawing(canvasSize: 13, weight: .regular, displayScale: scale)
                #expect(drawing.strokeWidth * scale >= 1)
                #expect(drawing.cgPaths().count == glyph.parts.count)
            }
        }
    }

    @Test func retinaImagesDrawAtTheDisplayScale() throws {
        let image = LayoutGlyph.layout(.single).templateImage(canvasSize: 13)
        let bitmap = try rasterize(image, pixels: 26)
        // 13 pt Regular at 2x is 0.8125 pt, or 1.625 device pixels: the top edge is at least
        // one fully covered pixel row, with partial coverage allowed beside it.
        var coverage = 0.0
        for y in 0 ..< 26 { coverage += Double(try #require(bitmap.colorAt(x: 13, y: y)).alphaComponent) }
        #expect(coverage > 2 * 1.5 && coverage < 2 * 2.0, "Two edges of about 1.625 pixels, got \(coverage)")
    }

    @Test func slotsSelectTheModeAndLayoutIcons() {
        for mode in LayoutMode.allCases {
            #expect(LayoutWheelSlot(command: .setMode(mode)).glyph == .mode(mode))
        }
        for preset in TabbedPreset.allCases {
            #expect(LayoutWheelSlot(command: .chooseLayout(preset)).glyph == .layout(preset))
        }
        // Every other command keeps its SF Symbol.
        #expect(LayoutWheelSlot(command: .windowAction(.leftHalf)).glyph == nil)
        #expect(LayoutWheelSlot(command: .repairBento).glyph == nil)
        #expect(LayoutWheelSlot(command: nil).glyph == nil)
        #expect(LayoutWheelSlot(command: .customZone(UUID())).glyph == nil)
    }

    @Test func groupParentsFollowTheChosenIcons() {
        let mode = LayoutWheelGroup.at(.bottomRight)
        let layout = LayoutWheelGroup.at(.bottomLeft)
        for current in LayoutMode.availableModes {
            let slot = LayoutWheelSlot(label: mode.title, symbolName: mode.symbolName,
                                       glyph: mode.glyph(currentMode: current), isEmpty: false, isAvailable: true)
            #expect(slot.glyph == .mode(current))
        }
        #expect(layout.glyph(currentMode: .manual) == .layouts)
        for sector in LayoutWheelSector.allCases where sector != .bottomLeft && sector != .bottomRight {
            #expect(LayoutWheelGroup.at(sector).glyph(currentMode: .tabbed) == nil)
        }
    }

    @Test func modePickerShowsAnImageAndATitleInEverySegment() {
        var selected = LayoutMode.bento
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let picker = LayoutModePicker("Window mode", selection: binding, width: .fillAvailable)
        let hosting = NSHostingView(rootView: picker.frame(width: 284))
        hosting.frame = NSRect(x: 0, y: 0, width: 284, height: 40)
        hosting.layoutSubtreeIfNeeded()
        let control = hosting.firstDescendant(of: NSSegmentedControl.self)
        #expect(control != nil)
        guard let control else { return }
        #expect(control.segmentCount == LayoutMode.availableModes.count)
        for (index, mode) in LayoutMode.availableModes.enumerated() {
            #expect(control.label(forSegment: index) == mode.title)
            let image = control.image(forSegment: index)
            #expect(image?.isTemplate == true)
            #expect(image?.size == NSSize(width: LayoutModePicker.glyphSize + LayoutModePicker.imageTrailingPadding, height: LayoutModePicker.glyphSize))
            #expect(control.imageScaling(forSegment: index) == .scaleNone)
        }
        #expect(control.selectedSegment == LayoutMode.availableModes.firstIndex(of: .bento))
        #expect(abs(control.frame.width - 284) < 1)
        control.selectedSegment = 2
        _ = control.sendAction(control.action, to: control.target)
        #expect(selected == .tabbed)
    }

    /// A control's ink, rendered at `scale` pixels per point: pixels that differ from the tray.
    private struct Ink {
        let bitmap: NSBitmapImageRep
        let scale: Int
        let reference: NSColor

        func isInk(x: Int, y: Int) -> Bool {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return abs(c.redComponent - reference.redComponent) > 0.25
        }

        /// Runs of ink columns between `from` and `to`, as x positions in points.
        func runs(from: Double, to: Double) -> [(Double, Double)] {
            var runs: [(Double, Double)] = []
            var start: Int?
            let first = Int(from * Double(scale)), last = Int(to * Double(scale))
            for x in first ... last {
                let ink = ((bitmap.pixelsHigh / 4) ..< (bitmap.pixelsHigh * 3 / 4)).contains { isInk(x: x, y: $0) }
                if ink, start == nil { start = x }
                if !ink || x == last, let begin = start {
                    runs.append((Double(begin) / Double(scale), Double(x) / Double(scale)))
                    start = nil
                }
            }
            return runs
        }

        /// The top and bottom of the ink in a run of columns, in points from the top.
        func rows(of run: (Double, Double)) -> (top: Double, bottom: Double)? {
            let columns = Int(run.0 * Double(scale)) ... Int(run.1 * Double(scale))
            let inked = (0 ..< bitmap.pixelsHigh).filter { y in columns.contains { isInk(x: $0, y: y) } }
            guard let top = inked.min(), let bottom = inked.max() else { return nil }
            return (Double(top) / Double(scale), Double(bottom + 1) / Double(scale))
        }
    }

    /// Renders `view` and takes the tray colour as the most common colour of its middle row between
    /// `from` and `to`. Segment separators, the selected segment and text are all less common than the tray.
    private func ink(of view: NSView, scale: Int, from: Double, to: Double) throws -> Ink {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let midY = bitmap.pixelsHigh / 2
        var counts: [Int: (count: Int, color: NSColor)] = [:]
        for x in Int(from * Double(scale)) ... Int(to * Double(scale)) {
            guard let c = bitmap.colorAt(x: x, y: midY)?.usingColorSpace(.sRGB) else { continue }
            let key = Int(c.redComponent * 255) << 16 | Int(c.greenComponent * 255) << 8 | Int(c.blueComponent * 255)
            counts[key] = ((counts[key]?.count ?? 0) + 1, c)
        }
        let reference = try #require(counts.values.max { $0.count < $1.count }?.color)
        return Ink(bitmap: bitmap, scale: scale, reference: reference)
    }

    private final class Backing: NSView {
        override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
    }

    /// The left side bearing of a title's first letter at the control font: where its ink starts when
    /// the text is drawn at x = 0, found by drawing it at 8x.
    private func bearing(of title: String) throws -> Double {
        let scale = 8
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40 * scale, pixelsHigh: 24 * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: 40, height: 24)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 24).fill()
        (String(title.prefix(1)) as NSString).draw(at: NSPoint(x: 10, y: 4), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        for x in 0 ..< bitmap.pixelsWide {
            for y in 0 ..< bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent ?? 1) < 0.5 {
                return Double(x) / Double(scale) - 10
            }
        }
        return 0
    }

    /// Where a segment's title sits relative to its icon: the gap from the icon to the title's text origin
    /// (ink gap less the first letter's side bearing), and the title's ink rows and the icon's rows.
    private struct TitlePlacement {
        var gap: Double
        var title: (top: Double, bottom: Double)
        var icon: (top: Double, bottom: Double)
    }

    /// A solid probe the size of a segment image, with the icon's canvas filled at its leading edge.
    private func probe(size: NSSize) -> NSImage {
        let canvas = LayoutModePicker.glyphSize
        let probe = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            NSRect(x: 0, y: (size.height - canvas) / 2, width: canvas, height: canvas).fill()
            return true
        }
        probe.isTemplate = true
        return probe
    }

    /// Hosts `content` in a 304 x 44 window and returns the segmented control it shows.
    private func host(_ content: NSView, dark: Bool) -> (container: NSView, window: NSWindow) {
        let container = Backing(frame: NSRect(x: 0, y: 0, width: 304, height: 44))
        container.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        container.addSubview(content)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = container.appearance
        window.contentView = container
        return (container, window)
    }

    /// Finds each unselected segment's probe across the whole control and measures its title. No segment
    /// geometry is assumed: segment widths, separators and the selected segment differ between macOS releases.
    private func placements(in control: NSSegmentedControl, container: NSView,
                            selected: LayoutMode) throws -> [String: TitlePlacement] {
        container.layoutSubtreeIfNeeded()
        let frame = control.convert(control.bounds, to: container)
        let ink = try ink(of: container, scale: 4, from: frame.minX + 1, to: frame.maxX - 1)
        let runs = ink.runs(from: frame.minX + 1, to: frame.maxX - 1)
        let size = LayoutModePicker.glyphSize
        let probes = runs.indices.filter { index in
            guard abs((runs[index].1 - runs[index].0) - size) <= 1.2, let rows = ink.rows(of: runs[index]) else { return false }
            return abs((rows.bottom - rows.top) - size) <= 1.2
        }
        // A selected segment far from the tray colour is one run, so its probe may not be found.
        let modes = LayoutMode.availableModes
        let shown = probes.count == modes.count ? modes : modes.filter { $0 != selected }
        try #require(probes.count == shown.count, "The icon is found in every segment: \(probes.count) probes in \(runs)")
        var placements: [String: TitlePlacement] = [:]
        for (mode, index) in zip(shown, probes) where mode != selected {
            guard runs.indices.contains(index + 1), let icon = ink.rows(of: runs[index]),
                  let title = ink.rows(of: runs[index + 1]) else {
                Issue.record("\(mode.title): no title after the icon")
                continue
            }
            placements[mode.title] = TitlePlacement(
                gap: runs[index + 1].0 - runs[index].1 - (try bearing(of: mode.title)), title: title, icon: icon)
        }
        return placements
    }

    /// Hosts the real `LayoutModePicker`, swaps each segment's image for a solid probe of the same size, and
    /// measures where each unselected title sits.
    private func pickerPlacements(dark: Bool, selected: LayoutMode, width: LayoutModePicker.Width) throws -> [String: TitlePlacement] {
        _ = NSApplication.shared
        var current = selected
        let picker = LayoutModePicker("Window mode", selection: Binding(get: { current }, set: { current = $0 }), width: width)
        let hosting = NSHostingView(rootView: Group {
            if width == .fillAvailable { picker.frame(width: 284) } else { picker.fixedSize() }
        }.padding(10))
        hosting.frame = NSRect(x: 0, y: 0, width: 304, height: 44)
        let (container, window) = host(hosting, dark: dark)
        defer { window.contentView = nil }
        for _ in 0 ..< 100 where hosting.firstDescendant(of: NSSegmentedControl.self) == nil {
            container.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02)) // real-time: SwiftUI creates the segmented control on a main run loop turn
        }
        container.layoutSubtreeIfNeeded()
        let control = try #require(hosting.firstDescendant(of: NSSegmentedControl.self))
        #expect(control.segmentDistribution == (width == .fillAvailable ? .fillEqually : .fit))
        // The probe keeps the size of the image the picker set, so a wrong icon size or padding moves the title.
        for index in 0 ..< control.segmentCount {
            let image = try #require(control.image(forSegment: index))
            control.setImage(probe(size: image.size), forSegment: index)
        }
        return try placements(in: control, container: container, selected: selected)
    }

    /// The same segments in a plain `NSSegmentedControl`: the designed image (the icon canvas and its padding)
    /// and each title, laid out by the system alone. This is the spacing the system gives that image and title.
    private func nativePlacements(dark: Bool, selected: LayoutMode, width: LayoutModePicker.Width) throws -> [String: TitlePlacement] {
        _ = NSApplication.shared
        let control = NSSegmentedControl()
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        control.segmentCount = LayoutMode.availableModes.count
        let image = probe(size: NSSize(width: LayoutModePicker.glyphSize + LayoutModePicker.imageTrailingPadding,
                                       height: LayoutModePicker.glyphSize))
        for (index, mode) in LayoutMode.availableModes.enumerated() {
            control.setLabel(mode.title, forSegment: index)
            control.setImage(image, forSegment: index)
            control.setImageScaling(.scaleNone, forSegment: index)
        }
        control.segmentDistribution = width == .fillAvailable ? .fillEqually : .fit
        control.selectedSegment = try #require(LayoutMode.availableModes.firstIndex(of: selected))
        let natural = control.fittingSize
        let controlWidth = width == .fillAvailable ? 284 : natural.width
        control.frame = NSRect(x: (304 - controlWidth) / 2, y: (44 - natural.height) / 2, width: controlWidth, height: natural.height)
        let (container, window) = host(control, dark: dark)
        defer { window.contentView = nil }
        return try placements(in: control, container: container, selected: selected)
    }

    /// The title follows the icon on the line the system gives it, and the picker adds no space of its own:
    /// the gap is positive and at most the gap a plain segmented control shows for the same image and title.
    /// That system gap differs between macOS releases, so it is measured, not assumed. Each title rasterises a
    /// little differently, so the bound applies to the average, with a wider bound on each title.
    @Test func modePickerTitleFollowsTheIconWithNoMoreThanTheSystemSpacing() throws {
        for dark in [false, true] {
            for width in [LayoutModePicker.Width.fillAvailable, .fitContent] {
                var picker: [String: [TitlePlacement]] = [:]
                var native: [String: [TitlePlacement]] = [:]
                for selected in [LayoutMode.manual, .tabbed] {
                    for (title, placement) in try pickerPlacements(dark: dark, selected: selected, width: width) {
                        picker[title, default: []].append(placement)
                    }
                    for (title, placement) in try nativePlacements(dark: dark, selected: selected, width: width) {
                        native[title, default: []].append(placement)
                    }
                }
                #expect(Set(picker.keys) == ["Manual", "Adaptive", "Tabbed"])
                #expect(Set(native.keys) == ["Manual", "Adaptive", "Tabbed"])
                func average(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(1, values.count)) }
                let gaps = picker.mapValues { average($0.map(\.gap)) }
                let systemGaps = native.mapValues { average($0.map(\.gap)) }
                let label = "\(dark ? "dark" : "light") \(width): picker \(gaps), system \(systemGaps)"
                #expect(average(Array(gaps.values)) <= average(Array(systemGaps.values)) + 0.6, "Mean gap, \(label)")
                for (title, gap) in gaps {
                    let system = try #require(systemGaps[title])
                    #expect(gap > 0, "\(title) follows its icon, \(label)")
                    #expect(gap <= system + 1.6, "\(title) \(gap) against the system's \(system), \(label)")
                }
                for (title, placements) in picker {
                    let system = try #require(native[title]?.first)
                    for placement in placements {
                        // Same line as the icon, and the same baseline as the system's own label.
                        let middle = (placement.title.top + placement.title.bottom) / 2
                        #expect(middle > placement.icon.top && middle < placement.icon.bottom, "\(title) beside its icon, \(label)")
                        #expect(abs(placement.title.top - system.title.top) <= 1, "\(title) top \(placement.title.top) against \(system.title.top), \(label)")
                        #expect(abs(placement.title.bottom - system.title.bottom) <= 1, "\(title) bottom, \(label)")
                    }
                }
            }
        }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews { if let match = subview.firstDescendant(of: type) { return match } }
        return nil
    }
}

@MainActor
@Suite(.macOSTestApplication)
struct LayoutGlyphNumberFitTests {
    /// The shortest pane is 6 units, or 13 points at the 52 point Settings size. Its 3.25 point stroke
    /// leaves 9.75 points inside. A 9 point semibold digit must fit there, and in the narrowest pane.
    @Test func ninePointNumbersFitInsideTheShortPanes() {
        let font = NSFont.systemFont(ofSize: LayoutGlyph.minimumNumberFontSize, weight: .semibold)
        let stroke = LayoutGlyph.strokeWidth(canvasSize: 52, weight: .regular, displayScale: 2)
        var narrowest = Double.infinity
        var shortest = Double.infinity
        for preset in TabbedPreset.allCases {
            for rect in LayoutGlyph.paneRects(of: preset) {
                narrowest = min(narrowest, rect.width * 52 / 24)
                shortest = min(shortest, rect.height * 52 / 24)
            }
        }
        #expect(abs(shortest - 13) < 1e-9)
        let interiorHeight = shortest - stroke
        #expect(font.capHeight < interiorHeight - 2, "Digit height \(font.capHeight) in \(interiorHeight) pt")
        var widest = 0.0
        for digit in ["1", "2", "3", "4"] {
            widest = max(widest, Double(NSAttributedString(string: digit, attributes: [.font: font]).size().width))
        }
        #expect(widest < narrowest - stroke - 2, "Digit width \(widest) in \(narrowest - stroke) pt")
    }
}
