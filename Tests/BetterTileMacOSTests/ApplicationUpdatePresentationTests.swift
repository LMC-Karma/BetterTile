import Foundation
import Testing
@testable import BetterTileMacOS

// MARK: - Update indicator

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
    #expect(UpdateIndicator.state(after: .foundValidUpdate, from: .idle) == .updateAvailable)
    #expect(UpdateIndicator.state(after: .foundValidUpdate, from: .updateAvailable) == .updateAvailable)
}

@Test func deferringAnUpdateKeepsTheIndicatorOn() {
    #expect(UpdateIndicator.state(after: .userDeferredUpdate, from: .updateAvailable) == .updateAvailable)
}

@Test func skippingAVersionClearsTheIndicator() {
    #expect(UpdateIndicator.state(after: .userSkippedUpdate, from: .updateAvailable) == .idle)
}

@Test func aConfirmedNoUpdateResultClearsTheIndicator() {
    #expect(UpdateIndicator.state(after: .confirmedNoUpdate, from: .updateAvailable) == .idle)
    #expect(UpdateIndicator.state(after: .confirmedNoUpdate, from: .idle) == .idle)
}

@Test func aFailedCheckPreservesWhicheverStateWasAlreadyShown() {
    #expect(UpdateIndicator.state(after: .checkFailed, from: .updateAvailable) == .updateAvailable)
    #expect(UpdateIndicator.state(after: .checkFailed, from: .idle) == .idle)
}

@Test func beginningAnInstallKeepsTheIndicatorUntilTheAppRelaunches() {
    // Sparkle's install choice only starts the download and install. A
    // successful install relaunches the app, which resets the indicator on its
    // own, so this must not clear it early — otherwise a failed install leaves
    // an available update unadvertised.
    #expect(UpdateIndicator.state(after: .userBeganInstallingUpdate, from: .updateAvailable) == .updateAvailable)
}

@Test func anInstallThatFailsLeavesTheUpdateAdvertised() {
    #expect(finalState(after: [.foundValidUpdate, .userBeganInstallingUpdate, .checkFailed]) == .updateAvailable)
}

@Test func deferringThenFailingStillAdvertisesTheUpdate() {
    #expect(finalState(after: [.foundValidUpdate, .userDeferredUpdate, .checkFailed]) == .updateAvailable)
}

@Test func skippingAfterBeginningAnInstallStillClearsTheIndicator() {
    #expect(finalState(after: [.foundValidUpdate, .userBeganInstallingUpdate, .userSkippedUpdate]) == .idle)
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
