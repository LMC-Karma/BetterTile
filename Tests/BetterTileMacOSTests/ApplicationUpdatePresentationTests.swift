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

private func feedbackURLComponents() throws -> URLComponents {
    let url = try #require(FeedbackLink.url(version: "0.1.0", build: "2"))
    return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
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

@Test func aFailedCheckPreservesWhicheverStateWasAlreadyShown() {
    #expect(
        UpdateIndicator.state(after: .checkFailed, from: .updateAvailable(update042))
            == .updateAvailable(update042)
    )
    #expect(UpdateIndicator.state(after: .checkFailed, from: .idle) == .idle)
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

@Test func anInstallThatFailsLeavesTheUpdateAdvertised() {
    #expect(
        finalState(after: [.foundValidUpdate(update042), .userBeganInstallingUpdate, .checkFailed])
            == .updateAvailable(update042)
    )
}

@Test func deferringThenFailingStillAdvertisesTheUpdate() {
    #expect(
        finalState(after: [.foundValidUpdate(update042), .userDeferredUpdate, .checkFailed])
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

@Test func feedbackURLSelectsTheBugFormAndCarriesTheRunningVersion() throws {
    let components = try feedbackURLComponents()
    let items = try #require(components.queryItems)

    #expect(components.scheme == "https")
    #expect(components.host == "github.com")
    #expect(components.path == "/LMC-Karma/BetterTile/issues/new")
    #expect(items.contains(URLQueryItem(name: "template", value: "bug.yml")))
    let title = try #require(items.first { $0.name == "title" }?.value)
    #expect(title.contains("0.1.0"))
    #expect(title.contains("(2)"))
}

@Test func feedbackURLCarriesNothingBeyondTheTemplateAndTitle() throws {
    let components = try feedbackURLComponents()
    let items = try #require(components.queryItems)

    #expect(Set(items.map(\.name)) == ["template", "title"])
}

@Test func feedbackURLLeaksNoConfigurationWindowOrDiagnosticData() throws {
    // The feedback form is the app's only user-triggered outbound link, so it is
    // asserted against by content, not just by shape.
    let url = try #require(feedbackURLComponents().url)
    let lowercased = url.absoluteString.lowercased()

    for forbidden in [
        "window", "frame", "display", "screen", "bento", "layout", "shortcut",
        "config", "preference", "diagnostic", "analytics", "telemetry", "profile",
        "serial", "uuid", "hostname", "user",
    ] {
        #expect(!lowercased.contains(forbidden), "feedback URL must not mention \(forbidden)")
    }
}

// MARK: - Application volume

@Test func aReadOnlyApplicationVolumeRequiresRelocation() {
    #expect(ApplicationVolume.requiresRelocation(volumeIsReadOnly: true))
}

@Test func aWritableOrUnknownVolumeDoesNotRequireRelocation() {
    #expect(!ApplicationVolume.requiresRelocation(volumeIsReadOnly: false))
    #expect(!ApplicationVolume.requiresRelocation(volumeIsReadOnly: nil))
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
