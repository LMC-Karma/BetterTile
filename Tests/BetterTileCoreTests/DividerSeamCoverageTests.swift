import Testing
import BetterTileCore

private let seamLeft = WindowID(rawValue: "left")
private let seamRight = WindowID(rawValue: "right")
private let inactiveTab = WindowID(rawValue: "inactive")
private let seamSpan = 8.0...792.0
private let seamBand = DividerSeamCoverage.band(axis: .vertical, coordinate: 500, span: seamSpan, hitWidth: 30)
private let seamMembers: Set<WindowID> = [seamLeft, seamRight, inactiveTab]
private func seamEntry(_ id: WindowID? = nil, pid: Int32 = 1, layer: Int = 0, alpha: Double = 1, frame: BTRect) -> SeamStackEntry {
    SeamStackEntry(windowID: id, processIdentifier: pid, layer: layer, alpha: alpha, frame: frame)
}
private let seamParticipants = [
    seamEntry(seamLeft, frame: BTRect(x: 0, y: 0, width: 499, height: 800)),
    seamEntry(seamRight, frame: BTRect(x: 501, y: 0, width: 499, height: 800)),
]
private func seamCandidates(_ stack: [SeamStackEntry]) -> [BTRect] {
    DividerSeamCoverage.frontCandidates(stack: stack, ownProcess: 99, managed: seamMembers,
                                        seamParticipants: [seamLeft, seamRight], handleLayer: 3)
}
private func seamSegments(_ stack: [SeamStackEntry]) -> [ClosedRange<Double>] {
    DividerSeamCoverage.exposedSegments(span: seamSpan, axis: .vertical, band: seamBand, candidates: seamCandidates(stack))
}

@Test func seamFloatingWindowSplitsTheExposedSpan() {
    let floating = seamEntry(layer: 3, frame: BTRect(x: 380, y: 300, width: 300, height: 200))
    let segments = seamSegments([floating] + seamParticipants)
    #expect(segments == [8...300, 500...792])
    #expect(DividerSeamCoverage.segment(containing: 120, in: segments) == 8...300)
    #expect(DividerSeamCoverage.segment(containing: 400, in: segments) == nil)
}

@Test func seamIgnoresWindowsBehindBothParticipants() {
    let behind = seamEntry(frame: BTRect(x: 300, y: 100, width: 400, height: 400))
    #expect(seamCandidates(seamParticipants + [behind]).isEmpty)
    #expect(seamSegments(seamParticipants + [behind]) == [seamSpan])
}

@Test func seamWindowBetweenParticipantsStillCovers() {
    let between = seamEntry(frame: BTRect(x: 450, y: 200, width: 300, height: 100))
    #expect(seamSegments([seamParticipants[0], between, seamParticipants[1]]) == [8...200, 300...792])
}

@Test func seamIgnoresOwnInvisibleManagedAndMenuBarWindows() {
    let over = BTRect(x: 400, y: 0, width: 200, height: 800)
    let ignored = [
        seamEntry(pid: 99, layer: 3, frame: over),
        seamEntry(alpha: 0, frame: over),
        seamEntry(alpha: 0.01, frame: over),
        seamEntry(inactiveTab, frame: over),
        seamEntry(layer: 24, frame: over),
        seamEntry(layer: 25, frame: over),
        seamEntry(layer: -1, frame: over),
    ]
    #expect(seamCandidates(ignored + seamParticipants).isEmpty)
}

@Test func seamIgnoresWindowsAboveTheHandleLevel() {
    // macOS 26 reports the Dock as one display-sized window at layer 20.
    let dock = seamEntry(layer: 20, frame: BTRect(x: 0, y: 0, width: 1000, height: 800))
    let panel = seamEntry(layer: 8, frame: BTRect(x: 300, y: 740, width: 400, height: 60))
    #expect(seamCandidates([dock, panel] + seamParticipants).isEmpty)
    #expect(seamSegments([dock, panel] + seamParticipants) == [seamSpan])
    let floating = seamEntry(layer: 3, frame: BTRect(x: 300, y: 740, width: 400, height: 60))
    #expect(seamSegments([dock, floating] + seamParticipants) == [8...740])
}

@Test func seamShortExposedGapHasNoHoverHandle() {
    let covers = [
        seamEntry(frame: BTRect(x: 450, y: 0, width: 100, height: 390)),
        seamEntry(frame: BTRect(x: 450, y: 400, width: 100, height: 400)),
    ]
    let segments = seamSegments(covers + seamParticipants)
    #expect(segments == [390...400])
    #expect(DividerSeamCoverage.segment(containing: 395, in: segments) == nil)
}

@Test func seamUnknownParticipantsCountAllForeignWindows() {
    let unknown = seamParticipants.map { seamEntry(frame: $0.frame) }
    #expect(seamCandidates(unknown).count == 2)
}

@Test func seamJunctionArmsStopAtCoversAndCoveredCenterHides() {
    let center = BTPoint(x: 500, y: 400)
    let acquisition = BTRect(x: 484, y: 384, width: 32, height: 32)
    let cover = BTRect(x: 490, y: 100, width: 200, height: 250)
    let room = DividerSeamCoverage.armRoom(center: center, acquisition: acquisition, hitWidth: 30, candidates: [cover])
    #expect(room?.up == 50)
    #expect(room?.down == .infinity)
    #expect(DividerSeamCoverage.armRoom(
        center: center, acquisition: acquisition, hitWidth: 30,
        candidates: [BTRect(x: 495, y: 395, width: 100, height: 100)]
    ) == nil)
}

@Test func seamHorizontalOverlappingCoversProduceSortedDisjointSegments() {
    let band = DividerSeamCoverage.band(axis: .horizontal, coordinate: -500, span: -800 ... -8, hitWidth: 30)
    let covers = [
        BTRect(x: -400, y: -520, width: 200, height: 50),
        BTRect(x: -450, y: -510, width: 100, height: 50),
        BTRect(x: -900, y: -510, width: 200, height: 50),
        BTRect(x: -650, y: -600, width: 100, height: 50),
    ]
    #expect(DividerSeamCoverage.exposedSegments(span: -800 ... -8, axis: .horizontal, band: band, candidates: covers)
        == [-700 ... -450, -200 ... -8])
}
