import Foundation
import Testing
@testable import BetterTileMacOS

// MARK: - Update indicator

private let update042 = AvailableUpdate(displayVersion: "0.4.2", buildVersion: "7")
private let update043 = AvailableUpdate(displayVersion: "0.4.3", buildVersion: "8")

/// Replays a sequence of updater outcomes from the starting state.
private func finalState(
    after events: [UpdateIndicatorEvent],
    from start: UpdateIndicatorState = .idle
) -> UpdateIndicatorState {
    events.reduce(start) { UpdateIndicator.state(after: $1, from: $0) }
}

@Test func validUpdateTurnsTheIndicatorOn() {
    #expect(UpdateIndicator.state(after: .foundValidUpdate(update042), from: .idle) == .updateAvailable(update042))
    #expect(
        UpdateIndicator.state(after: .foundValidUpdate(update043), from: .updateAvailable(update042))
            == .updateAvailable(update043)
    )
}

@Test func deferringAnUpdateKeepsTheIndicatorOn() {
    #expect(
        UpdateIndicator.state(after: .userDeferredUpdate, from: .updateAvailable(update042))
            == .updateAvailable(update042)
    )
}

@Test func skippingAVersionClearsTheIndicator() {
    #expect(UpdateIndicator.state(after: .userSkippedUpdate, from: .updateAvailable(update042)) == .idle)
}

@Test func aConfirmedNoUpdateResultClearsTheIndicator() {
    #expect(UpdateIndicator.state(after: .confirmedNoUpdate, from: .updateAvailable(update042)) == .idle)
    #expect(UpdateIndicator.state(after: .confirmedNoUpdate, from: .idle) == .idle)
}

@Test(arguments: [
    ([UpdateIndicatorEvent](), UpdateIndicatorState.idle),
    ([.foundValidUpdate(update042)], .updateAvailable(update042)),
    ([.foundValidUpdate(update042), .userBeganInstallingUpdate], .updateAvailable(update042)),
    ([.foundValidUpdate(update042), .userDeferredUpdate], .updateAvailable(update042)),
])
func aFailedCheckPreservesWhicheverStateWasAlreadyShown(scenario: ([UpdateIndicatorEvent], UpdateIndicatorState)) {
    #expect(finalState(after: scenario.0 + [.checkFailed]) == scenario.1)
}

@Test func beginningAnInstallKeepsTheIndicatorUntilTheAppRelaunches() {
    // Sparkle's install choice only starts the download and install. A
    // successful install relaunches the app, where build reconciliation clears
    // it. This must not clear it early — otherwise a failed install leaves an
    // available update unadvertised.
    #expect(
        UpdateIndicator.state(after: .userBeganInstallingUpdate, from: .updateAvailable(update042))
            == .updateAvailable(update042)
    )
}

@Test func skippingAfterBeginningAnInstallStillClearsTheIndicator() {
    #expect(finalState(after: [.foundValidUpdate(update042), .userBeganInstallingUpdate, .userSkippedUpdate]) == .idle)
}

@Test func aStoredFutureUpdateSurvivesRelaunch() {
    #expect(
        UpdateIndicator.restoredState(.updateAvailable(update042), runningBuildVersion: "6")
            == .updateAvailable(update042)
    )
}

@Test func anInstalledOrOlderStoredUpdateClearsOnRelaunch() {
    #expect(UpdateIndicator.restoredState(.updateAvailable(update042), runningBuildVersion: "7") == .idle)
    #expect(UpdateIndicator.restoredState(.updateAvailable(update042), runningBuildVersion: "8") == .idle)
    #expect(UpdateIndicator.restoredState(.updateAvailable(update042), runningBuildVersion: "unknown") == .idle)
}

@Test func updateStateSurvivesPersistenceRoundTrip() throws {
    let state = UpdateIndicatorState.updateAvailable(update042)
    #expect(try JSONDecoder().decode(UpdateIndicatorState.self, from: JSONEncoder().encode(state)) == state)
}

// MARK: - Feedback link

@Test(arguments: [
    ("0.1.0", "2", "[Bug] BetterTile 0.1.0 (2): "),
    ("1.2 β?&=#", "2 +&=#", "[Bug] BetterTile 1.2 β?&=# (2 +&=#): "),
])
func feedbackURLContainsOnlyTheBugTemplateAndEscapedRunningVersion(scenario: (String, String, String)) throws {
    let url = try #require(FeedbackLink.url(version: scenario.0, build: scenario.1))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)

    #expect(components.scheme == "https")
    #expect(components.host == "github.com")
    #expect(components.path == "/LMC-Karma/BetterTile/issues/new")
    #expect(components.port == nil)
    #expect(components.user == nil)
    #expect(components.password == nil)
    #expect(components.fragment == nil)
    #expect(items.count == 2)
    #expect(items.contains(URLQueryItem(name: "template", value: "bug.yml")))
    #expect(items.contains(URLQueryItem(name: "title", value: scenario.2)))
}

// MARK: - Application volume

@Test(arguments: [(true as Bool?, true), (false, false), (nil, false)])
func onlyAReadOnlyApplicationVolumeRequiresRelocation(scenario: (Bool?, Bool)) {
    #expect(ApplicationVolume.requiresRelocation(volumeIsReadOnly: scenario.0) == scenario.1)
}

// MARK: - Sibling application launch

@Test func siblingLaunchContinuesWhenTheSiblingAlreadyTerminated() {
    #expect(SiblingApplicationLaunch.nextDecision(
        userChoseToQuitSibling: nil,
        terminationRequestAccepted: nil,
        siblingIsTerminated: true,
        deadlinePassed: false
    ) == .continueLaunching)
}

@Test func siblingLaunchAsksBeforeRequestingTermination() {
    #expect(SiblingApplicationLaunch.nextDecision(
        userChoseToQuitSibling: nil,
        terminationRequestAccepted: nil,
        siblingIsTerminated: false,
        deadlinePassed: false
    ) == .askUser)
    #expect(SiblingApplicationLaunch.nextDecision(
        userChoseToQuitSibling: false,
        terminationRequestAccepted: nil,
        siblingIsTerminated: false,
        deadlinePassed: false
    ) == .quitCurrentApplication)
    #expect(SiblingApplicationLaunch.nextDecision(
        userChoseToQuitSibling: true,
        terminationRequestAccepted: nil,
        siblingIsTerminated: false,
        deadlinePassed: false
    ) == .requestTermination)
}

@Test func siblingLaunchWaitsForAnAcceptedTerminationRequest() {
    #expect(SiblingApplicationLaunch.nextDecision(
        userChoseToQuitSibling: true,
        terminationRequestAccepted: true,
        siblingIsTerminated: false,
        deadlinePassed: false
    ) == .waitForTermination)
    #expect(SiblingApplicationLaunch.nextDecision(
        userChoseToQuitSibling: true,
        terminationRequestAccepted: true,
        siblingIsTerminated: true,
        deadlinePassed: false
    ) == .continueLaunching)
}

@Test func siblingLaunchReportsRejectedOrTimedOutTermination() {
    #expect(SiblingApplicationLaunch.nextDecision(
        userChoseToQuitSibling: true,
        terminationRequestAccepted: false,
        siblingIsTerminated: false,
        deadlinePassed: false
    ) == .showTerminationFailure)
    #expect(SiblingApplicationLaunch.nextDecision(
        userChoseToQuitSibling: true,
        terminationRequestAccepted: true,
        siblingIsTerminated: false,
        deadlinePassed: true
    ) == .showTerminationFailure)
}
