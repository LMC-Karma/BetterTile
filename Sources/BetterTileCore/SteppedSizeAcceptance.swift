import Foundation

/// Some applications resize in steps, such as Terminal's character cells.
/// They settle slightly smaller than a requested size and never reach it.
/// A frame at the requested origin that falls short by less than one step
/// is the application's nearest size, not a refusal.
public enum SteppedSizeAcceptance {
    /// The largest shortfall treated as one resize step, in points.
    public static let maximumShortfall = 24.0

    public enum Verdict: Equatable, Sendable {
        /// Within the ordinary write tolerance.
        case exact
        /// Short of the request by less than one step in at least one axis.
        case stepped
        case rejected
    }

    public static func evaluate(requested: BTRect, actual: BTRect, tolerance: Double = 2) -> Verdict {
        guard abs(actual.minX - requested.minX) <= tolerance,
              abs(actual.minY - requested.minY) <= tolerance else { return .rejected }
        let widthShortfall = requested.size.width - actual.size.width
        let heightShortfall = requested.size.height - actual.size.height
        guard widthShortfall >= -tolerance, heightShortfall >= -tolerance,
              widthShortfall <= maximumShortfall, heightShortfall <= maximumShortfall else { return .rejected }
        return widthShortfall <= tolerance && heightShortfall <= tolerance ? .exact : .stepped
    }
}
