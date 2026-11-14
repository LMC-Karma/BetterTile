import Testing

/// How a native UI condition wait ended.
public enum ConditionWaitOutcome: Equatable, Sendable {
    case satisfied
    /// The condition never held. `polls` counts every poll, including the final one.
    case timedOut(polls: Int)
}

/// Poll an observed native UI condition with bounded run-loop opportunities and wall time, and return how the
/// wait ended without recording anything. Give a stalled main actor at least five polls before enforcing the
/// wall-clock deadline.
@MainActor
public func pollUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> ConditionWaitOutcome {
    let step = Duration.milliseconds(20)
    let wall = ContinuousClock() // real-time: bounds native UI waits when polls or executor scheduling exceed their step
    let deadline = wall.now.advanced(by: timeout)
    var polls = 0
    for _ in 0..<Int((timeout / step).rounded(.up)) {
        polls += 1
        if condition() { return .satisfied }
        if polls >= 5, wall.now >= deadline { break }
        try? await Task.sleep(for: step) // real-time: lets AppKit and WindowServer publish the observed UI condition
    }
    if condition() { return .satisfied }
    return .timedOut(polls: polls + 1)
}

/// Poll an observed native UI condition as `pollUntil` does, and report a timeout as a test failure at
/// `sourceLocation`.
@MainActor
public func waitUntil(timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation,
                      reporter: HelperFailureReporter = .issue, _ condition: () -> Bool) async -> Bool {
    switch await pollUntil(timeout: timeout, condition) {
    case .satisfied:
        return true
    case let .timedOut(polls):
        reporter.record("Timed out waiting for a native UI condition after \(polls) polls (timeout: \(timeout))",
                        sourceLocation: sourceLocation)
        return false
    }
}
