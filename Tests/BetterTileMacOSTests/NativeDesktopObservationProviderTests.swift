import BetterTileCore
import Foundation
import Testing
@testable import BetterTileMacOS

private let nativeMainDisplay = DisplayID(rawValue: "1")
private let nativeSecondDisplay = DisplayID(rawValue: "2")

@MainActor
@Test(.macOSTestApplication) func disabledNativeDesktopProviderNeverLoadsSkyLight() {
    let provider = NativeDesktopObservationProvider(disabled: true)

    #expect(!provider.isAvailable)
    #expect(provider.observation(displays: [], exactWindowIDs: [:]) == nil)
}

@Test(.macOSTestApplication) func nativeDesktopParserAcceptsCompleteValidatedTopology() throws {
    let observation = try #require(NativeDesktopObservationParser.topology(
        from: [
            managedDisplay("Main", current: 11, spaces: [(11, 0), (12, 4)]),
            managedDisplay("SECOND", current: 21, spaces: [(21, 0)]),
        ],
        expectedDisplayIDs: [nativeMainDisplay, nativeSecondDisplay],
        displayAliases: ["Main": nativeMainDisplay, "SECOND": nativeSecondDisplay]
    ))

    #expect(observation.currentSpaceByDisplay[nativeMainDisplay] == NativeSpaceID(rawValue: 11))
    #expect(observation.knownSpacesByDisplay[nativeMainDisplay] == [
        NativeSpaceID(rawValue: 11), NativeSpaceID(rawValue: 12),
    ])
    #expect(observation.fullscreenSpaceIDs == [NativeSpaceID(rawValue: 12)])
}

@Test(.macOSTestApplication) func nativeDesktopParserRejectsIncompleteDisplayCoverage() {
    let observation = NativeDesktopObservationParser.topology(
        from: [managedDisplay("SECOND", current: 11, spaces: [(11, 0)])],
        expectedDisplayIDs: [nativeMainDisplay, nativeSecondDisplay],
        displayAliases: ["Main": nativeMainDisplay, "SECOND": nativeSecondDisplay]
    )

    #expect(observation == nil)
}

@Test(.macOSTestApplication) func nativeDesktopParserExpandsOneGlobalMainSpaceAcrossDisplays() throws {
    let observation = try #require(NativeDesktopObservationParser.topology(
        from: [managedDisplay("Main", current: 11, spaces: [(11, 0)])],
        expectedDisplayIDs: [nativeMainDisplay, nativeSecondDisplay],
        displayAliases: ["Main": nativeMainDisplay, "SECOND": nativeSecondDisplay]
    ))

    #expect(observation.currentSpaceByDisplay == [
        nativeMainDisplay: NativeSpaceID(rawValue: 11),
        nativeSecondDisplay: NativeSpaceID(rawValue: 11),
    ])
}

@Test(.macOSTestApplication) func nativeDesktopParserRejectsCurrentSpaceOutsideKnownSpaces() {
    let observation = NativeDesktopObservationParser.topology(
        from: [managedDisplay("Main", current: 99, spaces: [(11, 0)])],
        expectedDisplayIDs: [nativeMainDisplay],
        displayAliases: ["Main": nativeMainDisplay]
    )

    #expect(observation == nil)
}

@Test(.macOSTestApplication) func nativeDesktopParserRejectsMalformedExpectedContainers() {
    let observation = NativeDesktopObservationParser.topology(
        from: [[
            "Display Identifier": "Main",
            "Current Space": ["id64": NSNumber(value: 11)],
            "Spaces": "not an array",
        ]],
        expectedDisplayIDs: [nativeMainDisplay],
        displayAliases: ["Main": nativeMainDisplay]
    )

    #expect(observation == nil)
}

@Test(.macOSTestApplication) func nativeMembershipAcceptsStickyAndEmptyMemberships() {
    let known: Set<NativeSpaceID> = [NativeSpaceID(rawValue: 11), NativeSpaceID(rawValue: 12)]

    #expect(NativeDesktopObservationParser.membership(
        from: [NSNumber(value: 11), NSNumber(value: 12)],
        knownSpaceIDs: known
    ) == known)
    #expect(NativeDesktopObservationParser.membership(
        from: [NSNumber](),
        knownSpaceIDs: known
    ) == [])
}

@Test(.macOSTestApplication) func nativeMembershipRejectsUnknownOrMalformedSpaceIDs() {
    let known: Set<NativeSpaceID> = [NativeSpaceID(rawValue: 11)]

    #expect(NativeDesktopObservationParser.membership(
        from: [NSNumber(value: 99)],
        knownSpaceIDs: known
    ) == nil)
    #expect(NativeDesktopObservationParser.membership(
        from: ["11"],
        knownSpaceIDs: known
    ) == nil)
    #expect(NativeDesktopObservationParser.membership(
        from: [NSNumber(value: true)],
        knownSpaceIDs: known
    ) == nil)
}

private func managedDisplay(
    _ identifier: String,
    current: UInt64,
    spaces: [(UInt64, Int)]
) -> [String: Any] {
    [
        "Display Identifier": identifier,
        "Current Space": ["id64": NSNumber(value: current)],
        "Spaces": spaces.map { id, type in
            ["id64": NSNumber(value: id), "type": NSNumber(value: type)]
        },
    ]
}
