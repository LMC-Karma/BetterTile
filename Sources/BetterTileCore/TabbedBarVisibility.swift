import Foundation

/// Auto-hide timing has no window-system effects. Callers supply monotonic time.
public struct TabbedBarVisibility: Equatable, Sendable {
    public enum Hold: Hashable, Sendable { case drag, menu, keyboard, selection, gallery, applicationPicker }
    public private(set) var isRevealed = false
    public private(set) var nextDeadline: TimeInterval?
    private var pointerInside = false
    private var holds: Set<Hold> = []
    private var dividerDragging = false

    public init() {}

    public mutating func enter(at now: TimeInterval, revealImmediately: Bool = false) {
        guard !dividerDragging, !pointerInside else { return }
        pointerInside = true
        if revealImmediately { isRevealed = true }
        nextDeadline = isRevealed ? nil : now + 0.080
    }

    public mutating func leave(at now: TimeInterval) {
        guard pointerInside else { return }
        pointerInside = false
        nextDeadline = isRevealed && holds.isEmpty ? now + 0.300 : nil
    }

    public mutating func hold(_ reason: Hold, enabled: Bool, at now: TimeInterval) {
        if enabled {
            holds.insert(reason)
            if !dividerDragging { isRevealed = true }
            nextDeadline = nil
        } else {
            guard holds.remove(reason) != nil else { return }
            if isRevealed, !pointerInside, holds.isEmpty { nextDeadline = now + 0.300 }
        }
    }

    public mutating func setDividerDragging(_ dragging: Bool) {
        dividerDragging = dragging
        if dragging {
            pointerInside = false
            nextDeadline = nil
            if holds.isEmpty { isRevealed = false }
        }
    }

    public mutating func advance(to now: TimeInterval) {
        guard let deadline = nextDeadline, now >= deadline else { return }
        nextDeadline = nil
        guard !dividerDragging else { return }
        isRevealed = pointerInside || !holds.isEmpty
    }

    public mutating func dismiss() {
        isRevealed = false
        pointerInside = false
        holds.removeAll()
        nextDeadline = nil
    }
}
