import Testing
@testable import BetterTileCore

/// Cleanup asks the store once for a set of owners instead of asking once per
/// entry. The set must give the same answer as the per-entry lookups it
/// replaces, for every kind of desktop.
struct LayoutSessionOwnershipSetTests {
    @Test func ownerSetsMatchThePerEntryAnswers() throws {
        var store = LayoutSessionStore()
        var ids: [DesktopSessionID] = []
        var desktops: [SavedLayoutDesktop] = []
        func add(_ display: String, space: UInt64?, window: String) {
            let displayID = DisplayID(rawValue: display)
            let id = WindowID(rawValue: window)
            let session = store.activate(displayID: displayID, windowIDs: [id], focusedWindowID: id,
                defaultMode: .bento, reuseActiveWhenUnmatched: false,
                nativeSpaceID: space.map { NativeSpaceID(rawValue: $0) }).session
            ids.append(session.id)
            if let space { desktops.append(.init(displayID: displayID, spaceID: .init(rawValue: space))) }
        }
        // 33 retired desktops: the oldest falls off the 32-entry list.
        for index in 1...33 { add("evicted-\(index)", space: UInt64(100 + index), window: "e-\(index)") }
        store.removeMissingDisplays([])
        // Stored: active and inactive native desktops, an inferred desktop, and
        // desktops on a display that is absent but not removed (a display hold).
        add("connected", space: nil, window: "inferred")
        add("connected", space: 1, window: "first")
        add("connected", space: 2, window: "second")
        add("absent", space: 3, window: "absent")
        // Retired, and retired then forgotten when its only window closes.
        add("unplugged", space: 4, window: "retired-a")
        add("unplugged", space: 5, window: "retired-b")
        add("forgotten", space: 6, window: "forgotten")
        store.removeMissingDisplays([.init(rawValue: "connected"), .init(rawValue: "absent")])
        store.removeClosedTabbedWindow(.init(rawValue: "forgotten"))
        ids.append(DesktopSessionID())
        desktops += [.init(displayID: .init(rawValue: "connected"), spaceID: .init(rawValue: 3)),
                     .init(displayID: .init(rawValue: "nowhere"), spaceID: .init(rawValue: 1))]

        let owners = store.retainedSessionIDs
        for id in ids {
            #expect(owners.contains(id) == (store.retainedSession(id) != nil), "\(id)")
        }
        let native = store.retainedNativeDesktops
        for desktop in desktops {
            func owns(_ session: LayoutSession) -> Bool {
                session.displayID == desktop.displayID && session.nativeSpaceID == desktop.spaceID
            }
            let perEntry = store.allSessions(for: desktop.displayID).contains(where: owns)
                || store.retiredSessions.contains { owns($0.session) }
            #expect(native.contains(desktop) == perEntry, "\(desktop)")
        }
        // Every kind is present, so the comparison covers both answers.
        let kinds: [(String, Bool)] = [("connected", true), ("absent", true), ("unplugged", true),
            ("forgotten", false), ("evicted-1", false), ("evicted-33", true)]
        for (display, expected) in kinds {
            #expect(desktops.contains { $0.displayID.rawValue == display && native.contains($0) } == expected, "\(display)")
        }
        #expect(owners.count == store.retiredSessions.count + 4, "Four stored desktops plus the retired list")
    }
}
