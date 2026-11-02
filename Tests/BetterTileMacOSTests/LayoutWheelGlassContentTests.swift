import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelGlassContentTests {
    /// Inspect the actual SwiftUI value tree, before native effect compositing.
    /// A later sibling is not content of the view carrying the glass modifier.
    @Test func centreInkIsContentOfTheGlassCarryingView() throws {
        let view = LayoutWheelGlassView(input: .init(configuration: .init()))
        var owners: [String] = []
        func visit(_ value: Any, depth: Int = 0) {
            guard depth < 40 else { return }
            let mirror = Mirror(reflecting: value)
            guard mirror.displayStyle != .class else { return }
            let children = Array(mirror.children)
            if let modifier = children.first(where: { $0.label == "modifier" }),
               String(reflecting: type(of: modifier.value)).contains("WheelWellGlass"),
               let content = children.first(where: { $0.label == "content" }) {
                owners.append(String(reflecting: type(of: content.value)))
            }
            for child in children { visit(child.value, depth: depth + 1) }
        }
        visit(view.body)
        let owner = try #require(owners.only)
        #expect(owner.contains("LayoutWheelLabelText"), "The measured label must belong to glass content: \(owner)")
        #expect(owner.contains("SwiftUI.Text"), "Cancel must belong to glass content: \(owner)")
        #expect(owner.contains("SwiftUI.Image"), "The cross and unavailable mark must belong to glass content: \(owner)")
    }

    @Test func truncatedFallbackAlsoSuppressesLean() throws {
        let renderer = LayoutWheelGlassRenderer(clock: WheelTestClock())
        defer { renderer.stop() }
        var input = LayoutWheelSceneInput(configuration: .init(levelCount: .two),
                                          selection: .init(ring: .inner, sector: .right))
        // Deliberately impossible presentation space exercises the future-name
        // fallback without adding an artificial catalog command.
        input.customMetrics = try #require(LayoutWheelMetrics(hubRadius: 5, innerRingOuterRadius: 6,
            outerRingInnerRadius: 7, outerRingOuterRadius: 8, oneLevelInnerRingOuterRadius: 6))
        #expect(input.centreLabel?.placement == .truncated)
        renderer.configure(input, reduceMotion: false)
        #expect(renderer.motion.lean.target == 0)
    }

    enum CentreState: CaseIterable {
        case rest, name, tag, parent, child, unavailable, unavailableTag
    }

    enum LensAppearance: CaseIterable {
        case nativeDark, solidDark, solidLight
        var scheme: ColorScheme { self == .solidLight ? .light : .dark }
        var glass: Bool { self == .nativeDark }
    }

    // Native offscreen Light material saturates to white, so its white outline
    // has no measurable contrast. Dark exercises native compositing; the opaque
    // controls cover both appearances with the same production layer order.
    @Test(arguments: LensAppearance.allCases)
    func hoveredLensArcDrawsAboveTheJoinedTag(appearance: LensAppearance) throws {
        let scheme = appearance.scheme, glass = appearance.glass
        var config = LayoutWheelConfiguration(levelCount: .two, scale: 0.8)
        config.innerSlots[LayoutWheelSector.right.rawValue] = .windowAction(.topRightQuarter)
        let selection = LayoutWheelSelection(ring: .inner, sector: .right)
        var input = LayoutWheelSceneInput(configuration: config, selection: selection)
        input.appearance.useLiquidGlass = glass
        let presentation = LayoutWheelLabelPresentation(input)
        #expect(presentation.label?.usesTag == true)
        let drawn = LayoutWheelDrawnMetrics(input)
        let point = drawn.iconPoint(selection)
        let arc = CGPoint(x: point.x - drawn.lensRadius(selection.ring), y: point.y)
        let shape = presentation.shape.path(in: CGRect(
            x: -presentation.size.width / 2, y: -presentation.size.height / 2,
            width: presentation.size.width, height: presentation.size.height))
        #expect(shape.contains(arc), "The sampled arc must overlap the tag")
        #expect(hypot(arc.x, arc.y) > drawn.wellRadius + 0.5)
        var hovered = LayoutWheelMotion()
        hovered.retarget(selection: selection, fan: input.fan, geometry: input.metrics.fanGeometry,
                         reduceMotion: true, suppressLean: true)
        let scene = LayoutWheelGlassRenderer(clock: WheelTestClock())
        defer { scene.stop() }
        scene.configure(input, reduceMotion: true, reduceTransparency: false, increasedContrast: false)
        #expect(scene.usesGlass == glass)
        func render(pulse: Double) throws -> NSBitmapImageRep {
            // Real glass modifiers and containers, with no contrast stand-in.
            // Change only outline opacity, so fill and icon pixels cannot pass.
            var view = try #require(scene.hosting).rootView
            view.motion = hovered
            view.pulse = pulse
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).accentColor(.black))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let baseline = try render(pulse: 0)
        let highlighted = try render(pulse: 1)
        let center = Double(highlighted.pixelsWide) / 2
        var peakArcDelta = 0.0
        for y in Int(center + arc.y * 2) - 2...Int(center + arc.y * 2) + 2 {
            for x in Int(center + arc.x * 2) - 2...Int(center + arc.x * 2) + 2 {
                let before = try #require(baseline.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let after = try #require(highlighted.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let backdrop = scheme == .dark ? 1.0 : 0.0
                let low = before.redComponent * before.alphaComponent + backdrop * (1 - before.alphaComponent)
                let high = after.redComponent * after.alphaComponent + backdrop * (1 - after.alphaComponent)
                peakArcDelta = max(peakArcDelta, high - low)
            }
        }
        // The one-point arc changes from 30% to 42% white. Its pixels
        // must survive the tag in both the native and opaque paths.
        #expect(peakArcDelta > 0.003, "Lens arc pixel change above the tag: \(peakArcDelta)")
        if let directory = ProcessInfo.processInfo.environment["BT_WHEEL_LENS_PROBE_DIR"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "\(scheme)-\(glass ? "glass" : "solid")"
            try highlighted.representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent(name + ".png"))
            try JSONSerialization.data(withJSONObject: ["arc_delta": peakArcDelta,
                "arc_x": arc.x, "arc_y": arc.y], options: [.sortedKeys])
                .write(to: folder.appendingPathComponent(name + ".json"))
        }
    }

    @Test(arguments: CentreState.allCases, [0.8, 1.0, 1.2])
    func nativeGlassRetainsCentreInk(state: CentreState, scale: Double) throws {
        var input = LayoutWheelSceneInput(configuration: .init(levelCount: .two, scale: scale))
        switch state {
        case .rest: break
        case .name: input.selection = .init(ring: .inner, sector: .top)
        case .tag, .unavailableTag:
            let command: LayoutWheelCommand
            if scale == 0.8 { command = .windowAction(.almostMaximize) }
            else {
                input.configuration.levelCount = .one
                command = .windowAction(.moveTabToPreviousPane)
            }
            input.configuration.innerSlots[LayoutWheelSector.right.rawValue] = command
            input.selection = .init(ring: .inner, sector: .right)
            #expect(input.centreLabel?.usesTag == true)
            if state == .unavailableTag { input.unavailableCommands = [command] }
        case .parent, .child:
            input.configuration.style = .grouped
            input.selection = .init(ring: .outer, sector: .top)
            if state == .child {
                let geometry = input.metrics.fanGeometry
                let point = BTPoint(x: 0, y: -124 * scale)
                input.fan.update(vector: point, at: 0, geometry: geometry)
                input.fan.update(vector: point, at: 0.2, geometry: geometry)
                input.fan.update(vector: geometry.point(sector: .top, option: 0), at: 0.21, geometry: geometry)
                input.selection = input.fan.selection
            }
        case .unavailable:
            input.selection = .init(ring: .outer, sector: .topLeft)
            input.unavailableCommands = [.repairBento]
        }
        let renderer = LayoutWheelGlassRenderer(clock: WheelTestClock())
        defer { renderer.stop() }
        renderer.configure(input, reduceMotion: true, reduceTransparency: false, increasedContrast: false)
        #expect(renderer.usesGlass)
        let image = ImageRenderer(content: try #require(renderer.hosting).rootView.environment(\.colorScheme, .dark))
        image.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try #require(image.cgImage))
        let center = Double(bitmap.pixelsWide) / 2
        let unavailable = state == .unavailable || state == .unavailableTag
        func ink(in rect: CGRect, threshold: Double) -> Int {
            var count = 0
            for y in Int(center + rect.minY * 2)..<Int(center + rect.maxY * 2) {
                for x in Int(center + rect.minX * 2)..<Int(center + rect.maxX * 2) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       color.alphaComponent > 0.8 && color.redComponent > threshold { count += 1 }
                }
            }
            return count
        }
        /// The brightest pixel, so a failure shows how far the ink missed.
        func brightest(in rect: CGRect) -> String {
            var best = (alpha: 0.0, red: 0.0)
            for y in Int(center + rect.minY * 2)..<Int(center + rect.maxY * 2) {
                for x in Int(center + rect.minX * 2)..<Int(center + rect.maxX * 2) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       color.alphaComponent * color.redComponent > best.alpha * best.red {
                        best = (color.alphaComponent, color.redComponent)
                    }
                }
            }
            return "brightest pixel alpha \(best.alpha), red \(best.red)"
        }
        // No stand-in: exercise the actual glass modifier and container. The
        // central crop excludes ring icons and the well outline.
        let centreCrop = CGRect(x: -24 * scale, y: -14 * scale, width: 48 * scale, height: 28 * scale)
        #expect(ink(in: centreCrop, threshold: unavailable ? 0.5 : 0.8) > 20, "\(brightest(in: centreCrop))")
        if unavailable {
            #expect(ink(in: CGRect(x: -6 * scale, y: -31 * scale, width: 12 * scale, height: 11 * scale),
                        threshold: 0.7) > 5)
        }
    }

    @Test func animationFramesReuseFirstRingBoxesAndJoinedOutline() throws {
        let clock = WheelTestClock()
        let renderer = LayoutWheelGlassRenderer(clock: clock)
        defer { renderer.stop() }
        var config = LayoutWheelConfiguration(levelCount: .two)
        config.innerSlots = Array(repeating: .setMode(.tabbed), count: 8)
        var input = LayoutWheelSceneInput(configuration: config, selection: .init(ring: .outer, sector: .right))
        renderer.configure(input, reduceMotion: false, reduceTransparency: false, increasedContrast: false)
        let initial = try #require(renderer.labelPresentation)
        #expect(initial.space.iconBoxes.count == 8)
        #expect(initial.shape.cachedOutline != nil)
        let bounds = CGRect(origin: .zero, size: initial.size)
        #expect(initial.shape.path(in: bounds) == LayoutWheelWellShape(tagSize: initial.tagSize).path(in: bounds))
        let preparations = LayoutWheelLabelPresentation.preparationCount
        for _ in 0..<60 {
            clock.frame()
            let view = try #require(renderer.hosting).rootView
            withExtendedLifetime(view.body) {}
            #expect(renderer.labelPresentation === initial)
            #expect(view.labelPresentation === initial)
        }
        #expect(LayoutWheelLabelPresentation.preparationCount == preparations)
        renderer.configure(input, reduceMotion: false, reduceTransparency: true, increasedContrast: false)
        #expect(renderer.labelPresentation === initial)
        input.selection = .init(ring: .outer, sector: .top)
        renderer.configure(input, reduceMotion: false, reduceTransparency: true, increasedContrast: false)
        #expect(renderer.labelPresentation !== initial)
        #expect(renderer.labelPresentation?.label == input.centreLabel)
    }

    @Test func symbolMeasurementStartupCost() throws {
        guard let directory = ProcessInfo.processInfo.environment["BT_WHEEL_SYMBOL_COST_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for level in [LayoutWheelLevelCount.two, .one] {
            for scale in [1.0, 0.8, 1.2] {
                let input = LayoutWheelSceneInput(configuration: .init(levelCount: level, scale: scale))
                for pass in ["cold", "warm"] {
                    let start = CACurrentMediaTime()
                    let space = LayoutWheelLabelSpace(input)
                    withExtendedLifetime(space) {}
                    records.append(["level": level.rawValue, "scale": scale, "pass": pass,
                                    "ms": (CACurrentMediaTime() - start) * 1000])
                }
            }
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("symbols.json"))
    }

    /// Opt-in capability probe. Hidden windows are never ordered onto a display.
    /// It records both paths rather than assuming cacheDisplay includes native
    /// WindowServer glass. The mandatory structure test above checks ownership.
    @Test func offscreenNativeGlassCaptureCapability() throws {
        guard let directory = ProcessInfo.processInfo.environment["BT_WHEEL_NATIVE_PROBE_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for glass in [false, true] {
            let renderer = LayoutWheelGlassRenderer(clock: WheelTestClock())
            renderer.configure(.init(configuration: .init()), reduceMotion: true,
                               reduceTransparency: !glass, increasedContrast: false)
            let host = try #require(renderer.hosting)
            host.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: renderer.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
            window.setFrameOrigin(.init(x: -20000, y: -20000))
            window.contentView = renderer
            defer { renderer.stop(); window.contentView = nil; window.close() }
            renderer.layoutSubtreeIfNeeded(); renderer.displayIfNeeded()
            CATransaction.flush()
            let cache = try #require(renderer.bitmapImageRepForCachingDisplay(in: renderer.bounds))
            renderer.cacheDisplay(in: renderer.bounds, to: cache)
            let image = ImageRenderer(content: host.rootView.environment(\.colorScheme, .dark))
            image.scale = 2
            let swiftUI = NSBitmapImageRep(cgImage: try #require(image.cgImage))
            for (method, bitmap) in [("cacheDisplay", cache), ("ImageRenderer", swiftUI)] {
                var visible = 0, ink = 0
                let size = Double(bitmap.pixelsWide), center = size / 2
                let scale = size / renderer.bounds.width
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        if color.alphaComponent > 0.1 { visible += 1 }
                        if abs(Double(x) - center) < 24 * scale,
                           abs(Double(y) - center) < 14 * scale,
                           color.alphaComponent > 0.8 && color.redComponent > 0.8 { ink += 1 }
                    }
                }
                let file = "\(glass ? "glass" : "solid")-\(method).png"
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(file))
                records.append(["glass": glass, "method": method, "visible_pixels": visible,
                                "centre_ink_pixels": ink, "window_visible": window.isVisible])
                if !glass && method == "ImageRenderer" { #expect(ink > 20) }
            }
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("native-capture.json"))
    }

    /// CPU preparation only: no raster capture, display link, sleep or GPU claim.
    @Test func labelPreparationCosts() throws {
        guard let directory = ProcessInfo.processInfo.environment["BT_WHEEL_LABEL_COST_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        func prepare(_ renderer: LayoutWheelGlassRenderer) throws {
            let view = try #require(renderer.hosting).rootView
            withExtendedLifetime(view.body) {}
        }
        let cold = LayoutWheelGlassRenderer(clock: WheelTestClock())
        let start = CACurrentMediaTime()
        cold.configure(.init(configuration: .init(levelCount: .two)), reduceMotion: true,
                       reduceTransparency: false, increasedContrast: false)
        try prepare(cold)
        records.append(["kind": "first_open", "ms": (CACurrentMediaTime() - start) * 1000])
        cold.stop()
        for glyphs in [false, true] {
            var config = LayoutWheelConfiguration(levelCount: .two)
            if glyphs { config.innerSlots = Array(repeating: .setMode(.tabbed), count: 8) }
            let input = LayoutWheelSceneInput(configuration: config, selection: .init(ring: .outer, sector: .right))
            let renderer = LayoutWheelGlassRenderer(clock: WheelTestClock())
            defer { renderer.stop() }
            renderer.configure(input, reduceMotion: true, reduceTransparency: false, increasedContrast: false)
            for _ in 0..<10 { try prepare(renderer) }
            for sample in 0..<20 {
                let start = CACurrentMediaTime()
                for _ in 0..<100 { try prepare(renderer) }
                records.append(["kind": glyphs ? "glyphs" : "default", "sample": sample,
                                "ms_per_body": (CACurrentMediaTime() - start) * 10])
            }
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("preparation.json"))
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
