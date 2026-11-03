import AppKit
import BetterTileCore
import Metal
import QuartzCore
import os

/// Colours and strengths for one appearance. Values are premultiplied sRGB.
struct LayoutWheelLiquidStyle: Equatable {
    var bodyTint: SIMD4<Float>
    var wellTint: SIMD4<Float>
    /// The blur material's own tint, drawn where the shape reaches past the
    /// blur mask (its 1 pt inset and the necks) so those edges keep the tone.
    var materialStandIn: SIMD4<Float>
    var accent: SIMD3<Float>
    var iconAccent: SIMD3<Float>
    var dark: Bool
    var rimStrength: Float
    var sheen: Float
    var separatorAlpha: Float
    var seamAlpha: Float
    var shadowAlpha: Float
    var glowAlpha: Float
    var brightenHighlight: Bool
    var neutralUnderglow: Bool
    var clearLightRimStrength: Float = 0.08
    /// Ink for icons and text, as today's wheel uses it.
    var ink: NSColor { dark ? NSColor.white.withAlphaComponent(0.94) : NSColor.black.withAlphaComponent(0.86) }

    /// `opaque` is the fallback for Reduce Transparency, Increase Contrast
    /// and the global glass switch: solid shapes and no blur.
    /// Measured on this Mac over flat white and dark areas: the dark HUD
    /// material is about half grey 0.64, the light popover material about
    /// three quarters grey 0.73, over the blurred backdrop.
    static let smokedTone = SIMD4<Float>(0.32, 0.32, 0.32, 0.50)
    static let frostedTone = SIMD4<Float>(0.5475, 0.5475, 0.5475, 0.75)

    /// Preserve the approved blur through 0.85, then ease its remaining opacity to zero.
    static func blurOpacity(translucency: Double) -> Double {
        let value = min(1, max(0, translucency))
        return value <= 0.85 ? 1 - 0.7 * value : 0.405 * (1 - value) / 0.15
    }

    /// `translucency` (0...1) thins the tints so more of the backdrop shows.
    /// `materialTone` is the blur material's own tint; nil follows `dark`.
    static func make(dark: Bool, opaque: Bool, accent: NSColor = .controlAccentColor, translucency: Double = 0,
                     materialTone: SIMD4<Float>? = nil, brightenHighlight: Bool = false, neutralUnderglow: Bool = false) -> Self {
        let srgb = accent.usingColorSpace(.sRGB) ?? .systemBlue
        let rgb = SIMD3<Float>(Float(srgb.redComponent), Float(srgb.greenComponent), Float(srgb.blueComponent))
        // Mist uses the same cloud as blue and gold, with enough coverage to read as a white underglow.
        // In Light, a neutral shade keeps that cloud visible over white windows.
        let cloudAccent = neutralUnderglow && !dark ? SIMD3<Float>(repeating: 0.78) : rgb
        let thin = Float(opaque ? 0 : min(1, max(0, translucency)))
        func tint(_ white: Float, _ alpha: Float) -> SIMD4<Float> { SIMD4(white * alpha, white * alpha, white * alpha, alpha) }
        let body = dark ? tint(0.03, opaque ? 1 : 0.34 * (1 - 0.75 * thin)) : tint(0.97, opaque ? 1 : 0.24 * (1 - 0.75 * thin))
        let well = dark ? tint(0.02, opaque ? 1 : 0.52 * (1 - 0.45 * thin)) : tint(0.99, opaque ? 1 : 0.50 * (1 - 0.45 * thin))
        let tone = materialTone ?? (dark ? smokedTone : frostedTone)
        let material = opaque ? SIMD4<Float>.zero : tone * Float(blurOpacity(translucency: Double(thin)))
        return Self(bodyTint: body, wellTint: well, materialStandIn: material,
                    accent: cloudAccent, iconAccent: !dark && (brightenHighlight || neutralUnderglow) ? .zero
                        : (brightenHighlight ? .init(repeating: 1) : cloudAccent),
                    dark: dark, rimStrength: dark ? 0.75 : 0.9, sheen: dark ? 0.06 : 0.10,
                    separatorAlpha: (dark ? 0.12 : 0.10) * (opaque ? 1.6 : 1), seamAlpha: dark ? 0.28 : 0.16,
                    shadowAlpha: dark ? 0.26 : 0.18, glowAlpha: (dark ? 0.40 : 0.32) * (neutralUnderglow ? 2 : 1), brightenHighlight: brightenHighlight, neutralUnderglow: neutralUnderglow)
    }
}

/// The compiled shader and its fixed GPU objects, built once per process.
///
/// Building compiles nothing: the shader is precompiled into the package's
/// `default.metallib`. Call `prepare()` at launch or on the first modifier
/// press so that no open ever waits for it.
@MainActor final class LayoutWheelLiquidPipeline {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let state: any MTLRenderPipelineState
    let spriteState: any MTLRenderPipelineState
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// Why `prepare()` returned nil. The first failure is final for the process.
    enum Failure: Error, Equatable, CustomStringConvertible {
        case noDevice
        case noCommandQueue
        case shaderBundleMissing
        case library(String)
        case pipeline(String)

        var description: String {
            switch self {
            case .noDevice: "no Metal device"
            case .noCommandQueue: "the Metal device made no command queue"
            case .shaderBundleMissing: "BetterTile_BetterTileMacOS.bundle with default.metallib is missing"
            case let .library(error): "the shader library did not load: \(error)"
            case let .pipeline(error): "a render pipeline state failed: \(error)"
            }
        }
    }

    private(set) static var buildCount = 0
    private static var shared: LayoutWheelLiquidPipeline?
    /// Set once when `prepare()` fails; nil while no attempt has failed.
    private(set) static var failure: Failure?

    static var current: LayoutWheelLiquidPipeline? { shared }

    /// Returns the pipeline, building it on the first call. Nil when this Mac
    /// has no Metal device or the library is missing; the caller then keeps
    /// the native wheel. `failure` then names the step that failed.
    @discardableResult
    static func prepare() -> LayoutWheelLiquidPipeline? {
        if let shared { return shared }
        guard failure == nil else { return nil }
        buildCount += 1
        do {
            shared = try build()
            return shared
        } catch {
            failure = error
            Logger(subsystem: "com.lmckarma.BetterTile", category: "LayoutWheel")
                .error("liquid wheel pipeline unavailable: \(error.description, privacy: .public)")
            return nil
        }
    }

    private static func build() throws(Failure) -> LayoutWheelLiquidPipeline {
        guard let device = MTLCreateSystemDefaultDevice() else { throw .noDevice }
        guard let queue = device.makeCommandQueue() else { throw .noCommandQueue }
        guard let bundle = shaderBundle else { throw .shaderBundleMissing }
        let library: any MTLLibrary
        do { library = try device.makeDefaultLibrary(bundle: bundle) } catch {
            throw .library(error.localizedDescription)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Layout Wheel liquid body"
        descriptor.vertexFunction = library.makeFunction(name: "liquidWheelVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "liquidWheelFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        let sprites = MTLRenderPipelineDescriptor()
        sprites.label = "Layout Wheel icons"
        sprites.vertexFunction = library.makeFunction(name: "liquidWheelSpriteVertex")
        sprites.fragmentFunction = library.makeFunction(name: "liquidWheelSpriteFragment")
        let attachment = sprites.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let state: any MTLRenderPipelineState
        let spriteState: any MTLRenderPipelineState
        do {
            state = try device.makeRenderPipelineState(descriptor: descriptor)
            spriteState = try device.makeRenderPipelineState(descriptor: sprites)
        } catch {
            throw .pipeline(error.localizedDescription)
        }
        queue.label = "Layout Wheel"
        return LayoutWheelLiquidPipeline(device: device, queue: queue, state: state, spriteState: spriteState)
    }

    /// The longest a synchronous offscreen render waits for the GPU or for a free buffer slot. A real or virtual
    /// GPU finishes these renders in milliseconds; a stalled one must not hold the main thread.
    nonisolated static let gpuWaitLimit = DispatchTimeInterval.seconds(5)

    /// Commits `commands` and waits until the GPU completes it, for at most `gpuWaitLimit`.
    /// Returns false when it did not complete in time or failed. Nothing here waits without a bound.
    nonisolated static func commitAndWait(_ commands: any MTLCommandBuffer) -> Bool {
        let done = DispatchSemaphore(value: 0)
        commands.addCompletedHandler { _ in done.signal() }
        commands.commit()
        return done.wait(timeout: .now() + gpuWaitLimit) == .success && commands.status == .completed
    }

    /// The package resource bundle with `default.metallib`, found where
    /// SwiftPM's own accessor looks. Unlike `Bundle.module`, a missing bundle
    /// returns nil instead of stopping the app, so the native wheel remains.
    private static var shaderBundle: Bundle? {
        let name = "BetterTile_BetterTileMacOS.bundle"
        var places = [Bundle.main.resourceURL, Bundle(for: LayoutWheelLiquidPipeline.self).resourceURL,
                      Bundle.main.bundleURL]
        #if BETTERTILE_TEST_HOOKS
        // SwiftPM's native build system does not compile Metal. Tools/test.sh
        // compiles the shader and names its folder here.
        if let folder = ProcessInfo.processInfo.environment["BETTERTILE_TEST_SHADER_DIRECTORY"] {
            places.append(URL(fileURLWithPath: folder, isDirectory: true))
        }
        #endif
        return places.lazy.compactMap { $0.flatMap { Bundle(url: $0.appendingPathComponent(name)) } }.first
    }

    private init(device: any MTLDevice, queue: any MTLCommandQueue, state: any MTLRenderPipelineState,
                 spriteState: any MTLRenderPipelineState) {
        self.device = device; self.queue = queue; self.state = state; self.spriteState = spriteState
    }
}

/// Encodes one frame of the liquid body from the model.
///
/// Uniforms and both outlines live in a small ring of three shared buffers,
/// about 30 KB in all. Nothing here allocates per frame.
@MainActor final class LayoutWheelLiquidEncoder {
    static let uniformCount = 11 + 2 * LayoutWheelLiquid.maximumDroplets
    private static let uniformBytes = uniformCount * MemoryLayout<SIMD4<Float>>.stride
    private static let rimBytes = LayoutWheelLiquidRim.sampleCount * MemoryLayout<SIMD4<Float>>.stride
    static let maximumSprites = 96
    private static let spriteBytes = maximumSprites * 3 * MemoryLayout<SIMD4<Float>>.stride
    private static let slotBytes = (uniformBytes + 2 * rimBytes + spriteBytes + 255) / 256 * 256
    static let framesInFlight = 3

    let pipeline: LayoutWheelLiquidPipeline
    private let buffer: any MTLBuffer
    private var slot = 0
    private var warmedUp = false
    private let inFlight = DispatchSemaphore(value: framesInFlight)
    private var uniforms = [SIMD4<Float>](repeating: .zero, count: uniformCount)
    private var outerSamples: [SIMD4<Float>] = []
    private var stepSamples: [SIMD4<Float>] = []
    /// Called on a Metal thread with each frame's GPU time, in milliseconds.
    var gpuTimeHandler: (@Sendable (Double) -> Void)?

    init?(pipeline: LayoutWheelLiquidPipeline) {
        guard let buffer = pipeline.device.makeBuffer(length: Self.slotBytes * Self.framesInFlight,
                                                      options: .storageModeShared) else { return nil }
        buffer.label = "Layout Wheel frame data"
        self.pipeline = pipeline
        self.buffer = buffer
    }

    struct Frame {
        /// Drawing centre in the layer, in points.
        var center: CGPoint
        var pointsPerPixel: Double
        /// How far the outline blur mask has shrunk, 0...1; 0 for no blur.
        var blurRecede: Double = 0
    }

    /// Uses the frame source's ready drawable. Returns false if every data
    /// buffer is in flight; the next callback retries without blocking input.
    /// The caller owns the transaction that also updates the mask and label.
    @discardableResult
    func draw(_ model: LayoutWheelLiquid, style: LayoutWheelLiquidStyle, frame: Frame,
              sprites: Sprites? = nil, drawable: any CAMetalDrawable) -> Bool {
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        guard let commands = pipeline.queue.makeCommandBuffer(),
              encode(model, style: style, frame: frame, sprites: sprites, into: drawable.texture, commands: commands) else {
            inFlight.signal()
            return false
        }
        let semaphore = inFlight
        let report = gpuTimeHandler
        commands.addCompletedHandler { buffer in
            semaphore.signal()
            let gpu = buffer.gpuEndTime - buffer.gpuStartTime
            if gpu > 0 { report?(gpu * 1000) }
        }
        commands.commit()
        // presentsWithTransaction requires present() on the transaction's
        // thread, after scheduling the GPU work (not commandBuffer.present).
        commands.waitUntilScheduled()
        drawable.present()
        return true
    }

    /// Prime the first command submission during preparation. It uses an
    /// owned one-pixel target, without acquiring or presenting a drawable.
    func warmUp(_ model: LayoutWheelLiquid, style: LayoutWheelLiquidStyle, frame: Frame, sprites: Sprites?) {
        guard !warmedUp, inFlight.wait(timeout: .now()) == .success else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LayoutWheelLiquidPipeline.pixelFormat,
                                                                  width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let texture = pipeline.device.makeTexture(descriptor: descriptor),
              let commands = pipeline.queue.makeCommandBuffer(),
              encode(model, style: style, frame: frame, sprites: sprites, into: texture, commands: commands) else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.commit()
        warmedUp = true
    }

    #if BETTERTILE_TEST_HOOKS
    /// The shared-buffer region the next encoded frame uses.
    var nextSlotForTesting: Int { slot }
    /// Makes the next encoding fail as if no render encoder were available.
    var failsNextEncodingForTesting = false

    /// Draws one frame into an offscreen image of `size` points, for tests.
    /// Blocks until the GPU finishes.
    func image(_ model: LayoutWheelLiquid, style: LayoutWheelLiquidStyle, size: CGSize, scale: CGFloat,
               sprites: Sprites? = nil) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LayoutWheelLiquidPipeline.pixelFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard inFlight.wait(timeout: .now() + LayoutWheelLiquidPipeline.gpuWaitLimit) == .success else { return nil }
        guard let texture = pipeline.device.makeTexture(descriptor: descriptor),
              let commands = pipeline.queue.makeCommandBuffer(),
              encode(model, style: style, frame: .init(center: CGPoint(x: size.width / 2, y: size.height / 2),
                                                        pointsPerPixel: 1 / scale),
                     sprites: sprites, into: texture, commands: commands) else {
            inFlight.signal()
            return nil
        }
        // The slot stays taken until the GPU is done with it, even when this wait gives up.
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        guard LayoutWheelLiquidPipeline.commitAndWait(commands) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                    | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    #endif

    /// Icon quads for one frame, three float4 values each, from `atlas`.
    struct Sprites {
        var atlas: LayoutWheelLiquidAtlas
        var instances: [SIMD4<Float>]
        /// View size in points, for the quads' clip-space transform.
        var viewSize: CGSize
    }

    private func encode(_ model: LayoutWheelLiquid, style: LayoutWheelLiquidStyle, frame: Frame,
                        sprites: Sprites?, into texture: any MTLTexture, commands: any MTLCommandBuffer) -> Bool {
        fillUniforms(model, style: style, frame: frame)
        // The slot advances only once the frame is encoded. A failed frame
        // returns its semaphore permit, so it must not consume a region.
        let base = slot * Self.slotBytes
        let contents = buffer.contents()
        uniforms.withUnsafeBytes { contents.advanced(by: base).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        model.outer.sample(into: &outerSamples)
        outerSamples.withUnsafeBytes {
            contents.advanced(by: base + Self.uniformBytes).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        if let step = model.step {
            step.sample(into: &stepSamples)
            stepSamples.withUnsafeBytes {
                contents.advanced(by: base + Self.uniformBytes + Self.rimBytes)
                    .copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        #if BETTERTILE_TEST_HOOKS
        if failsNextEncodingForTesting { failsNextEncodingForTesting = false; return false }
        #endif
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline.state)
        encoder.setFragmentBuffer(buffer, offset: base, index: 0)
        encoder.setFragmentBuffer(buffer, offset: base + Self.uniformBytes, index: 1)
        encoder.setFragmentBuffer(buffer, offset: base + Self.uniformBytes + Self.rimBytes, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if let sprites, !sprites.instances.isEmpty {
            let count = min(sprites.instances.count / 3, Self.maximumSprites)
            let offset = base + Self.uniformBytes + 2 * Self.rimBytes
            sprites.instances.withUnsafeBytes {
                contents.advanced(by: offset).copyMemory(from: $0.baseAddress!,
                                                         byteCount: min($0.count, Self.spriteBytes))
            }
            var spriteFrame = [SIMD4<Float>(Float(sprites.viewSize.width), Float(sprites.viewSize.height),
                                            Float(model.scale), Float(model.opacity)),
                               SIMD4<Float>(Float(frame.center.x), Float(frame.center.y), 0, 0)]
            encoder.setRenderPipelineState(pipeline.spriteState)
            encoder.setVertexBuffer(buffer, offset: offset, index: 0)
            encoder.setVertexBytes(&spriteFrame, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 1)
            var iconTint = SIMD4<Float>(style.iconAccent, 1)
            encoder.setFragmentBytes(&iconTint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(sprites.atlas.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        }
        encoder.endEncoding()
        slot = (slot + 1) % Self.framesInFlight
        return true
    }

    private func fillUniforms(_ model: LayoutWheelLiquid, style: LayoutWheelLiquidStyle, frame: Frame) {
        let layout = model.layout
        let glow = model.focusGlow
        let ringBand = layout.stepRadius.map { _ in 0.65 * (layout.outerRadius - layout.wellRadius) / 2 }
            ?? 0.65 * (layout.outerRadius - layout.wellRadius)
        let light = SIMD2<Float>(-0.55, -0.835)
        uniforms[0] = SIMD4(Float(frame.pointsPerPixel), Float(model.scale), Float(model.opacity), Float(layout.wellRadius))
        uniforms[1] = SIMD4(Float(frame.center.x), Float(frame.center.y), Float(layout.outerRadius),
                            Float(layout.stepRadius ?? 0))
        uniforms[2] = SIMD4(Float(glow.angle), Float(glow.radius), Float(glow.intensity), Float(glow.spread))
        let drops = model.droplets.prefix(LayoutWheelLiquid.maximumDroplets)
        uniforms[3] = SIMD4(Float(ringBand), style.glowAlpha, Float(drops.count), Float(7 * layout.scale))
        uniforms[4] = style.bodyTint
        uniforms[5] = style.wellTint
        uniforms[6] = SIMD4(style.accent, style.dark ? 1 : 0)
        uniforms[7] = SIMD4(light.x, light.y, style.rimStrength, style.sheen)
        uniforms[8] = SIMD4(style.separatorAlpha * (model.droplets.isEmpty ? 1 : 0.5), Float(4 * layout.scale),
                            style.seamAlpha, style.shadowAlpha)
        uniforms[9] = SIMD4(Float(frame.blurRecede), style.brightenHighlight ? 1 : 0, style.clearLightRimStrength, 0)
        uniforms[10] = frame.blurRecede > 0 ? style.materialStandIn : .zero
        for index in 0..<LayoutWheelLiquid.maximumDroplets {
            guard index < drops.count else {
                uniforms[11 + index] = .zero
                uniforms[11 + LayoutWheelLiquid.maximumDroplets + index] = .zero
                continue
            }
            let drop = drops[drops.startIndex + index]
            uniforms[11 + index] = SIMD4(Float(drop.center.x), Float(drop.center.y), Float(drop.radius),
                                        Float(min(1, max(0, drop.fade.value))))
            uniforms[11 + LayoutWheelLiquid.maximumDroplets + index] = SIMD4(
                Float(drop.ovalCosine.value), Float(drop.ovalSine.value), Float(max(0, drop.swell.value)), Float(model.reduceMotion ? 0 : drop.connection))
        }
    }
}

/// Every icon one wheel can show, packed once into a small texture.
@MainActor final class LayoutWheelLiquidAtlas {
    private(set) static var buildCount = 0
    private(set) static var uploadCount = 0
    enum Key: Hashable {
        case ring(Int, Int)
        case option(Int, Int)
        case chevron
        /// Small names drawn under the icons, for the Names option.
        case ringName(Int, Int)
        case optionName(Int, Int)
    }

    struct Entry {
        /// Atlas corners: top-left u, v and bottom-right u, v.
        var uv: SIMD4<Float>
        /// Size in points.
        var size: CGSize
    }

    let texture: any MTLTexture
    let entries: [Key: Entry]

    /// Shelf packing with a two-pixel gutter so linear filtering never bleeds.
    init?(device: any MTLDevice, images: [(Key, CGImage)], scale: CGFloat) {
        Self.buildCount += 1
        let gutter = 2
        let width = 1024
        var x = gutter, y = gutter, shelf = 0
        var places: [(Key, CGImage, Int, Int)] = []
        for (key, image) in images {
            if x + image.width + gutter > width { x = gutter; y += shelf + gutter; shelf = 0 }
            places.append((key, image, x, y))
            x += image.width + gutter
            shelf = max(shelf, image.height)
        }
        let height = max(1, y + shelf + gutter)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data else { return nil }
        var entries: [Key: Entry] = [:]
        for (key, image, px, py) in places {
            // Bitmap rows run top-down in memory, while Core Graphics draws bottom-up.
            context.draw(image, in: CGRect(x: px, y: height - py - image.height, width: image.width, height: image.height))
            entries[key] = Entry(uv: SIMD4(Float(px) / Float(width), Float(py) / Float(height),
                                           Float(px + image.width) / Float(width), Float(py + image.height) / Float(height)),
                                 size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LayoutWheelLiquidPipeline.pixelFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "Layout Wheel icons"
        Self.uploadCount += 1
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        self.texture = texture
        self.entries = entries
    }
}
