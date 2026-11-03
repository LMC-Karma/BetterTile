import Testing

/// Poll an observed native UI condition with bounded run-loop opportunities and wall time.
/// Give a stalled main actor at least five polls before enforcing the wall-clock deadline.
@MainActor
public func waitUntil(timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation,
                      _ condition: () -> Bool) async -> Bool {
    let step = Duration.milliseconds(20)
    let wall = ContinuousClock() // real-time: bounds native UI waits when polls or executor scheduling exceed their step
    let deadline = wall.now.advanced(by: timeout)
    var polls = 0
    for _ in 0..<Int((timeout / step).rounded(.up)) {
        polls += 1
        if condition() { return true }
        if polls >= 5, wall.now >= deadline { break }
        try? await Task.sleep(for: step) // real-time: lets AppKit and WindowServer publish the observed UI condition
    }
    if condition() { return true }
    Issue.record("Timed out waiting for a native UI condition after \(polls + 1) polls (timeout: \(timeout))",
                 sourceLocation: sourceLocation)
    return false
}
