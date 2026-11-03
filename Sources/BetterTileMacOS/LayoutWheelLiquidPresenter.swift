import AppKit
import BetterTileCore
import QuartzCore
import SwiftUI
import os

/// One moment of the gesture, from Core selection only.
public struct LayoutWheelLiquidState: Equatable, Sendable {
    public var selection: LayoutWheelSelection?
    /// The open group, Grouped only, and its aimed option.
    public var openSector: LayoutWheelSector?
    public var aimedOption: Int?
    /// The pointer relative to the drawn wheel centre, in top-left points.
    public var pointer: BTPoint?

    public init(selection: LayoutWheelSelection? = nil, openSector: LayoutWheelSector? = nil,
                aimedOption: Int? = nil, pointer: BTPoint? = nil) {
        self.selection = selection; self.openSector = openSector; self.aimedOption = aimedOption
        self.pointer = pointer
    }

    /// From the native wheel's Grouped selection.
    public init(selection: LayoutWheelSelection?, fan: LayoutWheelFanState?, pointer: BTPoint?) {
        self.init(selection: selection, openSector: fan?.openSector, aimedOption: fan?.optionIndex, pointer: pointer)
    }

    /// From the prototype's locked sub-menu selection.
    @_spi(LiquidWheelPrototype)
    public init(submenu: LayoutWheelFanState, pointer: BTPoint?) {
        self.init(selection: submenu.selection, openSector: submenu.openSector,
                  aimedOption: submenu.optionIndex, pointer: pointer)
    }
}

/// Presents the liquid Layout Wheel: a click-through panel with the system
/// blur at the back and one Metal drawable that carries the body and every
/// icon. Only the centre name is a layer.
///
/// It owns no command, selection or input monitor. The gesture supplies
/// Core selection; `end` only acknowledges what the gesture decided. The
/// frame clock runs only while the model moves, and closing frees the
/// drawables, so a closed or resting wheel does no CPU or GPU work.
@MainActor public final class LayoutWheelLiquidPresenter {
    /// Feel values. Product code uses the defaults; the prototype harness
    /// changes them with its Tuning knobs.
    public var tuning = LayoutWheelLiquidTuning.standard
    /// 0.25 plays every motion at quarter speed (prototype harness only).
    @_spi(LiquidWheelPrototype) public var timeScale = 1.0

    // Product defaults are centralized in LayoutWheelLiquidDefaults.
    public enum Material: String, CaseIterable, Sendable {
        /// Smoked in Dark, frosted in Light.
        case automatic, frosted, smoked
        /// No system blur, only the tint.
        case clear
    }
    public enum Names: String, CaseIterable, Sendable {
        case centre, underIcons, hidden
    }
    public var material = Material.automatic
    /// 0...1: thins the tints and the blur so more of the backdrop shows.
    public var translucency = 0.0
    /// The highlight colour; nil uses the system accent.
    public var accent: NSColor?
    public var names = Names.centre
    /// Colours the highlight by the kind of action aimed at.
    public var actionTint = false
    public var brightenHighlight = false
    public var neutralUnderglow = false
    /// Nil follows the system.
    public var reduceMotion: Bool?
    /// Nil follows the system appearance, as today's wheel does.
    public var dark: Bool?
    /// Nil follows Reduce Transparency and Increase Contrast.
    public var opaque: Bool?
    /// Called once the closing motion has finished and the panel is hidden.
    public var onClosed: (() -> Void)?
    public var isOpen: Bool { model != nil }
    public var isVisible: Bool { panel.isVisible }

    // Measurement hooks for the prototype harness; not product interface.
    @_spi(LiquidWheelPrototype) public private(set) var renderedFrameCount = 0
    @_spi(LiquidWheelPrototype) public var isClockRunning: Bool { frameSource.isRunning }
    /// True while full-size drawables exist; a close shrinks them to 1 x 1.
    @_spi(LiquidWheelPrototype) public var holdsDrawables: Bool {
        guard let size = metalLayer?.drawableSize else { return false }
        return size.width > 1 || size.height > 1
    }
    /// Called after every frame with the time since the previous frame of
    /// the same run (nil for a run's first frame) and the main-thread time.
    @_spi(LiquidWheelPrototype) public var frameObserver: ((_ elapsed: Double?, _ cpuMilliseconds: Double) -> Void)?
    /// Called on a Metal thread with each frame's GPU time in milliseconds.
    @_spi(LiquidWheelPrototype) public var gpuObserver: (@Sendable (Double) -> Void)? {
        didSet { encoder?.gpuTimeHandler = gpuObserver }
    }

    /// Builds the shader pipeline. Returns false when Metal is unavailable.
    @discardableResult
    public static func prepare() -> Bool { LayoutWheelLiquidPipeline.prepare() != nil }

    let frameSource: any LayoutWheelLiquidFrameSource
    private let panel: NSPanel
    private var embedded = false
    private let root = FlippedView()
    var previewView: NSView { root }
    func makePreviewView() -> NSView {
        embedded = true
        panel.contentView = nil
        return root
    }
    private let blurHost = FlippedView()
    private let bodyBlur = NSVisualEffectView()
    private let metalHost = FlippedView()
    private let inkHost = FlippedView()
    private let ink = CALayer()
    private let label = CALayer()
    private var labelKey: String?
    private var metalLayer: CAMetalLayer?
    private var drawablesReleased: Bool { !holdsDrawables }
    private var encoder: LayoutWheelLiquidEncoder?
    private var atlas: LayoutWheelLiquidAtlas?
    private struct AtlasKey: Equatable {
        var configuration: LayoutWheelConfiguration
        var levels: LayoutWheelLevelCount
        var rings: [[LayoutWheelSlot]]
        var options: [[LayoutWheelSlot]]
        var dark: Bool
        /// Captions exist only when Names draws them under the icons.
        var captions: Bool
        var scale: CGFloat

        /// The same icons for the same commands and colours, at any pixel density.
        /// An atlas with captions also serves a wheel that draws none.
        func drawsSameIcons(as other: AtlasKey) -> Bool {
            var other = other
            other.scale = scale
            if captions { other.captions = true }
            return self == other
        }
    }
    private var atlasKey: AtlasKey?
    private var sprites: [SIMD4<Float>] = []
    private var model: LayoutWheelLiquid?
    private var content: LayoutWheelLiquidContent?
    private var state = LayoutWheelLiquidState()
    private var style = LayoutWheelLiquidStyle.make(dark: true, opaque: false)
    private var lastTimestamp: Double?
    private var images = LayoutWheelLiquidImages()
    static let signposter = OSSignposter(subsystem: "com.lmckarma.BetterTile", category: "LiquidWheel")

    public convenience init(capturable: Bool = false) {
        self.init(frameSource: LayoutWheelLiquidDisplayLink(), capturable: capturable)
    }

    init(frameSource: any LayoutWheelLiquidFrameSource, capturable: Bool = false) {
        self.frameSource = frameSource
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
        // The prototype harness records itself; the product wheel stays private.
        panel.sharingType = capturable ? .readOnly : .none
        panel.isReleasedWhenClosed = false

        root.wantsLayer = true
        panel.contentView = root
        for view in [blurHost, metalHost, inkHost] {
            view.wantsLayer = true
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        bodyBlur.blendingMode = .behindWindow
        bodyBlur.state = .active
        bodyBlur.wantsLayer = true
        blurHost.addSubview(bodyBlur)
        inkHost.layer?.addSublayer(ink)
        ink.addSublayer(label)
    }

    /// Invalidate the frame source before releasing its layer and panel.
    isolated deinit {
        frameSource.stop()
        panel.orderOut(nil)
        metalLayer?.removeFromSuperlayer()
    }

    // MARK: Lifecycle

    var systemDarkProvider: () -> Bool = { LayoutWheelLiquidDefaults.systemDark }
    private var systemDark: Bool { systemDarkProvider() }
    /// Packs the icon images. Returns nil when a bitmap or texture allocation fails.
    var makeAtlas: (any MTLDevice, [(LayoutWheelLiquidAtlas.Key, CGImage)], CGFloat) -> LayoutWheelLiquidAtlas? = {
        LayoutWheelLiquidAtlas(device: $0, images: $1, scale: $2)
    }

    /// Lets a test make one icon or caption image fail to draw.
    var imageFailure: (LayoutWheelLiquidAtlas.Key) -> Bool = { _ in false }
    /// Called when an open wheel can no longer be drawn correctly and has been
    /// closed. The owner ends the gesture or installs another presenter.
    var onOpenWheelLost: (@MainActor () -> Void)?

    /// Draws every icon and name `content` can show and packs the icons, so
    /// neither an open nor a fan ever waits for one. Call at launch and when
    /// the configuration or appearance changes; not while a gesture runs.
    public func prewarm(_ content: LayoutWheelLiquidContent) {
        let isDark = dark ?? systemDark
        let style = LayoutWheelLiquidStyle.make(dark: isDark, opaque: false)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let prewarmState = LayoutWheelLiquidState()
        guard let pipeline = LayoutWheelLiquidPipeline.prepare() else { return }
        prepareAtlas(content, style: style, scale: scale, device: pipeline.device)
        for ring in content.rings {
            for sector in LayoutWheelSector.allCases {
                let selection = LayoutWheelSelection(ring: ring.ring, sector: sector)
                _ = images.label(content.centreName(LayoutWheelLiquidState(selection: selection)), content: content,
                                 color: style.ink, scale: scale)
                guard ring.ring == content.rings.last?.ring else { continue }
                for option in content.fanOptions(sector) {
                    _ = images.label((option.label, nil, option.isAvailable), content: content,
                                     color: style.ink, scale: scale)
                }
            }
        }
        _ = images.label(content.centreName(prewarmState), content: content, color: style.ink, scale: scale)
    }

    /// Does the work an open needs ahead of time, without showing anything:
    /// call it when the trigger's hold begins. A later `open` with the same
    /// content then only positions the panel and requests its first ready frame.
    @discardableResult
    public func prepareToOpen(_ content: LayoutWheelLiquidContent) -> Bool {
        close()
        return prepare(content)
    }

    private func prepare(_ content: LayoutWheelLiquidContent) -> Bool {
        #if BETTERTILE_TEST_HOOKS
        preparationCountForTesting += 1
        #endif
        frameSource.stop()
        lastTimestamp = nil
        guard let pipeline = ensureEncoder() else { return false }
        let options = displayOptions()
        systemReduceMotion = options.reduceMotion
        let isDark = dark ?? systemDark
        let isOpaque = opaque ?? (options.reduceTransparency || options.increaseContrast)
        let tone: SIMD4<Float>? = switch material {
        case .automatic: nil
        case .frosted: LayoutWheelLiquidStyle.frostedTone
        case .smoked: LayoutWheelLiquidStyle.smokedTone
        case .clear: SIMD4<Float>.zero
        }
        style = LayoutWheelLiquidStyle.make(dark: isDark, opaque: isOpaque, accent: accent ?? .controlAccentColor,
                                            translucency: translucency, materialTone: tone, brightenHighlight: brightenHighlight, neutralUnderglow: neutralUnderglow)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let scale = (embedded ? root.window?.backingScaleFactor : nil) ?? screen?.backingScaleFactor ?? 2
        self.content = content
        state = .init()
        let size = CGSize(width: content.diameter, height: content.diameter)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if panel.frame.size != size { panel.setContentSize(size) }
        root.frame = CGRect(origin: .zero, size: size)
        installMetalLayer(size: size, scale: scale)
        bodyBlur.isHidden = isOpaque || material == .clear || translucency >= 1
        bodyBlur.material = switch material {
        case .frosted: .popover
        case .smoked: .hudWindow
        default: isDark ? .hudWindow : .popover
        }
        // A fixed alpha; it changes only with the setting, never per frame.
        let blurAlpha = LayoutWheelLiquidStyle.blurOpacity(translucency: translucency)
        if abs(bodyBlur.alphaValue - blurAlpha) > 0.001 { bodyBlur.alphaValue = blurAlpha }
        label.isHidden = names != .centre
        let atlasReady = prepareAtlas(content, style: style, scale: scale, device: pipeline.device)
        labelKey = nil
        if atlasReady { syncLabel(scale: scale) }
        CATransaction.commit()
        // Without a complete atlas every command would stay selectable but
        // unseen. An open wheel may keep icons that still stand for the same
        // commands; otherwise it ends. A new gesture uses the fallback.
        let wasOpen = model?.phase == .open
        guard atlasReady || (wasOpen && atlasServes(content, style: style, scale: scale)) else {
            Logger(subsystem: "com.lmckarma.BetterTile", category: "LayoutWheel")
                .error("Liquid Layout Wheel icon atlas could not be built.")
            atlas = nil
            atlasKey = nil
            finishClose()
            if wasOpen { onOpenWheelLost?() }
            return false
        }
        var warmModel = LayoutWheelLiquid(layout: content.layout, tuning: tuning)
        warmModel.open()
        var warmSprites: LayoutWheelLiquidEncoder.Sprites?
        if let atlas {
            Self.fillSprites(&sprites, model: warmModel, content: content, state: state, atlas: atlas, names: names)
            warmSprites = .init(atlas: atlas, instances: sprites, viewSize: size)
        }
        encoder?.warmUp(warmModel, style: style,
                        frame: .init(center: CGPoint(x: size.width / 2, y: size.height / 2), pointsPerPixel: 1 / scale),
                        sprites: warmSprites)
        prepared = content
        return true
    }

    func refreshAppearance() {
        guard let content else { return }
        let savedModel = model
        let savedState = state
        let wasOpen = model != nil
        guard prepare(content) else { return }
        if let savedModel, savedModel.reduceMotion != (reduceMotion ?? systemReduceMotion) {
            if case .closing = savedModel.phase { finishClose(); return }
            var calm = LayoutWheelLiquid(layout: content.layout, tuning: tuning,
                                         reduceMotion: reduceMotion ?? systemReduceMotion)
            calm.open()
            calm.update(content.liquidInput(savedState))
            model = calm
        } else {
            model = savedModel
        }
        state = savedState
        if wasOpen { requestFrame() }
        else { close() }
    }

    /// The content the panel is set up for, until a close releases the drawables.
    private var prepared: LayoutWheelLiquidContent?
    private var systemReduceMotion = false
    var displayOptions: @MainActor () -> LayoutWheelDisplayOptions = { .system }

    private func ensureEncoder() -> LayoutWheelLiquidPipeline? {
        guard let pipeline = LayoutWheelLiquidPipeline.prepare() else { return nil }
        if encoder == nil {
            encoder = LayoutWheelLiquidEncoder(pipeline: pipeline)
            encoder?.gpuTimeHandler = gpuObserver
        }
        return encoder == nil ? nil : pipeline
    }

    /// Shows the wheel centred on `center`, a global top-left point. Returns
    /// false, showing nothing, when Metal is unavailable.
    @discardableResult
    public func open(_ content: LayoutWheelLiquidContent, center: BTPoint,
                     state: LayoutWheelLiquidState = .init()) -> Bool {
        open(content, center: center, state: state, inPanel: true)
    }

    func open(_ content: LayoutWheelLiquidContent, center: BTPoint,
              state: LayoutWheelLiquidState, inPanel: Bool) -> Bool {
        embedded = !inPanel
        if embedded, panel.contentView === root { panel.contentView = nil }
        let began = CACurrentMediaTime()
        if let prepared, prepared != content, prepared.drawsSameWheel(as: content), !drawablesReleased,
           metalLayer != nil {
            // The hold prepared this wheel before the target was captured.
            guard adoptTarget(content) else { return false }
        } else if prepared != content || drawablesReleased || metalLayer == nil || !atlasHasRequiredCaptions {
            guard prepare(content) else { return false }
        }
        frameSource.stop()
        lastTimestamp = nil
        self.state = state
        var model = LayoutWheelLiquid(layout: content.layout, tuning: tuning,
                                      reduceMotion: reduceMotion ?? systemReduceMotion)
        model.open()
        model.update(content.liquidInput(state))
        self.model = model

        let size = CGSize(width: content.diameter, height: content.diameter)
        let mainFrame = NSScreen.screens.first?.frame ?? .zero
        let frame = CoordinateConverter.toAppKit(
            BTRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                   width: size.width, height: size.height), mainScreenFrame: mainFrame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if inPanel, panel.frame != frame { panel.setFrame(frame, display: false) }
        var destinationScale = embedded ? root.window?.backingScaleFactor : panel.screen?.backingScaleFactor
        #if BETTERTILE_TEST_HOOKS
        if let destinationScaleForTesting { destinationScale = destinationScaleForTesting }
        #endif
        if let scale = destinationScale, let layer = metalLayer, layer.contentsScale != scale {
            // The wheel opened on a display with another scale than expected.
            installMetalLayer(size: size, scale: scale)
            // The new density changes the key, so the atlas is rebuilt. A failed
            // rebuild keeps the same icons, and their key, at the previous density.
            if let pipeline = LayoutWheelLiquidPipeline.current {
                prepareAtlas(content, style: style, scale: scale, device: pipeline.device)
            }
            labelKey = nil
        }
        // Keep the previous gesture hidden until its replacement is ready.
        blurHost.layer?.opacity = 0
        ink.opacity = 0
        CATransaction.commit()
        if inPanel { panel.orderFrontRegardless() }
        startClockIfNeeded()
        let took = (CACurrentMediaTime() - began) * 1000
        Self.signposter.emitEvent("Open", "\(took, format: .fixed(precision: 2)) ms")
        Logger(subsystem: "com.lmckarma.BetterTile", category: "LayoutWheel").debug("""
            liquid wheel panel shown: took \(took, format: .fixed(precision: 1), privacy: .public) ms
            """)
        return true
    }

    /// Applies the captured mode and availability to a prepared wheel. Only a
    /// changed Mode icon rebuilds the atlas; availability changes only alpha.
    private func adoptTarget(_ content: LayoutWheelLiquidContent) -> Bool {
        guard let device = encoder?.pipeline.device,
              prepareAtlas(content, style: style, scale: metalLayer?.contentsScale ?? 2, device: device)
        else { return prepare(content) }
        self.content = content
        prepared = content
        labelKey = nil
        return true
    }

    public func update(_ next: LayoutWheelLiquidState) {
        guard var model, let content, next != state else { return }
        state = next
        model.update(content.liquidInput(next))
        self.model = model
        startClockIfNeeded()
    }

    func update(_ content: LayoutWheelLiquidContent, state: LayoutWheelLiquidState) {
        guard model?.phase == .open else { return }
        if self.content != content {
            // Atlas entries are keyed by position. Old icons may stay only when
            // they still stand for the same commands.
            let scale = metalLayer?.contentsScale ?? 2
            let rebuilt = LayoutWheelLiquidPipeline.current.map {
                prepareAtlas(content, style: style, scale: scale, device: $0.device)
            } ?? false
            guard rebuilt || atlasServes(content, style: style, scale: scale) else {
                loseOpenWheel()
                return
            }
            self.content = content
            labelKey = nil
            // A changed availability or mode still needs a frame at rest.
            lastTimestamp = nil
            self.state = state
            model?.update(content.liquidInput(state))
            requestFrame()
        } else {
            update(state)
        }
    }

    private func requestFrame() {
        guard model != nil, let metalLayer, !frameSource.isRunning else { return }
        frameSource.start(layer: metalLayer, framesPerSecond: drawingScreen?.maximumFramesPerSecond ?? 60) { [weak self] time, drawable in
            self?.tick(time, drawable: drawable)
        }
    }

    /// Plays the release or cancel motion, then hides the panel.
    public func end(_ ending: LayoutWheelLiquid.Ending) {
        guard var model, model.phase == .open else { return }
        switch ending {
        case .commit: model.release()
        case .cancel: model.cancel()
        }
        self.model = model
        startClockIfNeeded()
    }

    /// Hides immediately, without a closing motion.
    public func close() {
        guard model != nil || prepared != nil else { return }
        finishClose()
    }

    func releaseResources() {
        close()
        atlas = nil
        atlasKey = nil
        images = LayoutWheelLiquidImages()
        content = nil
        label.contents = nil
        encoder = nil
    }

    private func finishClose() {
        let interval = Self.signposter.beginInterval("Close", id: Self.signposter.makeSignpostID())
        defer { Self.signposter.endInterval("Close", interval) }
        frameSource.stop()
        lastTimestamp = nil
        model = nil
        prepared = nil
        panel.orderOut(nil)
        // Drop the drawables, the largest memory this wheel holds. A 1 x 1
        // drawable size empties the pool; the layer itself stays attached,
        // which makes the next open cheaper.
        metalLayer?.drawableSize = CGSize(width: 1, height: 1)
        // Hand the removal to the render server now, so it lets go of the
        // drawables without waiting for an unrelated transaction.
        CATransaction.flush()
        onClosed?()
    }

    // MARK: Frames

    private func startClockIfNeeded() {
        guard let model, let metalLayer, !model.isAtRest || model.phase != .open,
              !frameSource.isRunning else { return }
        lastTimestamp = nil
        frameSource.start(layer: metalLayer, framesPerSecond: drawingScreen?.maximumFramesPerSecond ?? 60) { [weak self] time, drawable in
            self?.tick(time, drawable: drawable)
        }
    }

    private var drawingScreen: NSScreen? { embedded ? root.window?.screen : panel.screen }

    private var refreshInterval: Double {
        let fps = drawingScreen?.maximumFramesPerSecond ?? 60
        return 1 / Double(max(30, min(fps, 120)))
    }

    private func tick(_ time: Double, drawable: any CAMetalDrawable) {
        let began = CACurrentMediaTime()
        guard var model, time.isFinite else { frameSource.stop(); return }
        // Instruments shows each frame as an interval, so a stall can be traced.
        let signpost = Self.signposter.beginInterval("Frame", id: Self.signposter.makeSignpostID())
        defer { Self.signposter.endInterval("Frame", signpost) }
        let sinceLast = lastTimestamp.map { time - $0 }
        let elapsed = sinceLast ?? refreshInterval
        lastTimestamp = time
        model.advance(min(max(elapsed, 0), 0.05) * max(0.01, timeScale))
        self.model = model
        if model.phase == .closed {
            finishClose()
        } else {
            let drawn = render(drawable: drawable)
            if drawn && model.isAtRest { frameSource.stop(); lastTimestamp = nil }
        }
        frameObserver?(sinceLast, (CACurrentMediaTime() - began) * 1000)
    }

    private func installMetalLayer(size: CGSize, scale: CGFloat) {
        guard let encoder else { return }
        let layer = metalLayer ?? CAMetalLayer()
        layer.device = encoder.pipeline.device
        layer.pixelFormat = LayoutWheelLiquidPipeline.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // The body, blur mask and centre label belong to one presented frame.
        layer.presentsWithTransaction = true
        // A display link owns the drawable count after it has used the layer.
        // Set it only when creating a layer, never on a reprepare or reopen.
        if metalLayer == nil { layer.maximumDrawableCount = 3 }
        layer.contentsScale = scale
        layer.frame = CGRect(origin: .zero, size: size)
        layer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        if metalLayer == nil { metalHost.layer?.addSublayer(layer) }
        metalLayer = layer
    }

    @discardableResult
    private func render(drawable: any CAMetalDrawable) -> Bool {
        guard let model, let content, let encoder, let metalLayer else { return false }
        // Pointer drift leans the whole drawing; hit testing never moves.
        let center = CGPoint(x: content.diameter / 2 + model.drift.x, y: content.diameter / 2 + model.drift.y)
        // While the wheel fades, the blur mask shrinks toward the centre
        // instead of the blur view turning translucent, which would need an
        // offscreen surface. 0 means no blur (the opaque fallback).
        let recede = bodyBlur.isHidden ? 0 : min(1, max(0, model.opacity * 1.25))
        var drawnSprites: LayoutWheelLiquidEncoder.Sprites?
        if let atlas {
            Self.fillSprites(&sprites, model: model, content: content, state: state, atlas: atlas, names: names)
            drawnSprites = .init(atlas: atlas, instances: sprites,
                                 viewSize: CGSize(width: content.diameter, height: content.diameter))
        }
        var style = self.style
        if actionTint, let tint = Self.highlightTint(content: content, state: state)?.usingColorSpace(.sRGB) {
            style.accent = SIMD3(Float(tint.redComponent), Float(tint.greenComponent), Float(tint.blueComponent))
            style.brightenHighlight = false
            if style.neutralUnderglow { style.glowAlpha *= 0.5; style.neutralUnderglow = false }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard encoder.draw(model, style: style, frame: .init(center: center, pointsPerPixel: 1 / metalLayer.contentsScale,
                                                       blurRecede: recede),
                           sprites: drawnSprites, drawable: drawable) else {
            CATransaction.commit()
            return false
        }
        renderedFrameCount += 1
        blurHost.layer?.opacity = recede > 0 ? 1 : 0
        syncLabel(scale: metalLayer.contentsScale)
        if recede > 0 { layoutBlur(model, center: center, recede: recede) }
        layoutLabel(model, center: center)
        let commit = Self.signposter.beginInterval("Commit", id: Self.signposter.makeSignpostID())
        CATransaction.commit()
        Self.signposter.endInterval("Commit", commit)
        return true
    }

    // MARK: Blur

    /// The system blur sits behind the body: one blur view masked by the
    /// drawn outline and droplets. Where the shape passes the mask (the 1 pt
    /// inset and the necks between droplets and the rim), the shader adds
    /// the blur material's tone.
    private let outlineMask = CAShapeLayer()
    private var lastMask: [CGPoint] = []
    private var maskScratch: [CGPoint] = []
    private static let maskPoints = 128
    /// The mask sits 1 pt inside the drawn edge and lags it by at most
    /// 0.4 pt, so it never shows past the body; the shader tints the rest.
    static let maskInset = 1.0

    /// One full-size blur view, masked by the outline and the droplets. The
    /// mask is rebuilt only when some point moves by more than 0.4 pt, so a
    /// resting wheel commits nothing. While the wheel fades, the mask shrinks
    /// toward the centre instead of the view turning translucent.
    private func layoutBlur(_ model: LayoutWheelLiquid, center: CGPoint, recede: Double) {
        guard let content else { return }
        let side = content.diameter
        if bodyBlur.frame != CGRect(x: 0, y: 0, width: side, height: side) || bodyBlur.layer?.mask !== outlineMask {
            bodyBlur.frame = CGRect(x: 0, y: 0, width: side, height: side)
            bodyBlur.layer?.transform = CATransform3DIdentity
            bodyBlur.layer?.cornerRadius = 0
            bodyBlur.layer?.masksToBounds = false
            outlineMask.frame = CGRect(x: 0, y: 0, width: side, height: side)
            bodyBlur.layer?.mask = outlineMask
            lastMask = []
        }
        // The view is not flipped: its mask runs bottom-up.
        let scale = model.scale * recede
        // Reused every frame: no allocation while the wheel moves.
        var points = maskScratch
        maskScratch = []
        points.removeAll(keepingCapacity: true)
        for index in 0..<Self.maskPoints {
            let angle = 2 * Double.pi * Double(index) / Double(Self.maskPoints)
            let r = max(0, model.outer.radius(at: angle) - Self.maskInset) * scale
            points.append(CGPoint(x: center.x + cos(angle) * r, y: side - (center.y + sin(angle) * r)))
        }
        for drop in model.droplets where drop.radius > 2 {
            let r = (drop.radius - Self.maskInset) * scale * min(1, max(0, drop.fade.value))
            points.append(CGPoint(x: center.x + drop.center.x * scale, y: side - (center.y + drop.center.y * scale)))
            points.append(CGPoint(x: r, y: 0))
        }
        if points.count == lastMask.count,
           !zip(points, lastMask).contains(where: { abs($0.x - $1.x) > 0.4 || abs($0.y - $1.y) > 0.4 }) {
            maskScratch = points
            return
        }
        let signpost = Self.signposter.beginInterval("Mask", id: Self.signposter.makeSignpostID())
        defer { Self.signposter.endInterval("Mask", signpost) }
        maskScratch = lastMask
        lastMask = points
        let path = CGMutablePath()
        path.addLines(between: Array(points.prefix(Self.maskPoints)))
        path.closeSubpath()
        var index = Self.maskPoints
        while index + 1 < points.count {
            let c = points[index], r = points[index + 1].x
            if r > 0.5 { path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
            index += 2
        }
        outlineMask.path = path
    }

    // MARK: Icons

    private func makeAtlasKey(_ content: LayoutWheelLiquidContent, style: LayoutWheelLiquidStyle, scale: CGFloat) -> AtlasKey {
        // Availability changes sprite alpha, never the bitmap pixels.
        func rasterSlot(_ slot: LayoutWheelSlot) -> LayoutWheelSlot {
            var slot = slot
            slot.isAvailable = true
            return slot
        }
        return AtlasKey(configuration: content.configuration, levels: content.levelCount,
            rings: content.rings.map { $0.slots.map(rasterSlot) },
            options: content.submenuLayout == nil ? [] : LayoutWheelSector.allCases.map {
                content.fanOptions($0).map(rasterSlot)
            }, dark: style.dark, captions: names == .underIcons, scale: scale)
    }

    /// Under-icon names need captions in the atlas, and Names can change after
    /// the hold prepared the wheel.
    private var atlasHasRequiredCaptions: Bool {
        names != .underIcons || atlasKey?.captions == true
    }

    /// Whether the current atlas draws the right icon for every command of
    /// `content`. Only the pixel density may differ.
    private func atlasServes(_ content: LayoutWheelLiquidContent, style: LayoutWheelLiquidStyle, scale: CGFloat) -> Bool {
        guard atlas != nil, let current = atlasKey else { return false }
        return current.drawsSameIcons(as: makeAtlasKey(content, style: style, scale: scale))
    }

    /// The open wheel cannot be drawn completely. Close it and tell the owner,
    /// so no command is chosen from icons that do not match it.
    private func loseOpenWheel() {
        Logger(subsystem: "com.lmckarma.BetterTile", category: "LayoutWheel")
            .error("Liquid Layout Wheel icon atlas could not be rebuilt for an open wheel.")
        atlas = nil
        atlasKey = nil
        finishClose()
        onOpenWheelLost?()
    }

    /// Returns false when an icon or caption could not be drawn or the atlas
    /// could not be allocated. The previous atlas, if any, then stays in place.
    @discardableResult
    private func prepareAtlas(_ content: LayoutWheelLiquidContent, style: LayoutWheelLiquidStyle, scale: CGFloat,
                              device: any MTLDevice) -> Bool {
        let key = makeAtlasKey(content, style: style, scale: scale)
        guard key != atlasKey || atlas == nil else { return true }
        var entries: [(LayoutWheelLiquidAtlas.Key, CGImage)] = []
        let layout = content.layout
        var complete = true
        func add(_ key: LayoutWheelLiquidAtlas.Key, _ draw: (inout LayoutWheelLiquidImages) -> CGImage?) {
            if !imageFailure(key), let image = draw(&images) {
                entries.append((key, image))
            } else {
                complete = false
            }
        }
        for (index, ring) in content.rings.enumerated() {
            let symbol = content.iconSymbolSize(ringIndex: index)
            for (slot, item) in ring.slots.enumerated() {
                add(.ring(index, slot)) { $0.icon(item, symbol: symbol, color: style.ink, dark: style.dark, scale: scale) }
                if key.captions {
                    add(.ringName(index, slot)) { $0.caption(item.label, layout: layout, color: style.ink, scale: scale) }
                }
            }
        }
        if content.submenuLayout != nil {
            for sector in LayoutWheelSector.allCases {
                for (option, slot) in content.fanOptions(sector).enumerated() {
                    add(.option(sector.rawValue, option)) {
                        $0.icon(slot, symbol: 18 * layout.scale, color: style.ink, dark: style.dark, scale: scale)
                    }
                    if key.captions {
                        add(.optionName(sector.rawValue, option)) {
                            $0.caption(slot.label, layout: layout, color: style.ink, scale: scale)
                        }
                    }
                }
            }
            entries.append((.chevron, images.chevron(size: 8 * layout.scale, color: style.ink, scale: scale)))
        }
        defer { images.finishIconRendering() }
        // Every icon, and every caption that Names draws, must exist. A missing
        // one would leave a blank slot whose command still works.
        guard complete, let packed = makeAtlas(device, entries, scale) else { return false }
        atlas = packed
        atlasKey = key
        return true
    }

    /// Three float4 values per icon: centre and half size, atlas corners,
    /// rotation and opacity. All positions are model points from the centre.
    static func fillSprites(_ out: inout [SIMD4<Float>], model: LayoutWheelLiquid, content: LayoutWheelLiquidContent,
                            state: LayoutWheelLiquidState, atlas: LayoutWheelLiquidAtlas, names: Names = .centre) {
        let underIcons = names == .underIcons
        out.removeAll(keepingCapacity: true)
        func add(_ key: LayoutWheelLiquidAtlas.Key, at point: BTPoint, scale: Double, rotation: Double = 0, opacity: Double, tint: Double = 0) {
            guard let entry = atlas.entries[key], opacity > 0.002, scale > 0.01,
                  out.count / 3 < LayoutWheelLiquidEncoder.maximumSprites else { return }
            out.append(SIMD4(Float(point.x), Float(point.y),
                             Float(entry.size.width / 2 * scale), Float(entry.size.height / 2 * scale)))
            out.append(entry.uv)
            out.append(SIMD4(Float(rotation), Float(min(1, opacity)), Float(tint), 0))
        }
        let layout = content.layout
        let openSector = state.openSector
        for (ringIndex, ring) in content.rings.enumerated() {
            let radius = layout.iconRadii[ringIndex]
            for slot in 0..<layout.slotCount {
                let angle = layout.slotAngle(slot)
                let offset = model.iconOffset(ring: ringIndex, slot: slot)
                let isParent = openSector?.rawValue == slot && ringIndex == layout.outermostRing
                let dim = !isParent ? 1 - 0.5 * model.submenuDimming : 1
                let tint = model.iconTint(ring: ringIndex, slot: slot)
                let grow = 1 + 0.08 * max(-0.5, model.magnet(ring: ringIndex, slot: slot))
                let alpha = (ring.slots[slot].isAvailable ? 1 : 0.35) * dim
                var icon = BTPoint(x: cos(angle) * radius + offset.x, y: sin(angle) * radius + offset.y)
                if underIcons {
                    // Lift the icon a little so it and its name share the slot.
                    icon.y -= 5 * layout.scale
                    // Hang the name's top edge just below the icon.
                    let half = (atlas.entries[.ringName(ringIndex, slot)]?.size.height ?? 0) / 2
                    add(.ringName(ringIndex, slot), at: BTPoint(x: icon.x, y: icon.y + 9 * layout.scale + half),
                        scale: 1, opacity: alpha)
                }
                add(.ring(ringIndex, slot), at: icon, scale: grow * (underIcons ? 0.85 : 1), opacity: alpha, tint: tint)
                if ringIndex == layout.outermostRing, ring.hasFan[slot] {
                    // The chevron sits in the room Grouped adds outside the icons.
                    let edge = model.outer.radius(at: angle) - LayoutWheelLiquidContent.chevronRoom / 2 * layout.scale
                    add(.chevron, at: BTPoint(x: cos(angle) * edge, y: sin(angle) * edge), scale: 1, rotation: angle,
                        opacity: 0.8 * dim, tint: tint)
                }
            }
        }
        for drop in model.droplets {
            guard let sector = LayoutWheelSector(rawValue: drop.parentSlot) else { continue }
            let options = content.fanOptions(sector)
            guard options.indices.contains(drop.option) else { continue }
            let size = max(0, drop.size.value) * (1 + 0.1 * drop.swell.value)
            let alpha = min(1, max(0, drop.fade.value)) * min(1, max(0, drop.size.value) * 1.4)
                * (options[drop.option].isAvailable ? 1 : 0.35)
            if underIcons {
                add(.option(drop.parentSlot, drop.option), at: BTPoint(x: drop.center.x, y: drop.center.y - 4 * size),
                    scale: size * 0.8, opacity: alpha, tint: drop.iconTint)
                add(.optionName(drop.parentSlot, drop.option),
                    at: BTPoint(x: drop.center.x, y: drop.center.y + 11 * size * layout.scale), scale: size * 0.85,
                    opacity: alpha)
            } else {
                add(.option(drop.parentSlot, drop.option), at: drop.center, scale: size, opacity: alpha, tint: drop.iconTint)
            }
        }
    }

    /// The colour the highlight takes for this moment of the gesture.
    static func highlightTint(content: LayoutWheelLiquidContent, state: LayoutWheelLiquidState) -> NSColor? {
        actionTint(content.tintCommand(state))
    }

    /// One colour per kind of action, for the Action tint option.
    static func actionTint(_ command: LayoutWheelCommand?) -> NSColor? {
        switch command {
        case .none: return nil
        case let .windowAction(action):
            switch action {
            case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return .systemBlue
            case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter: return .systemTeal
            case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds: return .systemIndigo
            case .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth,
                 .bottomRightSixth: return .systemPurple
            case .maximize, .almostMaximize, .center, .centerResize: return .systemGreen
            case .nextDisplay, .previousDisplay: return .systemOrange
            case .moveLeft, .moveRight, .moveUp, .moveDown: return .systemCyan
            case .restore: return .systemYellow
            default: return .systemMint
            }
        case .repairBento: return .systemRed
        case .setMode: return .systemPink
        case .chooseLayout, .savedLayouts, .savedLayout, .moreSavedLayouts, .moreLayoutChoices: return .systemBrown
        case .customZone: return nil
        }
    }

    // MARK: Centre name

    private func layoutLabel(_ model: LayoutWheelLiquid, center: CGPoint) {
        guard let content else { return }
        let bounds = CGRect(x: 0, y: 0, width: content.diameter, height: content.diameter)
        if ink.bounds != bounds {
            ink.bounds = bounds
            ink.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        let transform = CATransform3DMakeScale(model.scale, model.scale, 1)
        if !CATransform3DEqualToTransform(ink.transform, transform) { ink.transform = transform }
        let opacity = Float(model.opacity)
        if abs(ink.opacity - opacity) > 0.002 { ink.opacity = opacity }
        if label.position != center { label.position = center }
    }

    private func syncLabel(scale: CGFloat) {
        guard let content else { return }
        let name = content.centreName(state)
        let key = "\(name?.name ?? "")|\(name?.detail ?? "")|\(name?.available ?? true)|\(style.dark)|\(scale)"
        guard key != labelKey else { return }
        labelKey = key
        let image = images.label(name, content: content, color: style.ink, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.contents = image
        label.contentsScale = scale
        label.bounds = CGRect(x: 0, y: 0, width: CGFloat(image?.width ?? 0) / scale, height: CGFloat(image?.height ?? 0) / scale)
        CATransaction.commit()
    }

    #if BETTERTILE_TEST_HOOKS
    /// Full preparations: drawables, style, atlas and the warm-up frame.
    private(set) var preparationCountForTesting = 0
    /// Stands in for the display the wheel opens on, which an offscreen test panel lacks.
    var destinationScaleForTesting: CGFloat?
    var labelImageForTesting: CGImage? { label.contents as! CGImage? }
    var metalLayerForTesting: CAMetalLayer? { metalLayer }
    var panelForTesting: NSPanel { panel }
    /// The Metal layer's real drawable size, so tests check the release itself.
    var drawableSizeForTesting: CGSize? { metalLayer?.drawableSize }
    /// Test access to the model.
    var currentModel: LayoutWheelLiquid? { model }
    var styleForTesting: LayoutWheelLiquidStyle { style }
    var blurIsHiddenForTesting: Bool { bodyBlur.isHidden }
    var blurAlphaForTesting: CGFloat { bodyBlur.alphaValue }
    var blurMaterialForTesting: NSVisualEffectView.Material { bodyBlur.material }
    var atlasForTesting: LayoutWheelLiquidAtlas? { atlas }
    var contentForTesting: LayoutWheelLiquidContent? { content }
    var stateForTesting: LayoutWheelLiquidState { state }
    /// Every value the product writes into the renderer from the saved configuration, as text.
    /// The overlay and the Settings preview must produce the same value from the same configuration.
    var configurationValuesForTesting: String {
        let rgb = accent.flatMap { $0.usingColorSpace(.sRGB) }.map { [$0.redComponent, $0.greenComponent, $0.blueComponent] }
        return [
            "tuning=\(tuning)", "material=\(material)", "translucency=\(translucency)", "accent=\(String(describing: rgb))",
            "names=\(names)", "actionTint=\(actionTint)", "brighten=\(brightenHighlight)", "underglow=\(neutralUnderglow)",
            "reduceMotion=\(String(describing: reduceMotion))", "dark=\(String(describing: dark))",
            "opaque=\(String(describing: opaque))", "style=\(style)",
            "blurHidden=\(bodyBlur.isHidden)", "blurAlpha=\(bodyBlur.alphaValue)", "blurMaterial=\(bodyBlur.material.rawValue)",
        ].joined(separator: "\n")
    }
    /// Plays the current model to rest without a frame clock.
    func settleForTesting() {
        guard var current = model else { return }
        for _ in 0..<720 where !current.isAtRest { current.advance(1 / 120) }
        model = current
    }
    /// Draws the current frame, exactly as `render(drawable:)` does, into an offscreen texture
    /// of the layer's drawable size. The centre name is a layer, not part of this image.
    func offscreenImageForTesting() -> CGImage? {
        guard let metalLayer, let pipeline = LayoutWheelLiquidPipeline.current else { return nil }
        let width = Int(metalLayer.drawableSize.width), height = Int(metalLayer.drawableSize.height)
        guard width > 1, height > 1 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LayoutWheelLiquidPipeline.pixelFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = pipeline.device.makeTexture(descriptor: descriptor),
              render(drawable: OffscreenWheelDrawable(texture: texture)),
              let fence = pipeline.queue.makeCommandBuffer() else { return nil }
        guard LayoutWheelLiquidPipeline.commitAndWait(fence) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                    | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    func rebuildAtlasForTesting() {
        guard let content, let pipeline = LayoutWheelLiquidPipeline.current else { return }
        atlasKey = nil
        images = LayoutWheelLiquidImages()
        prepareAtlas(content, style: style, scale: metalLayer?.contentsScale ?? 2, device: pipeline.device)
    }
    #endif
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A bitmap-byte-bounded least-recently-used cache. A settings session can visit
/// arbitrary labels and sizes; none of those combinations lives forever.
struct LayoutWheelLiquidImageCache {
    private struct Entry {
        let image: CGImage
        var access: UInt64
        var bytes: Int { image.bytesPerRow * image.height }
    }
    let limit: Int
    let maximumCount = 128
    private var entries: [String: Entry] = [:]
    private var access: UInt64 = 0
    private(set) var bytes = 0
    var count: Int { entries.count }

    init(limit: Int) {
        self.limit = limit
    }

    subscript(key: String) -> CGImage? {
        mutating get {
            guard var entry = entries[key] else { return nil }
            access &+= 1
            entry.access = access
            entries[key] = entry
            return entry.image
        }
        set {
            if let old = entries.removeValue(forKey: key) { bytes -= old.bytes }
            guard let image = newValue else { return }
            let cost = image.bytesPerRow * image.height
            guard cost <= limit else { return }
            while bytes + cost > limit || entries.count >= maximumCount {
                guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
                bytes -= oldest.value.bytes
                entries.removeValue(forKey: oldest.key)
            }
            access &+= 1
            entries[key] = Entry(image: image, access: access)
            bytes += cost
        }
    }
}

/// Cached icon, chevron and label images, reused across opens.
/// Icons and text each retain at most 512 KiB of bitmap pixels, plus one small chevron.
@MainActor struct LayoutWheelLiquidImages {
    private struct IconImage: View {
        let slot: LayoutWheelSlot
        let symbol: Double
        let color: NSColor
        let dark: Bool
        var body: some View {
            let side = 35 / 18 * symbol
            LayoutWheelIcon(slot: slot, tint: Color(nsColor: color), fontSize: symbol)
                .frame(width: side, height: side)
                .environment(\.colorScheme, dark ? .dark : .light)
        }
    }
    private var iconRenderer: ImageRenderer<IconImage>?
    private var icons = LayoutWheelLiquidImageCache(limit: 524_288)
    private var labels = LayoutWheelLiquidImageCache(limit: 524_288)
    private var chevronImage: (key: String, image: CGImage)?

    var retainedImageBytes: Int { icons.bytes + labels.bytes }
    #if BETTERTILE_TEST_HOOKS
    var rendererForTesting: AnyObject? { iconRenderer }
    #endif

    mutating func icon(_ slot: LayoutWheelSlot, symbol: Double, color: NSColor, dark: Bool, scale: CGFloat) -> CGImage? {
        let key = "\(slot.label)|\(slot.symbolName)|\(String(describing: slot.glyph))|\(symbol)|\(dark)|\(scale)"
        if let image = icons[key] { return image }
        let content = IconImage(slot: slot, symbol: symbol, color: color, dark: dark)
        let renderer: ImageRenderer<IconImage>
        if let existing = iconRenderer {
            renderer = existing
            renderer.content = content
        } else {
            renderer = ImageRenderer(content: content)
            iconRenderer = renderer
        }
        renderer.scale = scale
        let image = renderer.cgImage.flatMap(Self.rasterize)
        icons[key] = image
        return image
    }

    mutating func finishIconRendering() { iconRenderer = nil }

    /// A SwiftUI-rendered image can retain its render backend and textures.
    /// Cache only owned bitmap pixels, which are also what the atlas needs.
    static func rasterize(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Small text for the Names option: up to two centred lines that fit a slot.
    mutating func caption(_ text: String, layout: LayoutWheelLiquidLayout, color: NSColor, scale: CGFloat) -> CGImage? {
        let key = "caption|\(text)|\(layout.scale)|\(color)|\(scale)"
        if let image = labels[key] { return image }
        let font = NSFont.systemFont(ofSize: max(7.5, 8.5 * layout.scale), weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color,
                                                                   .paragraphStyle: paragraph])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let limit = 54 * layout.scale
        let fitted = string.boundingRect(with: CGSize(width: limit, height: lineHeight * 2),
                                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let width = min(ceil(fitted.width) + 2, limit + 2)
        let height = min(ceil(fitted.height), lineHeight * 2) + 2
        let image = Self.draw(size: CGSize(width: width, height: height), scale: scale) { _ in
            string.draw(with: CGRect(x: 1, y: 1, width: width - 2, height: height - 1),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        labels[key] = image
        return image
    }

    mutating func chevron(size: Double, color: NSColor, scale: CGFloat) -> CGImage {
        let key = "\(size)|\(color)|\(scale)"
        if let chevronImage, chevronImage.key == key { return chevronImage.image }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        let symbol = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        var rect = CGRect(origin: .zero, size: symbol?.size ?? CGSize(width: size, height: size))
        let image = symbol?.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
            ?? Self.blank(scale: scale)
        chevronImage = (key, image)
        return image
    }

    mutating func label(_ name: (name: String, detail: String?, available: Bool)?, content: LayoutWheelLiquidContent,
                        color: NSColor, scale: CGFloat) -> CGImage? {
        // The fitted lines depend on the space the innermost icons leave.
        let space = LayoutWheelLabelSpace(liquid: content)
        let key = "\(name?.name ?? "")|\(name?.detail ?? "")|\(name?.available ?? true)|\(color)|\(scale)|\(content.layout.scale)"
            + "|\(space.style)|\(space.levelCount)|\(space.iconBoxes)"
        if let image = labels[key] { return image }
        let s = content.layout.scale
        let ink = color.withAlphaComponent(color.alphaComponent * ((name?.available ?? true) ? 1 : 0.6))
        var lines: [(String, NSFont)] = []
        var mark: NSImage?
        if let name {
            let fitted = LayoutWheelCentreLabel(name: name.name, mainAction: name.detail, space: space)
            lines = fitted.lines.map { ($0.text, $0.font) }
        } else {
            mark = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: max(9, 8.8 * s), weight: .semibold)
                    .applying(.init(paletteColors: [ink])))
            lines = [("Cancel", .systemFont(ofSize: max(9, 9.5 * s), weight: .medium))]
        }
        let attributed = lines.map { NSAttributedString(string: $0.0, attributes: [.font: $0.1, .foregroundColor: ink]) }
        let sizes = attributed.map { $0.size() }
        let gap = mark == nil ? 0 : 3 * s
        let markSize = mark?.size ?? .zero
        let width = ceil(max(sizes.map(\.width).max() ?? 0, markSize.width)) + 4
        let height = ceil(sizes.reduce(0) { $0 + $1.height } + markSize.height + gap) + 2
        let image = Self.draw(size: CGSize(width: width, height: height), scale: scale) { context in
            var y = 1.0
            if let mark {
                mark.draw(in: CGRect(x: (width - markSize.width) / 2, y: y, width: markSize.width, height: markSize.height))
                y += markSize.height + gap
            }
            for (line, size) in zip(attributed, sizes) {
                line.draw(at: CGPoint(x: (width - size.width) / 2, y: y))
                y += size.height
            }
        }
        labels[key] = image
        return image
    }

    private static func blank(scale: CGFloat) -> CGImage {
        draw(size: CGSize(width: 1, height: 1), scale: scale) { _ in }!
    }

    /// Draws in a flipped, top-left context at the backing scale.
    private static func draw(size: CGSize, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let pixels = CGSize(width: max(1, ceil(size.width * scale)), height: max(1, ceil(size.height * scale)))
        guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.translateBy(x: 0, y: pixels.height)
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
