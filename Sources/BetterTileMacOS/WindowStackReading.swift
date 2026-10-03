import AppKit
import BetterTileCore

@MainActor
public protocol WindowStackReading {
    func onScreenStack(labeling ids: Set<WindowID>) -> [SeamStackEntry]?
}

/// Reads only the five public fields needed for seam coverage.
enum SeamStackRecord {
    static func parseStack(
        _ records: [[CFString: Any]], identities: WindowIdentityRegistry, labeling ids: Set<WindowID>
    ) -> [SeamStackEntry]? {
        // Without the exact join, a layout member looks like a foreign cover.
        guard ids.allSatisfy({ identities.exactWindowID(for: $0) != nil }) else { return nil }
        let entries = records.compactMap { record in
            parse(value: { record[$0] }, identities: identities, labeling: ids)
        }
        // Known inactive tabs may be off-screen. Validate only records that
        // are present, without letting a wrong owner or malformed frame pass.
        let numbers = Set(records.compactMap { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value })
        let present = ids.filter { identities.exactWindowID(for: $0).map(numbers.contains) == true }
        guard Set(entries.compactMap(\.windowID)).isSuperset(of: present) else { return nil }
        return entries
    }

    static func parse(
        value: (CFString) -> Any?, identities: WindowIdentityRegistry, labeling ids: Set<WindowID>
    ) -> SeamStackEntry? {
        guard let number = value(kCGWindowNumber) as? NSNumber,
              let owner = value(kCGWindowOwnerPID) as? NSNumber,
              let layer = value(kCGWindowLayer) as? NSNumber,
              let bounds = value(kCGWindowBounds) as? [String: Any],
              let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0
        else { return nil }
        let exactID = identities.windowID(forExactWindowID: number.uint32Value)
        let windowID = exactID.flatMap { id in
            ids.contains(id) && identities.records[id]?.application.processIdentifier == owner.int32Value ? id : nil
        }
        return SeamStackEntry(
            windowID: windowID,
            processIdentifier: owner.int32Value, layer: layer.intValue,
            alpha: (value(kCGWindowAlpha) as? NSNumber)?.doubleValue ?? 1,
            frame: BTRect(x: x, y: y, width: width, height: height)
        )
    }
}
