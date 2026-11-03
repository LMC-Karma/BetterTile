import Foundation

/// Chooses which windows a Save Current Layout capture includes. Pure policy.
/// The caller supplies only eligible windows of one display's current desktop.
public enum SavedLayoutCaptureSelection {
    /// Adaptive and Tabbed: windows in the pane tree or in a Tabbed pane. They cannot be left out,
    /// because the tree is the layout. Manual has no members.
    public static func members(of session: SavedLayoutSession) -> Set<WindowID> {
        switch session {
        case .manual: []
        case let .bento(state): Set(state.root?.windowIDs ?? [])
        case let .tabbed(state): state.windowIDs
        }
    }

    /// Manual: every eligible window. Adaptive and Tabbed: the members. Deliberate floats and other
    /// windows start unchecked, and the user can include them as floats.
    public static func defaultChecked(session: SavedLayoutSession, windows: [SavedLayoutEligibleWindow]) -> Set<WindowID> {
        if case .manual = session { return Set(windows.map(\.id)) }
        return members(of: session).intersection(windows.map(\.id))
    }

    /// Builds the capture input for the checked windows. Members stay in. Checked non-members become
    /// deliberate floats. Frames are clipped to the work area; a window fully outside it is an error.
    public static func input(session: SavedLayoutSession, windows: [SavedLayoutEligibleWindow],
                             checked: Set<WindowID>, workArea: BTRect) throws -> SavedLayoutCaptureInput {
        // A member with no known app (no bundle ID, or not eligible) cannot be saved. Leave it out.
        let unnamed = Self.members(of: session).subtracting(windows.map(\.id))
        var session = session
        switch session {
        case .manual: break
        case var .bento(state): unnamed.forEach { state.remove($0) }; session = .bento(state)
        case var .tabbed(state): unnamed.forEach { state.removeClosedWindow($0) }; session = .tabbed(state)
        }
        let members = Self.members(of: session)
        let included = windows.filter { checked.contains($0.id) || members.contains($0.id) }
        var frames: [WindowID: BTRect] = [:]
        for window in included {
            guard let clipped = window.frame.intersection(workArea) else {
                throw savedLayoutError("$.frames", "A checked window is outside this display. Capture was not saved.")
            }
            frames[window.id] = clipped
        }
        let floats: Set<WindowID>
        let target: SavedLayoutSession
        switch session {
        case .manual:
            floats = []; target = session
        case var .bento(state):
            floats = Set(included.map(\.id)).subtracting(members)
            state.floatingWindowIDs.formUnion(floats)
            target = .bento(state)
        case var .tabbed(state):
            floats = Set(included.map(\.id)).subtracting(members)
            var layout = state.layout
            layout.floatingWindowIDs.formUnion(floats)
            state.synchronize(with: layout)
            target = .tabbed(state)
        }
        return SavedLayoutCaptureInput(session: target, bundleIDs: Dictionary(uniqueKeysWithValues: included.map { ($0.id, $0.bundleID) }),
            frames: frames, workArea: workArea, deliberateFloatingWindowIDs: floats)
    }

    public static func capture(name: String, session: SavedLayoutSession, windows: [SavedLayoutEligibleWindow],
                               checked: Set<WindowID>, workArea: BTRect) throws -> SavedLayoutDocument {
        try SavedLayoutCapture.capture(name: name, input: input(session: session, windows: windows,
                                                                checked: checked, workArea: workArea))
    }
}
