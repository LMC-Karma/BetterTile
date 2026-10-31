import Foundation

/// One closed liquid outline around the wheel centre.
///
/// The outline is the rest radius plus a radial displacement, stored as a
/// short Fourier series. Each harmonic is its own closed-form spring, which
/// is the textbook model of a vibrating liquid ring: broad harmonics ring
/// slowly and visibly, fine harmonics move quickly and die out. Callers set
/// a target displacement profile and add impulses; the springs supply the
/// stretch, overshoot and settling.
///
/// Angles are standard angles in BetterTile's top-left coordinates: zero
/// points right and angles increase clockwise on screen, so the top of the
/// wheel is at -pi/2.
public struct LayoutWheelLiquidRim: Equatable, Sendable {
    /// Harmonics 0 through 31. A bump one sector wide needs about 16.
    public static let modeCount = 32
    /// Uniform samples used to project target profiles and to draw.
    public static let sampleCount = 256

    public let restRadius: Double
    private(set) var cosine: [Double]
    private(set) var sine: [Double]
    private(set) var cosineVelocity: [Double]
    private(set) var sineVelocity: [Double]
    private(set) var cosineTarget: [Double]
    private(set) var sineTarget: [Double]

    public init(restRadius: Double) {
        self.restRadius = restRadius.isFinite ? max(1, restRadius) : 1
        let zeros = Array(repeating: 0.0, count: Self.modeCount)
        cosine = zeros; sine = zeros
        cosineVelocity = zeros; sineVelocity = zeros
        cosineTarget = zeros; sineTarget = zeros
    }

    /// The angle of sample `index`.
    public static func angle(ofSample index: Int) -> Double {
        2 * .pi * Double(index) / Double(sampleCount)
    }

    /// A smooth bump with compact support: 1 at zero offset, 0 beyond
    /// `halfWidth`, with zero slope at both ends.
    public static func bump(offset: Double, halfWidth: Double) -> Double {
        guard halfWidth > 0 else { return 0 }
        let q = offset / halfWidth
        guard abs(q) < 1 else { return 0 }
        let a = 1 - q * q
        return a * a * a
    }

    /// The same angle in -pi...pi.
    public static func wrapped(_ angle: Double) -> Double {
        remainder(angle, 2 * .pi)
    }

    // MARK: Targets and impulses

    /// Projects `samples.count == sampleCount` target displacements onto the
    /// harmonics. Detail finer than the highest harmonic is filtered out.
    public mutating func setTarget(_ samples: [Double]) {
        guard samples.count == Self.sampleCount else { return }
        Self.project(samples, cosine: &cosineTarget, sine: &sineTarget)
        // Lanczos sigma factors: cutting the series off at a crease, such as
        // where a pulled lobe meets the rim, otherwise leaves ripples all
        // around the outline.
        for mode in 1..<Self.modeCount {
            cosineTarget[mode] *= Self.sigma[mode]
            sineTarget[mode] *= Self.sigma[mode]
        }
    }

    private static let sigma: [Double] = (0..<modeCount).map { mode in
        guard mode > 0 else { return 1 }
        let x = Double.pi * Double(mode) / Double(modeCount)
        return sin(x) / x
    }

    /// Adds a localised push to the outline's velocity. A positive `speed`
    /// moves the outline outward, in points per second at the centre of the
    /// push. The push has zero mean, so it does not change the enclosed area
    /// to first order.
    public mutating func strike(angle: Double, halfWidth: Double, speed: Double) {
        guard angle.isFinite, halfWidth.isFinite, speed.isFinite, halfWidth > 0, speed != 0 else { return }
        var samples = Array(repeating: 0.0, count: Self.sampleCount)
        for index in samples.indices {
            samples[index] = speed * Self.bump(offset: Self.wrapped(Self.angle(ofSample: index) - angle),
                                               halfWidth: halfWidth)
        }
        var addCosine = Array(repeating: 0.0, count: Self.modeCount)
        var addSine = addCosine
        Self.project(samples, cosine: &addCosine, sine: &addSine)
        // Harmonic 0 is uniform growth. Leaving it out keeps the push area-neutral.
        for mode in 1..<Self.modeCount {
            cosineVelocity[mode] += addCosine[mode]
            sineVelocity[mode] += addSine[mode]
        }
    }

    // MARK: Motion

    public mutating func advance(_ elapsed: Double, spectrum: Spectrum) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        for mode in 0..<Self.modeCount {
            let parameters = spectrum.modes[mode]
            let a = LayoutWheelLiquidSpring.step(displacement: cosine[mode] - cosineTarget[mode],
                                                 velocity: cosineVelocity[mode], elapsed: elapsed, parameters)
            cosine[mode] = cosineTarget[mode] + a.displacement
            cosineVelocity[mode] = a.velocity
            let b = LayoutWheelLiquidSpring.step(displacement: sine[mode] - sineTarget[mode],
                                                 velocity: sineVelocity[mode], elapsed: elapsed, parameters)
            sine[mode] = sineTarget[mode] + b.displacement
            sineVelocity[mode] = b.velocity
        }
    }

    /// The largest possible distance, anywhere on the outline, between the
    /// drawn and the target displacement. It bounds every sample, because no
    /// harmonic can exceed its own amplitude.
    public var maximumTargetError: Double {
        var sum = 0.0
        for mode in 0..<Self.modeCount {
            sum += abs(cosine[mode] - cosineTarget[mode]) + abs(sine[mode] - sineTarget[mode])
        }
        return sum
    }

    /// The largest possible outline speed anywhere, in points per second.
    public var maximumSpeed: Double {
        var sum = 0.0
        for mode in 0..<Self.modeCount { sum += abs(cosineVelocity[mode]) + abs(sineVelocity[mode]) }
        return sum
    }

    /// At rest the outline is within 0.02 pt of its target everywhere and
    /// moves less than 0.2 pt per second: far below one pixel.
    public var isSettled: Bool { maximumTargetError <= 0.02 && maximumSpeed <= 0.2 }

    public mutating func settle() {
        cosine = cosineTarget; sine = sineTarget
        for mode in 0..<Self.modeCount { cosineVelocity[mode] = 0; sineVelocity[mode] = 0 }
    }

    /// Moves the whole outline in or out at once, keeping the target: the
    /// springs then carry it back, ringing in the breathing harmonic.
    public mutating func offsetUniformly(by distance: Double) {
        guard distance.isFinite else { return }
        cosine[0] += distance
    }

    /// Returns the outline to a still circle immediately.
    public mutating func reset() { self = Self(restRadius: restRadius) }

    // MARK: Reading the outline

    public func displacement(at angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        var result = cosine[0]
        // Chebyshev recurrence: one cos/sin pair for every harmonic.
        let c1 = cos(angle), s1 = sin(angle)
        var c = c1, s = s1
        for mode in 1..<Self.modeCount {
            result += cosine[mode] * c + sine[mode] * s
            let nextC = c * c1 - s * s1
            s = s * c1 + c * s1
            c = nextC
        }
        return result
    }

    public func radius(at angle: Double) -> Double { restRadius + displacement(at: angle) }

    /// Fills `radius`, its first and its second angular derivative at every
    /// sample. The derivatives are exact, so drawn normals and curvature stay
    /// smooth between samples.
    public func sample(into output: inout [SIMD4<Float>]) {
        if output.count != Self.sampleCount {
            output = Array(repeating: .zero, count: Self.sampleCount)
        }
        Self.tables.cosine.withUnsafeBufferPointer { cosTable in
            Self.tables.sine.withUnsafeBufferPointer { sinTable in
                cosine.withUnsafeBufferPointer { a in
                    sine.withUnsafeBufferPointer { b in
                        output.withUnsafeMutableBufferPointer { out in
                            for index in 0..<Self.sampleCount {
                                var value = a[0], first = 0.0, second = 0.0
                                for mode in 1..<Self.modeCount {
                                    let table = mode * Self.sampleCount + index
                                    let c = cosTable[table], s = sinTable[table]
                                    let n = Double(mode)
                                    let wave = a[mode] * c + b[mode] * s
                                    value += wave
                                    first += n * (b[mode] * c - a[mode] * s)
                                    second -= n * n * wave
                                }
                                out[index] = SIMD4(Float(restRadius + value), Float(first), Float(second), 0)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The enclosed area divided by the rest circle's area.
    public var areaRatio: Double {
        var sum = 0.0
        for index in 0..<Self.sampleCount {
            let r = radius(at: Self.angle(ofSample: index))
            sum += r * r
        }
        return sum / Double(Self.sampleCount) / (restRadius * restRadius)
    }

    // MARK: Spectrum

    /// Spring parameters for each harmonic, from two tuning values.
    ///
    /// The frequencies follow the capillary waves of a two-dimensional liquid
    /// ring, where harmonic n vibrates at a rate proportional to
    /// sqrt(n(n^2-1)). The damping follows viscous loss, which grows with n^2.
    /// Together they let the broad shape wobble while fine ripples vanish.
    public struct Spectrum: Equatable, Sendable {
        public private(set) var modes: [LayoutWheelLiquidSpring.Parameters]

        /// - Parameters:
        ///   - tension: the frequency of the oval (second) harmonic, in hertz.
        ///   - ringing: the damping ratio of the oval harmonic. Lower rings longer.
        ///   - reduceMotion: critically damps every harmonic, so nothing rings.
        public init(tension: Double, ringing: Double, reduceMotion: Bool = false) {
            let tension = tension.isFinite ? min(12, max(0.5, tension)) : 2.6
            let ringing = ringing.isFinite ? min(1, max(0.05, ringing)) : 0.32
            let oval = 2 * Double.pi * tension
            // Detail above this rate cannot be shown at 60 Hz and only flickers.
            let ceiling = 2 * Double.pi * 24
            let decay = ringing * oval // Viscous decay rate of harmonic 2, per second.
            modes = (0..<LayoutWheelLiquidRim.modeCount).map { mode in
                let n = Double(mode)
                let omega: Double
                let zeta: Double
                switch mode {
                case 0:
                    // Uniform growth: area correction drives it, so return briskly.
                    omega = oval * 1.6; zeta = 0.7
                case 1:
                    // A sideways shift of the whole outline.
                    omega = oval; zeta = min(1, ringing + 0.15)
                default:
                    omega = min(ceiling, oval * (n * (n * n - 1) / 6).squareRoot())
                    zeta = decay * n * (n - 1) / 2 / omega
                }
                return .init(angularFrequency: omega, dampingRatio: reduceMotion ? 1 : zeta)
            }
        }
    }

    // MARK: Projection

    private struct Tables: Sendable {
        let cosine: [Double]
        let sine: [Double]
    }

    private static let tables: Tables = {
        var cosine = Array(repeating: 0.0, count: modeCount * sampleCount)
        var sine = cosine
        for mode in 0..<modeCount {
            for index in 0..<sampleCount {
                let angle = Double(mode) * Self.angle(ofSample: index)
                cosine[mode * sampleCount + index] = cos(angle)
                sine[mode * sampleCount + index] = sin(angle)
            }
        }
        return Tables(cosine: cosine, sine: sine)
    }()

    private static func project(_ samples: [Double], cosine: inout [Double], sine: inout [Double]) {
        let count = Double(sampleCount)
        tables.cosine.withUnsafeBufferPointer { cosTable in
            tables.sine.withUnsafeBufferPointer { sinTable in
                samples.withUnsafeBufferPointer { f in
                    for mode in 0..<modeCount {
                        var a = 0.0, b = 0.0
                        let row = mode * sampleCount
                        for index in 0..<sampleCount {
                            a += f[index] * cosTable[row + index]
                            b += f[index] * sinTable[row + index]
                        }
                        let scale = mode == 0 ? 1 / count : 2 / count
                        cosine[mode] = a * scale
                        sine[mode] = mode == 0 ? 0 : b * scale
                    }
                }
            }
        }
    }
}
