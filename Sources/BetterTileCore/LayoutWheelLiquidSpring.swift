import Foundation

/// A unit-mass damped spring solved in closed form.
///
/// The exact solution replaces numerical integration, so one long step and
/// many short steps land on the same trajectory. The liquid Layout Wheel
/// therefore looks the same at 60 Hz and 120 Hz, and a test can replay it
/// with any time step. Damping ratios of one or more use the critically
/// damped solution; the wheel never needs a slower, overdamped channel.
public struct LayoutWheelLiquidSpring: Equatable, Sendable {
    public struct Parameters: Equatable, Sendable {
        /// The undamped natural frequency, in radians per second.
        public var angularFrequency: Double
        /// 0 rings forever, 1 is critical damping.
        public var dampingRatio: Double

        public init(angularFrequency: Double, dampingRatio: Double) {
            self.angularFrequency = angularFrequency.isFinite ? max(0.01, angularFrequency) : 1
            self.dampingRatio = dampingRatio.isFinite ? min(1, max(0.01, dampingRatio)) : 1
        }

        /// `response` is the undamped period in seconds. It sets how quickly the
        /// spring reacts; it is not a guaranteed duration.
        public init(response: Double, dampingRatio: Double) {
            let response = response.isFinite ? max(0.001, response) : 1
            self.init(angularFrequency: 2 * .pi / response, dampingRatio: dampingRatio)
        }
    }

    public var value: Double
    public var velocity: Double
    public var target: Double

    public init(value: Double = 0, target: Double? = nil) {
        self.value = value
        velocity = 0
        self.target = target ?? value
    }

    public mutating func advance(_ elapsed: Double, _ parameters: Parameters) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        let next = Self.step(displacement: value - target, velocity: velocity,
                             elapsed: elapsed, parameters)
        value = target + next.displacement
        velocity = next.velocity
        if !value.isFinite || !velocity.isFinite { settle() }
    }

    /// True when both the distance to the target and the speed are below the
    /// given tolerances, in the channel's own units.
    public func isSettled(tolerance: Double, velocityTolerance: Double) -> Bool {
        abs(value - target) <= tolerance && abs(velocity) <= velocityTolerance
    }

    public mutating func settle() {
        value = target
        velocity = 0
    }

    /// Exact displacement and velocity after `elapsed` seconds.
    public static func step(displacement y: Double, velocity v: Double, elapsed t: Double,
                            _ parameters: Parameters) -> (displacement: Double, velocity: Double) {
        let omega = parameters.angularFrequency
        let zeta = parameters.dampingRatio
        if zeta >= 0.9999 {
            let decay = exp(-omega * t)
            let b = v + omega * y
            return ((y + b * t) * decay, (v - omega * b * t) * decay)
        }
        let damped = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * t)
        let c = cos(damped * t)
        let s = sin(damped * t)
        let displacement = decay * (y * c + (v + zeta * omega * y) / damped * s)
        let velocity = decay * (v * c - (omega * omega * y + zeta * omega * v) / damped * s)
        return (displacement, velocity)
    }
}
