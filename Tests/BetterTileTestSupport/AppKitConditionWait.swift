/// Poll an observed native UI condition with a bounded number of run-loop turns.
/// Count steps so a busy main actor does not consume the condition's entire budget.
@MainActor
public func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let step = Duration.milliseconds(20)
    for _ in 0..<Int((timeout / step).rounded(.up)) {
        if condition() { return true }
        try? await Task.sleep(for: step) // real-time: lets AppKit and WindowServer publish the observed UI condition
    }
    return condition()
}
