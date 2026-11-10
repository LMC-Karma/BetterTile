import AppKit
import BetterTileCore
import Metal
import QuartzCore
import Observation

/// Owned by a Settings page. Only eight style/theme bitmaps survive at one size.
@Observable @MainActor public final class LayoutWheelStyleSnapshots: NSObject {
    private struct Key: Hashable {
        var preset: LayoutWheelLiquidSettings.Preset
        var dark: Bool
    }
    @ObservationIgnored private var images: [Key: NSImage] = [:]
    @ObservationIgnored private var size: LayoutWheelSize?
    @ObservationIgnored var render: (LayoutWheelLiquidSettings.Preset, Bool, LayoutWheelSize) -> NSImage?
    @ObservationIgnored private weak var window: NSWindow?
    public private(set) var isActive = true
    public private(set) var revision = 0
    @ObservationIgnored private var generation = 0
    public override convenience init() { self.init(render: Self.renderImage) }
    init(render: @escaping (LayoutWheelLiquidSettings.Preset, Bool, LayoutWheelSize) -> NSImage?) {
        self.render = render
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed(_:)), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowOpened(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
    }
    public func observe(window: NSWindow?) { self.window = window; isActive = window != nil }
    @objc private func windowClosed(_ note: Notification) {
        guard note.object as? NSWindow === window else { return }
        isActive = false
        removeAll()
    }
    @objc private func windowOpened(_ note: Notification) {
        if note.object as? NSWindow === window { isActive = true }
    }
    isolated deinit { NotificationCenter.default.removeObserver(self) }

    /// A body pass reads cached pixels only; generation starts from the page's task.
    public func image(preset: LayoutWheelLiquidSettings.Preset, dark: Bool, size: LayoutWheelSize) -> NSImage? {
        _ = revision
        guard isActive, self.size == size else { return nil }
        return images[Key(preset: preset, dark: dark)]
    }

    public func load(dark: Bool, size: LayoutWheelSize) async {
        guard isActive else { return }
        if self.size != size { removeAll(); self.size = size }
        generation += 1
        let request = generation
        for preset in LayoutWheelLiquidSettings.Preset.allCases {
            await Task.yield()
            guard !Task.isCancelled, isActive, generation == request else { return }
            let key = Key(preset: preset, dark: dark)
            guard images[key] == nil else { continue }
            guard let image = autoreleasepool(invoking: { render(preset, dark, size) }) else { continue }
            images[key] = image
            revision += 1
        }
    }

    public func removeAll() { generation += 1; images.removeAll(); size = nil; revision += 1 }
    var count: Int { images.count }

    /// Uses the product shader, model, icon rendering and sprite layout, without opening a panel.
    private static func renderImage(preset: LayoutWheelLiquidSettings.Preset, dark: Bool, size: LayoutWheelSize) -> NSImage? {
        var configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        configuration.appearance.size = size
        configuration.appearance.liquid = .init(preset: preset, appearance: dark ? .dark : .light)
        // Style cards are 72 pt high; 256 px keeps them oversampled at 2×.
        return render(configuration: configuration, dark: dark, maximumPixelDimension: 256)
    }

    /// Shared offscreen encode path, also used to measure highlight visibility in tests.
    static func render(configuration: LayoutWheelConfiguration, dark: Bool,
                       state: LayoutWheelLiquidState = .init(selection: .init(ring: .outer, sector: .right)), opaque: Bool = false, clearLightRimStrength: Float = 0.08, tintIcons: Bool = true, drawIcons: Bool = true, maximumPixelDimension: Int? = nil) -> NSImage? {
        guard let pipeline = LayoutWheelLiquidPipeline.prepare(), let encoder = LayoutWheelLiquidEncoder(pipeline: pipeline) else { return nil }
        let content = LayoutWheelLiquidDefaults.content(configuration: configuration, currentMode: .manual)
        var style = LayoutWheelLiquidDefaults.snapshotStyle(configuration: configuration, dark: dark, opaque: opaque)
        style.clearLightRimStrength = clearLightRimStrength
        // A static picture uses the renderer's calm path, without spending frames on a discarded opening.
        var model = LayoutWheelLiquid(layout: content.layout,
            tuning: LayoutWheelLiquidDefaults.tuning(configuration: configuration), reduceMotion: true)
        model.open()
        model.update(content.liquidInput(state))
        for _ in 0..<120 { model.advance(1.0 / 60); if model.isAtRest { break } }
        var iconImages = LayoutWheelLiquidImages()
        var entries: [(LayoutWheelLiquidAtlas.Key, CGImage)] = []
        for (index, ring) in content.rings.enumerated() {
            for (slot, item) in ring.slots.enumerated() {
                if let image = iconImages.icon(item, symbol: (index == 0 ? 16 : 18) * content.layout.scale,
                                               color: style.ink, dark: dark, scale: 2) {
                    entries.append((.ring(index, slot), image))
                }
            }
        }
        for sector in LayoutWheelSector.allCases {
            for (option, item) in content.fanOptions(sector).enumerated() {
                if let image = iconImages.icon(item, symbol: 16 * content.layout.scale, color: style.ink, dark: dark, scale: 2) {
                    entries.append((.option(sector.rawValue, option), image))
                }
            }
        }
        entries.append((.chevron, iconImages.chevron(size: 8 * content.layout.scale, color: style.ink, scale: 2)))
        let label = iconImages.label(content.centreName(state), content: content, color: style.ink, scale: 2)
        iconImages.finishIconRendering()
        guard let atlas = LayoutWheelLiquidAtlas(device: pipeline.device, images: entries, scale: 2) else { return nil }
        var instances: [SIMD4<Float>] = []
        LayoutWheelLiquidPresenter.fillSprites(&instances, model: model, content: content, state: state, atlas: atlas)
        if !tintIcons { for index in stride(from: 2, to: instances.count, by: 3) { instances[index].z = 0 } }
        if !drawIcons { instances.removeAll() }
        let points = CGSize(width: content.diameter, height: content.diameter)
        let fullPixels = Int(ceil(content.diameter * 2))
        let pixels = min(fullPixels, max(1, maximumPixelDimension ?? fullPixels))
        let pointsPerPixel = pixels == fullPixels ? 0.5 : content.diameter / Double(pixels)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LayoutWheelLiquidPipeline.pixelFormat,
                                                                  width: pixels, height: pixels, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = pipeline.device.makeTexture(descriptor: descriptor) else { return nil }
        let drawable = OffscreenWheelDrawable(texture: texture)
        guard encoder.draw(model, style: style,
            frame: .init(center: .init(x: points.width / 2, y: points.height / 2), pointsPerPixel: pointsPerPixel),
            sprites: .init(atlas: atlas, instances: instances, viewSize: points), drawable: drawable),
              let fence = pipeline.queue.makeCommandBuffer() else { return nil }
        // Settings draws these on the main thread. A stalled GPU gives no thumbnail, never a hang.
        guard LayoutWheelLiquidPipeline.commitAndWait(fence) else { return nil }
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        texture.getBytes(&bytes, bytesPerRow: pixels * 4,
                         from: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: pixels, height: pixels, depth: 1)), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        // Compose in sRGB at the render's own pixel size. NSImage.lockFocus would use the main
        // display's scale and colour profile, so the same render would give other pixels on
        // another Mac.
        guard let composer = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        composer.interpolationQuality = .high
        composer.scaleBy(x: CGFloat(pixels) / points.width, y: CGFloat(pixels) / points.height)
        composer.draw(image, in: .init(origin: .zero, size: points))
        if let label {
            let width = CGFloat(label.width) / 2, height = CGFloat(label.height) / 2
            composer.draw(label, in: .init(x: (points.width - width) / 2, y: (points.height - height) / 2,
                                           width: width, height: height))
        }
        guard let composed = composer.makeImage() else { return nil }
        if maximumPixelDimension != nil {
            let bitmap = NSBitmapImageRep(cgImage: composed)
            bitmap.size = points
            let result = NSImage(size: points)
            result.addRepresentation(bitmap)
            return result
        }
        return NSImage(cgImage: composed, size: points)
    }
}

/// An owned texture target, with no surface, window, display link or retained drawable pool.
final class OffscreenWheelDrawable: NSObject, CAMetalDrawable {
    let texture: any MTLTexture
    let layer = CAMetalLayer()
    let drawableID: Int = 0
    let presentedTime: CFTimeInterval = 0
    init(texture: any MTLTexture) { self.texture = texture }
    func present() {}
    func present(at presentationTime: CFTimeInterval) {}
    func present(afterMinimumDuration duration: CFTimeInterval) {}
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) {}
}
