import AppKit
import BetterTileCore
import CoreImage
import Testing
@testable import BetterTileMacOS

@Test(arguments: Array(2...12))
@MainActor func lensKnobMatchesEveryWidthSetting(thickness: Int) throws {
    let t = Double(thickness)
    for progress in [0.0, 0.5, 1] {
        for glass in [false, true] {
            let geometry = DividerLensGeometry(bounds: CGRect(x: 0, y: 0, width: max(18, 3 * t), height: 168),
                                               mode: .vertical(restingLength: 56, activeLength: 168),
                                               thickness: t, progress: progress, useLiquidGlass: glass)
            let knob = try #require(geometry.capsules.first)
            #expect(knob.width == CGFloat(glass ? t + 4 : t))
            #expect(knob.height == CGFloat(56 + 112 * progress - (glass ? 2 : 0)))
            #expect(geometry.bounds.contains(knob))
            #expect(DividerHandleGeometry.renderedThickness(t, useLiquidGlass: glass) == Double(knob.width))
        }
    }
}

@Test(arguments: [false, true], [NSAppearance.Name.aqua, .darkAqua,
                               .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
@MainActor func lensLimitUsesOrangeAtRestAndWhileActive(active: Bool, appearance: NSAppearance.Name) throws {
    let view = DividerHandleView(frame: CGRect(x: 0, y: 0, width: 30, height: 168),
                                 mode: .vertical(restingLength: 56, activeLength: 168), thickness: 10)
    view.appearance = NSAppearance(named: appearance)
    view.displayOptions = { (false, false) }
    view.setActive(active, animated: false)
    var accent: NSColor!
    var orange: NSColor!
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB)
        orange = NSColor.systemOrange.usingColorSpace(.deviceRGB)
    }
    #expect(view.lensTint.usingColorSpace(.deviceRGB) == accent)
    let rects = view.knobRects
    view.setLimit(DragLimit(width: true, blockedTowardPositive: true))
    #expect(view.lensTint.usingColorSpace(.deviceRGB) == orange)
    #expect(view.knobRects == rects)
    view.setLimit(DragLimit())
    #expect(view.lensTint.usingColorSpace(.deviceRGB) == accent)
}

@Test(arguments: [false, true], [(false, false), (true, false), (false, true)])
@MainActor func lensFallbacksHideAllDecoration(glass: Bool, options: (Bool, Bool)) throws {
    _ = NSApplication.shared
    let panel = DividerHandlePanel(frame: CGRect(x: -10_000, y: -10_000, width: 30, height: 168),
                                   mode: .vertical(restingLength: 56, activeLength: 168), thickness: 10)
    defer { panel.close() }
    let view = try #require(panel.contentView as? DividerHandleView)
    let decoration = try #require(panel.decorationWindow.contentView as? DividerLensDecorationView)
    view.displayOptions = { options }
    view.overlayAppearance.useLiquidGlass = glass
    let lens = glass && !options.0 && !options.1
    for active in [false, true] {
        view.setActive(active, animated: false)
        view.layoutSubtreeIfNeeded()
        #expect(view.showsGlass == lens)
        #expect(view.showsFrost == (!glass && !options.0 && !options.1))
        #expect(view.showsSolid == (options.0 || options.1))
        #expect(decoration.showsContent == lens)
        #expect(view.knobRects.first?.width == (glass ? 14 : 10))
    }
}

/// Glass off used to fill the handle with the label color at full opacity,
/// which is solid white in dark mode.
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor func glassOffHandleIsTranslucentFrost(appearance: NSAppearance.Name) throws {
    _ = NSApplication.shared
    let panel = DividerHandlePanel(frame: CGRect(x: -10_000, y: -10_000, width: 30, height: 168),
                                   mode: .vertical(restingLength: 56, activeLength: 168), thickness: 8)
    defer { panel.close() }
    let view = try #require(panel.contentView as? DividerHandleView)
    view.appearance = NSAppearance(named: appearance)
    view.displayOptions = { (false, false) }
    view.overlayAppearance.useLiquidGlass = false
    view.layoutSubtreeIfNeeded()
    #expect(view.showsFrost && !view.showsSolid && !view.showsGlass)
    #expect(view.frostBlendingMode == .behindWindow)
    var grey: NSColor!
    var accent: NSColor!
    var orange: NSColor!
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        grey = NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB)
        accent = NSColor.controlAccentColor.withAlphaComponent(0.88).usingColorSpace(.deviceRGB)
        orange = NSColor.systemOrange.usingColorSpace(.deviceRGB)
    }
    func close(_ color: NSColor?, _ expected: NSColor) -> Bool {
        guard let color = color?.usingColorSpace(.deviceRGB) else { return false }
        return [color.redComponent - expected.redComponent, color.greenComponent - expected.greenComponent,
                color.blueComponent - expected.blueComponent, color.alphaComponent - expected.alphaComponent]
            .allSatisfy { abs($0) < 0.02 }
    }
    #expect(close(view.frostColor, grey))
    #expect(grey.alphaComponent < 0.9)
    view.setActive(true, animated: false)
    #expect(close(view.frostColor, accent))
    view.setLimit(DragLimit(width: true, blockedTowardPositive: true))
    #expect(close(view.frostColor, orange))
    view.displayOptions = { (true, false) }
    #expect(view.showsSolid && !view.showsFrost)
    view.displayOptions = { (false, false) }
    #expect(view.showsFrost && !view.showsSolid)
    #expect(view.knobRects.first?.width == 8)
}

@Test @MainActor func settingsPreviewFrostBlursItsOwnWindow() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 180, height: 180),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let preview = DividerLensPreviewView(frame: CGRect(x: 0, y: 0, width: 180, height: 180),
                                         mode: .vertical(restingLength: 56, activeLength: 168), thickness: 8)
    preview.handleView.displayOptions = { (false, false) }
    preview.handleView.overlayAppearance.useLiquidGlass = false
    window.contentView?.addSubview(preview)
    #expect(preview.handleView.showsFrost)
    #expect(preview.handleView.frostBlendingMode == .withinWindow)
}

@Test @MainActor func accessibilityChangesRefreshAVisibleLens() async throws {
    _ = NSApplication.shared
    let panel = DividerHandlePanel(frame: CGRect(x: -10_000, y: -10_000, width: 30, height: 168),
                                   mode: .vertical(restingLength: 56, activeLength: 168), thickness: 10)
    defer { panel.close() }
    let view = try #require(panel.contentView as? DividerHandleView)
    let decoration = try #require(panel.decorationWindow.contentView as? DividerLensDecorationView)
    var options = (false, false)
    view.displayOptions = { options }
    panel.orderFrontRegardless()
    for next in [(true, false), (false, true), (false, false)] {
        options = next
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                   object: nil)
        await Task.yield()
        #expect(view.showsGlass == (!next.0 && !next.1))
        #expect(view.showsSolid == (next.0 || next.1))
        #expect(decoration.showsContent == (!next.0 && !next.1))
    }
}

@Test @MainActor func lensJunctionClosesTheConcaveCornerWithAFillet() throws {
    let view = DividerHandleView(frame: CGRect(x: 0, y: 0, width: 92, height: 92),
                                 mode: .junction(center: CGPoint(x: 46, y: 46),
                                                 resting: [.left: 12, .right: 12, .up: 12, .down: 12],
                                                 active: [.left: 36, .right: 36, .up: 36, .down: 36]), thickness: 10)
    view.displayOptions = { (false, false) }
    view.setActive(true, animated: false)
    view.layoutSubtreeIfNeeded()
    let shape = try #require(view.knobOutline)
    // T = 14, r = 6.3. The raw union leaves this upper-right corner empty.
    let inward = 0.3 * 6.3 / sqrt(2.0)
    let point = CGPoint(x: 53 + inward, y: 53 + inward)
    #expect(view.knobRects.allSatisfy { !capsulePath($0).contains(point) })
    #expect(shape.contains(point))
    #expect(!shape.contains(CGPoint(x: 53 + 6.3, y: 53 + 6.3)))
    #expect(shape.contains(CGPoint(x: 46, y: 46)))
}

@Test(arguments: [SplitAxis.vertical, .horizontal])
@MainActor func lensTrackClipsAsymmetricallyToTheUsableSpan(axis: SplitAxis) throws {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
    let mode: DividerHandleMode = axis == .vertical
        ? .vertical(restingLength: 56, activeLength: 168)
        : .horizontal(restingLength: 56, activeLength: 168)
    let room: [DividerHandleArm: Double] = axis == .vertical ? [.up: 35, .down: 27] : [.left: 27, .right: 35]
    for progress in [0.0, 0.5, 1.0] {
        let geometry = DividerLensGeometry(bounds: bounds, mode: mode, thickness: 10,
                                           progress: progress, trackRoom: room)
        let track = try #require(geometry.trackRects.first)
        // Local +y is up. In top-left coordinates these are spanStart + 8
        // and spanEnd - 8, so neither end can extend into a neighboring pane.
        #expect(axis == .vertical ? track.minY == 73 : track.minX == 73)
        #expect(axis == .vertical ? track.maxY == 135 : track.maxX == 135)
        #expect(axis == .vertical ? track.width == 2.94 : track.height == 2.94)
    }
}

@Test @MainActor func lensJunctionTracksRespectEachIndependentArmRoom() throws {
    let geometry = DividerLensGeometry(
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        mode: .junction(center: CGPoint(x: 100, y: 100),
                        resting: [.left: 12, .right: 12, .up: 12, .down: 12],
                        active: [.left: 36, .right: 36, .up: 36, .down: 36]),
        thickness: 10, progress: 1, trackRoom: [.left: 20, .right: 65, .up: 35, .down: 75]
    )
    #expect(geometry.trackRects == [CGRect(x: 80, y: 98.53, width: 85, height: 2.94),
                                  CGRect(x: 98.53, y: 25, width: 2.94, height: 110)])
}

@Test(arguments: [SplitAxis.vertical, .horizontal], [0.0, 1.0])
@MainActor func shortestDividerTrackKeepsItsAxisAndSpan(axis: SplitAxis, progress: Double) throws {
    // The resolver accepts a 24 pt span. Its 8 pt end margins leave 8 pt
    // for the handle, shorter than even the resting lens thickness.
    let vertical = axis == .vertical
    let geometry = DividerLensGeometry(
        bounds: CGRect(x: 0, y: 0, width: vertical ? 30 : 8, height: vertical ? 8 : 30),
        mode: vertical ? .vertical(restingLength: 8, activeLength: 8)
            : .horizontal(restingLength: 8, activeLength: 8),
        thickness: 10, progress: progress,
        trackRoom: vertical ? [.up: 4, .down: 4] : [.left: 4, .right: 4]
    )
    let track = try #require(geometry.trackRects.first)
    #expect(track == (vertical ? CGRect(x: 13.53, y: 0, width: 2.94, height: 8)
        : CGRect(x: 0, y: 13.53, width: 8, height: 2.94)))
}

@Test @MainActor func junctionWithoutHorizontalRoomDoesNotDuplicateItsVerticalTrack() {
    let geometry = DividerLensGeometry(
        bounds: CGRect(x: 0, y: 0, width: 20, height: 92),
        mode: .junction(center: CGPoint(x: 10, y: 46),
                        resting: [.up: 12, .down: 12], active: [.up: 36, .down: 36]),
        thickness: 10, progress: 1, trackRoom: [.left: 0, .right: 0, .up: 46, .down: 46]
    )
    #expect(geometry.trackRects[0].width == 0)
    #expect(geometry.trackRects[1] == CGRect(x: 8.53, y: 0, width: 2.94, height: 92))
}

@Test @MainActor func squareHorizontalLensKeepsItsTrackDirection() {
    let geometry = DividerLensGeometry(bounds: CGRect(x: 0, y: 0, width: 16, height: 30),
                                       mode: .horizontal(restingLength: 16, activeLength: 16), thickness: 10,
                                       progress: 0, trackRoom: [.left: 8, .right: 8])
    #expect(geometry.capsuleAxes == [.horizontal])
    #expect(geometry.trackRects == [CGRect(x: 0, y: 13.53, width: 16, height: 2.94)])
}

@Test(arguments: [DividerPreviewShape.up, .down, .left, .right])
@MainActor func settingsJunctionTrackStopsAtItsMissingArm(shape: DividerPreviewShape) throws {
    let sample = shape.sample(in: BTRect(x: 0, y: 0, width: 240, height: 180),
                              position: CGPoint(x: 0.5, y: 0.5), paneGap: 10)
    let missing: DividerHandleArm = switch shape {
    case .up: .down
    case .down: .up
    case .left: .right
    default: .left
    }
    #expect(sample.trackRoom[missing] == 0)
    let preview = DividerLensPreviewView(frame: CGRect(x: 0, y: 0, width: 180, height: 180),
                                        mode: sample.mode(thickness: 10), thickness: 10,
                                        trackRoom: sample.trackRoom)
    for active in [false, true] {
        preview.handleView.setActive(active, animated: false)
        preview.layoutSubtreeIfNeeded()
        let tracks = preview.handleView.trackRects
        switch missing {
        case .up: #expect(tracks[1].maxY == 90)
        case .down: #expect(tracks[1].minY == 90)
        case .left: #expect(tracks[0].minX == 90)
        case .right: #expect(tracks[0].maxX == 90)
        }
    }
}

@Test(arguments: [0.0, 0.25, 0.5, 0.75, 1.0])
@MainActor func lensGeometryFollowsEasedProgressWithoutExtraAnimation(progress: Double) throws {
    let geometry = DividerLensGeometry(bounds: CGRect(x: 0, y: 0, width: 30, height: 168),
                                       mode: .vertical(restingLength: 56, activeLength: 168),
                                       thickness: 10, progress: progress)
    let knob = try #require(geometry.capsules.first)
    #expect(knob.width == CGFloat(14))
    #expect(knob.height == CGFloat(54 + 112 * progress))
    #expect(knob.midX == 15)
    #expect(knob.midY == 84)
    let track = try #require(geometry.trackRects.first)
    #expect(track.height == knob.height + CGFloat(2 * (16 + 54 * progress)))
    let layers = DividerLensLayers()
    layers.apply(geometry: geometry, margins: .zero, tint: .controlAccentColor, dark: true,
                 strength: 0.5, limited: false, p: progress)
    let host = layers.trackHosts[0]
    let start = try #require(host.value(forKeyPath: "filters.lens.inputPoint0") as? CIVector)
    let end = try #require(host.value(forKeyPath: "filters.lens.inputPoint1") as? CIVector)
    #expect(start.y == knob.minY + 7)
    #expect(end.y == knob.maxY - 7)
    #expect(host.isHidden == (progress == 0))
    let gradient = try #require(host.sublayers?.first as? CAGradientLayer)
    let colors = try #require(gradient.colors as? [CGColor])
    #expect(colors.map(\.alpha) == [0, CGFloat(progress), CGFloat(progress), 0])


}

@Test(arguments: [SplitAxis.vertical, .horizontal])
@MainActor func lensDecorationPanelFollowsItsHandleFrameAndVisibility(axis: SplitAxis) throws {
    _ = NSApplication.shared
    let mode: DividerHandleMode = axis == .vertical
        ? .vertical(restingLength: 56, activeLength: 168)
        : .horizontal(restingLength: 56, activeLength: 168)
    let frame = axis == .vertical ? CGRect(x: 100, y: 100, width: 30, height: 168)
        : CGRect(x: 100, y: 100, width: 168, height: 30)
    let panel = DividerHandlePanel(frame: frame, mode: mode, thickness: 10)
    defer { panel.close() }
    let decoration = panel.decorationWindow
    #expect(decoration.ignoresMouseEvents)
    #expect(!decoration.isOpaque)
    #expect(!decoration.hasShadow)
    #expect(decoration.level == .floating)
    #expect(panel.level == .floating)
    #expect(decoration.collectionBehavior == panel.collectionBehavior)
    #expect(decoration.parent === panel)
    #expect(panel.childWindows?.contains(decoration) == true)
    let dx = axis == .vertical ? 24.0 : 84.0
    let dy = axis == .vertical ? 84.0 : 24.0
    #expect(decoration.frame == frame.insetBy(dx: -dx, dy: -dy))
    let moved = frame.offsetBy(dx: 45, dy: -25)
    panel.setFrame(moved, display: true)
    #expect(decoration.frame == moved.insetBy(dx: -dx, dy: -dy))
    panel.orderFrontRegardless()
    #expect(panel.isVisible)
    #expect(decoration.isVisible)
    let ordered = try #require(NSWindow.windowNumbers(options: [])).map(\.intValue)
    let handleIndex = try #require(ordered.firstIndex(of: panel.windowNumber))
    let decorationIndex = try #require(ordered.firstIndex(of: decoration.windowNumber))
    #expect(handleIndex < decorationIndex)
    panel.orderOut(nil)
    #expect(!panel.isVisible)
    #expect(!decoration.isVisible)
    panel.orderFrontRegardless()
    #expect(decoration.isVisible)
}

@Test @MainActor func lensJunctionDecorationHasRoomOnEverySide() {
    _ = NSApplication.shared
    let frame = CGRect(x: 100, y: 100, width: 92, height: 92)
    let arms: [DividerHandleArm: Double] = [.left: 36, .right: 36, .up: 36, .down: 36]
    let panel = DividerHandlePanel(frame: frame,
                                   mode: .junction(center: CGPoint(x: 46, y: 46), resting: arms, active: arms), thickness: 10)
    defer { panel.close() }
    #expect(panel.decorationWindow.frame == frame.insetBy(dx: -84, dy: -84))
    #expect(!DividerOverlayController.ownWindowCoversHandle(frame, windows: [panel.decorationWindow], excluding: []))
}

@Test @MainActor func changingDividerModeMovesDecorationOnlyWithTheFinalFrame() throws {
    _ = NSApplication.shared
    let panel = DividerHandlePanel(frame: CGRect(x: 100, y: 100, width: 30, height: 56),
                                   mode: .vertical(restingLength: 56, activeLength: 168), thickness: 10)
    defer { panel.close() }
    let arms: [DividerHandleArm: Double] = [.left: 12, .right: 12, .up: 12, .down: 12]
    let transitions: [(DividerHandleMode, CGRect, CGFloat, CGFloat)] = [
        (.junction(center: CGPoint(x: 22, y: 22), resting: arms, active: arms),
         CGRect(x: 200, y: 200, width: 44, height: 44), 84, 84),
        (.horizontal(restingLength: 56, activeLength: 168),
         CGRect(x: 300, y: 300, width: 56, height: 30), 84, 24),
        (.vertical(restingLength: 56, activeLength: 168),
         CGRect(x: 400, y: 400, width: 30, height: 56), 24, 84),
    ]
    for (mode, frame, marginX, marginY) in transitions {
        let previousDecorationFrame = panel.decorationWindow.frame
        panel.configure(mode: mode, thickness: 10)
        #expect(panel.decorationWindow.frame == previousDecorationFrame)
        panel.setFrame(frame, display: true)
        #expect(panel.decorationWindow.frame == frame.insetBy(dx: -marginX, dy: -marginY))
        let view = try #require(panel.contentView as? DividerHandleView)
        #expect(view.knobRects.allSatisfy { view.bounds.contains($0) })
    }
}

@MainActor private func lensLayerTree(_ root: CALayer) -> [CALayer] {
    [root] + (root.sublayers ?? []).flatMap(lensLayerTree) + (root.mask.map(lensLayerTree) ?? [])
}

@MainActor private final class RetinaLensTestPanel: NSPanel {
    override var backingScaleFactor: CGFloat { 2 }
}

@Test @MainActor func lensLayersUseRetinaScaleAndRemainReusable() throws {
    _ = NSApplication.shared
    let panel = RetinaLensTestPanel(contentRect: CGRect(x: -10_000, y: -10_000, width: 30, height: 168),
                                    styleMask: .borderless, backing: .buffered, defer: false)
    defer { panel.close() }
    let view = DividerHandleView(frame: CGRect(x: 0, y: 0, width: 30, height: 168),
                                 mode: .vertical(restingLength: 56, activeLength: 168), thickness: 10)
    view.displayOptions = { (false, false) }
    panel.contentView = view
    view.viewDidChangeBackingProperties()
    view.layoutSubtreeIfNeeded()
    let root = try #require(view.layer)
    // AppKit controls the hosting layer's scale from the real display,
    // independently of the panel's injected scale. Check our layers only.
    let initial = (root.sublayers ?? []).flatMap(lensLayerTree)
    let decoration = lensLayerTree(view.lensLayers.decorationLayer)
    #expect(initial.count > 8)
    #expect(initial.allSatisfy { $0.contentsScale == 2 })
    #expect(decoration.allSatisfy { $0.contentsScale == 2 })
    view.setActive(true, animated: false)
    view.setLimit(DragLimit(width: true, blockedTowardPositive: true))
    view.overlayAppearance.strength = 1
    view.layoutSubtreeIfNeeded()
    let updated = (root.sublayers ?? []).flatMap(lensLayerTree)
    #expect(updated.map(ObjectIdentifier.init) == initial.map(ObjectIdentifier.init))
    #expect(updated.allSatisfy { $0.contentsScale == 2 })
    #expect(updated.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    #expect(lensLayerTree(view.lensLayers.decorationLayer).map(ObjectIdentifier.init)
        == decoration.map(ObjectIdentifier.init))
    #expect(decoration.allSatisfy { $0.contentsScale == 2 && ($0.animationKeys() ?? []).isEmpty })
}

/// Captures only this test's own opaque window. The full row preserves track
/// reach and panel margins; the second row enlarges the real views for inspection.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_GLASS_PREVIEW_DIR"] != nil,
               "Requires an explicit native glass preview output directory."))
@MainActor func nativeDividerLensPreviews() async throws {
    _ = NSApplication.shared
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_GLASS_PREVIEW_DIR"])
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let size = CGSize(width: 990, height: 810)
    let panel = NSPanel(contentRect: CGRect(origin: CGPoint(x: 60, y: 60), size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.isOpaque = true
    defer { panel.close() }
    #expect(panel.backingScaleFactor == 2, "Inspect these previews on a Retina display.")
    for (name, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        let dark = name == "dark"
        panel.appearance = NSAppearance(named: appearanceName)
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: dark ? 0.08 : 0.93, alpha: 1).cgColor
        panel.contentView = root
        let titles = ["Resting", "Dragging", "Dragging at limit", "Junction, dragging"]
        for (index, title) in titles.enumerated() {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.frame = CGRect(x: 150 + index * 210, y: 775, width: 205, height: 22)
            root.addSubview(label)
            let cell = DividerLensSceneView(frame: CGRect(x: 150 + index * 210, y: 455, width: 200, height: 300),
                                            dark: dark, junction: index == 3, active: index > 0)
            root.addSubview(cell)
            addNativeLens(to: cell, state: index, scale: 1)
            let zoom = DividerLensSceneView(frame: CGRect(x: 10 + index * 245, y: 0, width: 235, height: 420),
                                            dark: dark, junction: index == 3, active: index > 0, magnification: 3)
            root.addSubview(zoom)
            addNativeLens(to: zoom, state: index, scale: index == 0 ? 3 : (index == 3 ? 2 : 2.2))
        }
        for (text, frame) in [("Lens knob", CGRect(x: 12, y: 590, width: 130, height: 24)),
                              ("Close-up", CGRect(x: 12, y: 426, width: 300, height: 24))] {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.frame = frame
            root.addSubview(label)
        }
        root.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(300))
        let output = URL(fileURLWithPath: directory).appendingPathComponent("divider-lens-\(name)-2x.png")
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), output.path]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        #expect(bitmap.pixelsWide == 1980)
        #expect(bitmap.pixelsHigh == 1620)
    }
}

@MainActor private func addNativeLens(to cell: NSView, state: Int, scale: CGFloat, thickness: Double = 10, strength: Double = 0.5) {
    let junction = state == 3
    let handleSize = junction ? CGSize(width: 86, height: 86) : CGSize(width: 30, height: 168)
    let mode: DividerHandleMode = junction
        ? .junction(center: CGPoint(x: 43, y: 43),
                    resting: [.left: 12, .right: 12, .up: 12, .down: 12],
                    active: [.left: 36, .right: 36, .up: 36, .down: 36])
        : .vertical(restingLength: 56, activeLength: 168)
    let wrapper = NSView(frame: cell.bounds)
    wrapper.setBoundsSize(CGSize(width: cell.bounds.width / scale, height: cell.bounds.height / scale))
    cell.addSubview(wrapper)
    let frame = CGRect(x: wrapper.bounds.midX - handleSize.width / 2,
                       y: wrapper.bounds.midY - handleSize.height / 2,
                       width: handleSize.width, height: handleSize.height)
    let preview = DividerLensPreviewView(frame: frame, mode: mode, thickness: thickness)
    wrapper.addSubview(preview)
    let handle = preview.handleView
    handle.displayOptions = { (false, false) }
    handle.overlayAppearance = OverlayAppearance(strength: strength)
    let verticalRoom = max(142, wrapper.bounds.height / 2 - 8 / scale)
    let horizontalRoom = max(92, wrapper.bounds.width / 2 - 8 / scale)
    handle.configure(mode: mode, thickness: thickness,
                     trackRoom: [.up: verticalRoom, .down: verticalRoom, .left: horizontalRoom, .right: horizontalRoom])
    handle.setActive(state > 0, animated: false)
    if state == 2 { handle.setLimit(DragLimit(width: true, blockedTowardPositive: true)) }
    preview.layoutSubtreeIfNeeded()
}

/// A deterministic backdrop with two columns, or four panes at a junction.
/// Every pixel belongs to this test; no desktop or other application is sampled.
@MainActor private final class DividerLensSceneView: NSView {
    let dark: Bool
    let junction: Bool
    let active: Bool
    let magnification: CGFloat

    init(frame: CGRect, dark: Bool, junction: Bool, active: Bool, magnification: CGFloat = 1) {
        self.dark = dark
        self.junction = junction
        self.active = active
        self.magnification = magnification
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let top = dark ? NSColor(red: 0.05, green: 0.08, blue: 0.16, alpha: 1)
            : NSColor(red: 0.75, green: 0.82, blue: 0.95, alpha: 1)
        let bottom = dark ? NSColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
            : NSColor(red: 0.88, green: 0.86, blue: 0.95, alpha: 1)
        NSGradient(starting: bottom, ending: top)?.draw(in: bounds, angle: 90)
        let gap = 10 * magnification
        let columns = [CGRect(x: 4, y: 4, width: bounds.midX - gap / 2 - 4, height: bounds.height - 8),
                       CGRect(x: bounds.midX + gap / 2, y: 4, width: bounds.midX - gap / 2 - 4, height: bounds.height - 8)]
        for (column, fullHeight) in columns.enumerated() {
            let panes = junction
                ? [CGRect(x: fullHeight.minX, y: 4, width: fullHeight.width, height: bounds.midY - gap / 2 - 4),
                   CGRect(x: fullHeight.minX, y: bounds.midY + gap / 2, width: fullHeight.width,
                          height: bounds.midY - gap / 2 - 4)] : [fullHeight]
            for pane in panes {
                let fill = column == 0 ? NSColor(white: dark ? 0.16 : 0.97, alpha: 1)
                    : NSColor(red: dark ? 0.18 : 0.95, green: dark ? 0.16 : 0.94, blue: dark ? 0.22 : 0.98, alpha: 1)
                fill.setFill()
                let shape = NSBezierPath(roundedRect: pane, xRadius: 12 * magnification, yRadius: 12 * magnification)
                shape.fill()
                if active {
                    NSColor.controlAccentColor.withAlphaComponent(0.78).setStroke()
                    shape.lineWidth = 2 * magnification
                    shape.stroke()
                }
                NSColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.10).setFill()
                for row in 0..<Int(max(0, (pane.height - 32 * magnification) / (22 * magnification))) {
                    let line = CGRect(x: pane.minX + 14 * magnification,
                                      y: pane.minY + 16 * magnification + CGFloat(row) * 22 * magnification,
                                      width: max(20, pane.width * (0.55 + 0.06 * CGFloat(row % 5)) - 14 * magnification),
                                      height: 8 * magnification)
                    NSBezierPath(roundedRect: line, xRadius: 4 * magnification, yRadius: 4 * magnification).fill()
                }
            }
        }
    }
}

@Test(arguments: [0.0, 0.5, 0.75, 1.0], [false, true])
@MainActor func lensFrostControlsOnlyBodyAndOptionalBlur(strength: Double, dark: Bool) throws {
    let view = DividerHandleView(frame: CGRect(x: 0, y: 0, width: 30, height: 168),
                                 mode: .vertical(restingLength: 56, activeLength: 168), thickness: 10)
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.displayOptions = { (false, false) }
    view.overlayAppearance.strength = strength
    view.setActive(true, animated: false)
    let alpha = try #require(view.lensLayers.body.fillColor?.alpha)
    #expect(abs(alpha - ((dark ? 0.02 : 0.12) + (dark ? 0.12 : 0.40) * strength)) < 0.000001)
    let host = view.lensLayers.trackHosts[0]
    let filters = try #require(host.filters as? [CIFilter])
    #expect(filters.map(\.name) == (strength > 0.5 ? ["lens", "frost"] : ["lens"]))
    #expect(host.value(forKeyPath: "filters.lens.inputRefraction") as? Double == 1.2)
    if strength > 0.5 {
        #expect(host.value(forKeyPath: "filters.frost.inputRadius") as? Double == (strength - 0.5) * 5)
    }
}

@Test(arguments: ["CIGlassLozenge", "CIGaussianBlur", "all"])
@MainActor func missingLensFilterUsesFrostedHandle(missing: String) throws {
    let layers = DividerLensLayers { name in
        missing == "all" || name == missing ? nil : CIFilter(name: name)
    }
    let view = DividerHandleView(frame: CGRect(x: 0, y: 0, width: 30, height: 168),
                                 mode: .vertical(restingLength: 56, activeLength: 168),
                                 thickness: 10, lensLayers: layers)
    view.displayOptions = { (false, false) }
    #expect(!layers.isAvailable)
    for strength in [0.0, 1.0] {
        view.overlayAppearance.strength = strength
        for active in [false, true] {
            view.setActive(active, animated: false)
            #expect(view.showsFrost)
            #expect(!view.showsSolid && !view.showsGlass)
            #expect(layers.decorationLayer.isHidden)
            let knob = try #require(view.knobRects.first)
            #expect(knob.width == 14)
            #expect(knob.height == (active ? 166 : 54))
            #expect(view.hitTest(CGPoint(x: 15, y: 84)) === view)
        }
    }
}

@Test(arguments: [false, true])
@MainActor func lensFiltersFollowEndCapsAndRetainInstances(junction: Bool) throws {
    let mode: DividerHandleMode = junction
        ? .junction(center: CGPoint(x: 43, y: 43), resting: [.left: 12, .right: 12, .up: 12, .down: 12],
                    active: [.left: 36, .right: 36, .up: 36, .down: 36])
        : .vertical(restingLength: 56, activeLength: 168)
    let view = DividerHandleView(frame: CGRect(x: 0, y: 0, width: junction ? 86 : 30, height: junction ? 86 : 168),
                                 mode: mode, thickness: 10)
    view.displayOptions = { (false, false) }
    let chains = view.lensLayers.filterChainUpdateCount
    #expect(view.lensLayers.trackHosts.allSatisfy { $0.isHidden })
    for active in [true, false, true] {
        view.setActive(active, animated: false)
        for (index, rect) in view.knobRects.enumerated() {
            let host = view.lensLayers.trackHosts[index]
            let vertical = !junction || index == 1
            let p0 = try #require(host.value(forKeyPath: "filters.lens.inputPoint0") as? CIVector)
            let p1 = try #require(host.value(forKeyPath: "filters.lens.inputPoint1") as? CIVector)
            #expect(p0.x == (vertical ? rect.midX : rect.minX + 7))
            #expect(p0.y == (vertical ? rect.minY + 7 : rect.midY))
            #expect(p1.x == (vertical ? rect.midX : rect.maxX - 7))
            #expect(p1.y == (vertical ? rect.maxY - 7 : rect.midY))
            #expect(host.value(forKeyPath: "filters.lens.inputRadius") as? Double == 7)
            #expect(host.isHidden == !active)
            #expect(view.lensLayers.filterChainUpdateCount == chains)
        }
        let layers = lensLayerTree(view.lensLayers.handleLayer) + lensLayerTree(view.lensLayers.decorationLayer)
        #expect(layers.allSatisfy { $0.mask == nil && !$0.masksToBounds })
        #expect(layers.filter { $0.shadowOpacity > 0 && !$0.isHidden }.allSatisfy { $0.shadowPath != nil })
    }
}

@Test @MainActor func repeatedLensUpdatesReuseGeometryAndSkipLayerChanges() {
    let mode = DividerHandleMode.vertical(restingLength: 56, activeLength: 168)
    let view = DividerHandleView(frame: CGRect(x: 0, y: 0, width: 30, height: 168), mode: mode, thickness: 10)
    view.displayOptions = { (false, false) }
    view.layoutSubtreeIfNeeded()
    let builds = view.outlineBuildCount
    let updates = view.appearanceUpdateCount
    let outline = view.knobOutline
    for _ in 0..<5 {
        view.configure(mode: mode, thickness: 10)
        view.overlayAppearance = OverlayAppearance()
        view.layout()
    }
    #expect(view.outlineBuildCount == builds)
    #expect(view.appearanceUpdateCount == updates)
    view.configure(mode: mode, thickness: 10, trackRoom: [.up: 100, .down: 110])
    view.layoutSubtreeIfNeeded()
    #expect(view.outlineBuildCount == builds)
    #expect(view.knobOutline === outline)
    view.overlayAppearance.strength = 1
    #expect(view.outlineBuildCount == builds)
}

/// Width and frost sweeps use the production views on a synthetic backdrop.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_GLASS_PREVIEW_DIR"] != nil,
               "Requires an explicit native glass preview output directory."))
@MainActor func nativeDividerLensSettingsPreviews() async throws {
    _ = NSApplication.shared
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_GLASS_PREVIEW_DIR"])
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let size = CGSize(width: 980, height: 1060)
    let panel = NSPanel(contentRect: CGRect(origin: CGPoint(x: 40, y: 40), size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.isOpaque = true
    defer { panel.close() }
    for (name, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        let dark = name == "dark"
        panel.appearance = NSAppearance(named: appearanceName)
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: dark ? 0.08 : 0.93, alpha: 1).cgColor
        panel.contentView = root
        for row in 0..<4 {
            let widths = row < 2 ? [2.0, 4, 6, 8, 10, 12] : [10.0, 10, 10, 10, 10]
            for (column, width) in widths.enumerated() {
                let strength = row < 2 ? 0.5 : Double(column) / 4
                let active = row % 2 == 1
                let x = 145 + CGFloat(column) * 136
                let y = 790 - CGFloat(row) * 260
                let label = NSTextField(labelWithString: row < 2 ? "\(Int(width)) pt" : "\(Int((1 - strength) * 100))% clear")
                label.frame = CGRect(x: x, y: y + 234, width: 130, height: 20)
                root.addSubview(label)
                let cell = DividerLensSceneView(frame: CGRect(x: x, y: y, width: 130, height: 230),
                                                dark: dark, junction: false, active: active)
                root.addSubview(cell)
                addNativeLens(to: cell, state: active ? 1 : 0, scale: 1, thickness: width, strength: strength)
            }
            let label = NSTextField(labelWithString: "\(row < 2 ? "Width" : "Transparency")\n\(row % 2 == 1 ? "Grabbed" : "Resting")")
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.frame = CGRect(x: 12, y: 880 - CGFloat(row) * 260, width: 130, height: 45)
            root.addSubview(label)
        }
        root.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(300))
        let output = URL(fileURLWithPath: directory).appendingPathComponent("divider-lens-settings-\(name)-2x.png")
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), output.path]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        #expect(bitmap.pixelsWide == Int(size.width * panel.backingScaleFactor))
        #expect(bitmap.pixelsHigh == Int(size.height * panel.backingScaleFactor))
    }
}

@Test @MainActor func movingAlongAnAmpleSeamDoesNotUpdateLensLayers() {
    let mode = DividerHandleMode.junction(center: CGPoint(x: 43, y: 43),
                                          resting: [.left: 12, .right: 12, .up: 12, .down: 12],
                                          active: [.left: 36, .right: 36, .up: 36, .down: 36])
    let view = DividerHandleView(frame: CGRect(x: 0, y: 0, width: 86, height: 86), mode: mode, thickness: 10)
    view.displayOptions = { (false, false) }
    view.setActive(true, animated: false)
    view.configure(mode: mode, thickness: 10, trackRoom: [.left: 200, .right: 200, .up: 200, .down: 200])
    view.layoutSubtreeIfNeeded()
    let updates = view.appearanceUpdateCount
    let builds = view.outlineBuildCount
    for distance in 0..<100 {
        view.configure(mode: mode, thickness: 10,
                       trackRoom: [.left: 200 + Double(distance), .right: 400 - Double(distance), .up: 200, .down: 200])
        view.layoutSubtreeIfNeeded()
    }
    #expect(view.appearanceUpdateCount == updates)
    #expect(view.outlineBuildCount == builds)
    view.configure(mode: mode, thickness: 10, trackRoom: [.left: 50, .right: 50, .up: 50, .down: 50])
    view.layoutSubtreeIfNeeded()
    #expect(view.appearanceUpdateCount == updates + 1)
    #expect(view.trackRects[0].width == 100)
}
