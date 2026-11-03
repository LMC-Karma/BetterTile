import AppKit
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// Own test windows only, entirely offscreen. This is a CPU bitmap-capture
/// proxy with native glass enabled, not WindowServer/GPU presentation timing.
/// ImageRenderer keeps the drawn overlay visible; its glass is an offscreen
/// approximation and cannot establish actual backdrop refraction or contrast.
@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelRendererPerformanceTests {
    @Test func twoHundredMillisecondRevealCapture() throws {
        guard let directory = ProcessInfo.processInfo.environment["BT_WHEEL_BENCHMARK_DIR"] else { return }
        let folder = URL(filePath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var samples: [[String: Any]] = []
        for sector in [LayoutWheelSector.top, .left] {
            for iteration in -1..<20 {
                let clock = WheelTestClock()
                let scene = LayoutWheelGlassRenderer(clock: clock)
                let configuration = LayoutWheelConfiguration(style: .grouped)
                var input = LayoutWheelSceneInput(configuration: configuration)
                scene.configure(input, reduceMotion: false, reduceTransparency: false, increasedContrast: false)
                scene.appearance = NSAppearance(named: .darkAqua)
                let rect = scene.bounds
                let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
                window.contentView = scene; window.setFrameOrigin(.init(x: -10000, y: -10000))
                window.orderFront(nil)
                defer { scene.stop(); window.orderOutForTesting(); window.close() }
                func capture() throws -> NSBitmapImageRep {
                    scene.layoutSubtreeIfNeeded(); scene.displayIfNeeded()
                    let host = try #require(scene.hosting)
                    let renderer = ImageRenderer(content: host.rootView.environment(\.colorScheme, .dark))
                    renderer.scale = 2
                    return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                }
                _ = try capture()
                let point = LayoutWheelDrawnMetrics(input).iconPoint(.init(ring: .outer, sector: sector))
                input.fan.update(vector: point, at: 0, geometry: input.metrics.fanGeometry)
                input.fan.update(vector: point, at: 0.2, geometry: input.metrics.fanGeometry)
                input.selection = input.fan.selection
                scene.configure(input, reduceMotion: false, reduceTransparency: false, increasedContrast: false)
                #expect(scene.usesGlass)
                let epoch = CACurrentMediaTime()
                for tick in 1...12 {
                    let deadline = epoch + Double(tick) / 60
                    while CACurrentMediaTime() < deadline {
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: min(0.001, deadline - CACurrentMediaTime())))
                    }
                    clock.frame()
                    scene.layoutSubtreeIfNeeded(); scene.displayIfNeeded(); CATransaction.flush()
                }
                let start = CACurrentMediaTime()
                let bitmap = try capture()
                let cost = (CACurrentMediaTime() - start) * 1000
                #expect(scene.motion.isAtRest && !clock.isRunning)
                if iteration >= 0 {
                    samples.append(["options": LayoutWheelGroup.at(sector).options.count, "iteration": iteration,
                        "elapsed_s": start - epoch, "capture_ms": cost, "pixels": bitmap.pixelsWide,
                        "glass": scene.usesGlass, "rendered_frames": scene.renderedFrameCount])
                    if iteration == 0 {
                        try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("reveal-\(sector.rawValue).png"))
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: ["samples": samples,
            "method": "20 fresh opens plus warmup per three/six-option fan; 200ms reveal; 60Hz injected clock with real runloop; native regular glass fixed 30%; dark; Medium; offscreen NSWindow plus ImageRenderer 2x CPU proxy; cacheDisplay cannot capture native glass; not live optics or GPU timing",
            "os": ProcessInfo.processInfo.operatingSystemVersionString], options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("renderer.json"))
    }

    @Test func offscreenSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["BT_WHEEL_SNAPSHOT_DIR"] else { return }
        let folder = URL(filePath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (style, level, name) in [(LayoutWheelStyle.custom, LayoutWheelLevelCount.one, "custom-one"),
                                      (.custom, .two, "custom-two"), (.grouped, .two, "grouped-two")] {
            for scale in [0.8, 1.0, 1.2] {
                for dark in [false, true] {
                    for fallback in [false, true] {
                        for state in ["rest", "inner", "outer", "fan", "child", "unavailable"] {
                            if style == .custom && ["fan", "child"].contains(state) { continue }
                            var configuration = LayoutWheelConfiguration(style: style, levelCount: level)
                            configuration.scale = scale
                            let clock = WheelTestClock()
                            let renderer = LayoutWheelGlassRenderer(clock: clock)
                            defer { renderer.stop() }
                            var input = LayoutWheelSceneInput(configuration: configuration)
                            if state != "rest" {
                                input.selection = .init(ring: state == "inner" || level == .one ? .inner : .outer, sector: .top)
                            }
                            if ["fan", "child"].contains(state) {
                                let point = LayoutWheelDrawnMetrics(input).iconPoint(.init(ring: .outer, sector: .top))
                                input.fan.update(vector: point, at: 0, geometry: input.metrics.fanGeometry)
                                input.fan.update(vector: point, at: 0.2, geometry: input.metrics.fanGeometry)
                                if state == "child" { input.fan.handleKey(.nextSector) }
                                input.selection = input.fan.selection
                            }
                            if state == "unavailable", let selection = input.selection,
                               let command = configuration.command(at: selection) { input.unavailableCommands = [command] }
                            renderer.configure(input, reduceMotion: false, reduceTransparency: fallback, increasedContrast: false)
                            clock.settle()
                            let size = input.diameter
                            let host = try #require(renderer.hosting)
                            let image = ImageRenderer(content: ZStack {
                                WheelP1Fixture(dark: dark)
                                host.rootView
                            }.frame(width: size, height: size).environment(\.colorScheme, dark ? .dark : .light))
                            image.scale = 2
                            let bitmap = NSBitmapImageRep(cgImage: try #require(image.cgImage))
                            let filename = "\(name)-\(scale)-\(dark ? "dark" : "bright")-\(fallback ? "solid" : "glass")-\(state).png"
                            try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(filename))
                        }
                    }
                }
            }
        }
    }
}

private struct WheelP1Fixture: View {
    let dark: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [.init(red: 0.1, green: 0.1, blue: 0.2), .init(red: 0.3, green: 0.12, blue: 0.23)] : [.white, .init(white: 0.90)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 14) {
                Text("BetterTile sample window").font(.headline)
                ForEach(0..<8) { _ in Rectangle().fill(dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)).frame(height: 5) }
            }.foregroundStyle(dark ? .white : .black).padding(28)
        }
    }
}
