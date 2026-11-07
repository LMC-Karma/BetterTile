import AppKit

/// Keeps owned overlay panels in sync, including panels reused during a gesture.
/// Weak references let a dismissed preview release its panels normally.
@MainActor
final class OverlayCapturePolicy {
    var showsInRecordings: Bool {
        didSet {
            guard showsInRecordings != oldValue else { return }
            for panel in panels.allObjects { apply(to: panel) }
        }
    }

    private let panels = NSHashTable<NSWindow>.weakObjects()

    init(showsInRecordings: Bool = false) {
        self.showsInRecordings = showsInRecordings
    }

    static func sharingType(showsInRecordings: Bool) -> NSWindow.SharingType {
        showsInRecordings ? .readOnly : .none
    }

    func apply(to panel: NSWindow) {
        panels.add(panel)
        panel.sharingType = Self.sharingType(showsInRecordings: showsInRecordings)
    }

#if BETTERTILE_TEST_HOOKS
    var panelsForTesting: [NSWindow] { panels.allObjects }
#endif
}
