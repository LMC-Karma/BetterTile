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
        /// Short of the request by less than one step in at least one axis,
        /// or past it when growth is allowed.
        case stepped
        case rejected
    }

    /// - Parameter allowsGrowth: Also accept a frame up to one step larger,
    ///   for a caller that then fits the layout to it.
    public static func evaluate(
        requested: BTRect, actual: BTRect, tolerance: Double = 2, allowsGrowth: Bool = false
    ) -> Verdict {
        guard abs(actual.minX - requested.minX) <= tolerance,
              abs(actual.minY - requested.minY) <= tolerance else { return .rejected }
        let widthShortfall = requested.size.width - actual.size.width
        let heightShortfall = requested.size.height - actual.size.height
        let largest = allowsGrowth ? maximumShortfall : tolerance
        guard widthShortfall >= -largest, heightShortfall >= -largest,
              widthShortfall <= maximumShortfall, heightShortfall <= maximumShortfall else { return .rejected }
        return abs(widthShortfall) <= tolerance && abs(heightShortfall) <= tolerance ? .exact : .stepped
    }
}
