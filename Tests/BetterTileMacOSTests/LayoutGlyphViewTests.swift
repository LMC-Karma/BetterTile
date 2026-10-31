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

    /// Runs of columns that differ from the tray, as x positions in points, between `from` and `to`.
    private func inkRuns(of view: NSView, scale: Int, from: Double, to: Double) throws -> [(Double, Double)] {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        // The tray colour in the middle of the control, between segments' content, is the reference.
        let midY = bitmap.pixelsHigh / 2
        let reference = try #require(bitmap.colorAt(x: Int(from * Double(scale)) + 1, y: midY)?.usingColorSpace(.sRGB))
        var runs: [(Double, Double)] = []
        var start: Int?
        let first = Int(from * Double(scale)), last = Int(to * Double(scale))
        for x in first ... last {
            var ink = false
            for y in (bitmap.pixelsHigh / 4) ..< (bitmap.pixelsHigh * 3 / 4) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - reference.redComponent) > 0.25 { ink = true; break }
            }
            if ink, start == nil { start = x }
            if !ink || x == last, let begin = start {
                runs.append((Double(begin) / Double(scale), Double(x) / Double(scale)))
                start = nil
            }
        }
        return runs
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

    /// Hosts the real `LayoutModePicker`, swaps each segment's icon for a solid probe of the same size, and
    /// returns the gap from the probe to the first letter of each unselected title, less the letter's own
    /// side bearing: the distance from icon to text origin.
    private func originGaps(dark: Bool, selected: LayoutMode, width: LayoutModePicker.Width) throws -> [String: Double] {
        _ = NSApplication.shared
        var current = selected
        let picker = LayoutModePicker("Window mode", selection: Binding(get: { current }, set: { current = $0 }), width: width)
        let hosting = NSHostingView(rootView: Group {
            if width == .fillAvailable { picker.frame(width: 284) } else { picker.fixedSize() }
        }.padding(10))
        let container = Backing(frame: NSRect(x: 0, y: 0, width: 304, height: 44))
        container.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = container.bounds
        container.addSubview(hosting)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = container.appearance
        window.contentView = container
        for _ in 0 ..< 100 where hosting.firstDescendant(of: NSSegmentedControl.self) == nil {
            container.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02)) // real-time: SwiftUI creates the segmented control on a main run loop turn
        }
        container.layoutSubtreeIfNeeded()
        let control = try #require(hosting.firstDescendant(of: NSSegmentedControl.self))
        #expect(control.segmentDistribution == (width == .fillAvailable ? .fillEqually : .fit))

        let size = LayoutModePicker.glyphSize
        let probe = NSImage(size: NSSize(width: size + LayoutModePicker.imageTrailingPadding(for: width), height: size), flipped: true) { _ in
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: size, height: size).fill()
            return true
        }
        probe.isTemplate = true
        for index in 0 ..< control.segmentCount {
            #expect(control.image(forSegment: index)?.size == probe.size, "The wrapper's image is the size of the probe")
            control.setImage(probe, forSegment: index)
        }
        container.layoutSubtreeIfNeeded()

        let controlFrame = control.convert(control.bounds, to: container)
        var gaps: [String: Double] = [:]
        for (index, mode) in LayoutMode.availableModes.enumerated() where mode != selected {
            let segmentWidth = controlFrame.width / Double(control.segmentCount)
            let from = controlFrame.minX + segmentWidth * Double(index)
            let to = width == .fillAvailable ? from + segmentWidth - 2 : (control.width(forSegment: index) > 0 ? from + control.width(forSegment: index) - 2 : from + segmentWidth - 2)
            let runs = try inkRuns(of: container, scale: 4, from: from + 2, to: to)
            let probeIndex = try #require(runs.firstIndex { abs(($0.1 - $0.0) - size) <= 1.2 }, "\(mode.title): no probe in \(runs)")
            guard runs.indices.contains(probeIndex + 1) else { Issue.record("\(mode.title): no title after the icon"); continue }
            gaps[mode.title] = runs[probeIndex + 1].0 - runs[probeIndex].1 - (try bearing(of: mode.title))
        }
        return gaps
    }

    /// The system lays each title out a little differently (the gap varies by about 1.5 pt between Manual,
    /// Adaptive and Tabbed), so the check is the average gap, with a bound on each title. Both widths, Light and Dark.
    @Test func modePickerKeepsFourPointsBetweenTheIconAndTheTitle() throws {
        for dark in [false, true] {
            for width in [LayoutModePicker.Width.fillAvailable, .fitContent] {
                var sums: [String: [Double]] = [:]
                for selected in [LayoutMode.manual, .tabbed] {
                    for (title, gap) in try originGaps(dark: dark, selected: selected, width: width) { sums[title, default: []].append(gap) }
                }
                #expect(Set(sums.keys) == ["Manual", "Adaptive", "Tabbed"])
                let gaps = sums.mapValues { $0.reduce(0, +) / Double($0.count) }
                let mean = gaps.values.reduce(0, +) / Double(max(1, gaps.count))
                let label = "\(dark ? "dark" : "light") \(width): \(gaps)"
                #expect(abs(mean - LayoutModePicker.glyphSpacing) <= 0.6, "Mean gap \(mean), \(label)")
                for (title, gap) in gaps { #expect(abs(gap - LayoutModePicker.glyphSpacing) <= 1.6, "\(title) \(gap), \(label)") }
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
