import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

// Pure observer admission checks. These do not validate the model retry scheduler.
@Suite(.macOSTestApplication) struct ReadinessAdmissionValidationTests {
    @Test func separateUnmappedCreationsRemainSeparateDeliveries() throws {
        let app = ApplicationLaunchInstance(processIdentifier: 81, generation: 1)
        var lifetime = WindowObservationLifetime()
        var identities = WindowIdentityRegistry()
        lifetime.install(app)
        let first = try #require(lifetime.capture(kind: .created, application: app,
            accessibilityHash: 100, identities: identities))
        let second = try #require(lifetime.capture(kind: .created, application: app,
            accessibilityHash: 200, identities: identities))
        _ = identities.resolve(application: app, accessibilityHash: 100, exactWindowID: 700)
        // A scan between capture and delivery must not invent identity for either callback.
        let deliveredFirst = try #require(lifetime.event(for: first, identities: identities))
        let deliveredSecond = try #require(lifetime.event(for: second, identities: identities))
        #expect(deliveredFirst.windowID == nil)
        #expect(deliveredSecond.windowID == nil)
        #expect(deliveredFirst.processIdentifier == 81 && deliveredSecond.processIdentifier == 81)
        #expect(deliveredFirst.kind == .created && deliveredSecond.kind == .created)
    }

    @Test func knownSiblingDestructionDoesNotInvalidateUnknownCreation() throws {
        let app = ApplicationLaunchInstance(processIdentifier: 81, generation: 1)
        var lifetime = WindowObservationLifetime()
        var identities = WindowIdentityRegistry()
        lifetime.install(app)
        let sibling = identities.resolve(application: app, accessibilityHash: 100, exactWindowID: 700)
        let arrival = try #require(lifetime.capture(kind: .created, application: app,
            accessibilityHash: 200, identities: identities))
        let destruction = try #require(lifetime.capture(kind: .destroyed, application: app,
            accessibilityHash: 100, identities: identities))
        #expect(lifetime.event(for: destruction, identities: identities)?.windowID == sibling)
        identities.remove(sibling)
        let delivered = try #require(lifetime.event(for: arrival, identities: identities))
        #expect(delivered.kind == .created && delivered.windowID == nil)
        #expect(identities.records.isEmpty)
    }

    @Test func nilIdentityCreationCannotCrossObserverOrLaunchReplacement() throws {
        let old = ApplicationLaunchInstance(processIdentifier: 81, generation: 1)
        let replacement = ApplicationLaunchInstance(processIdentifier: 81, generation: 2)
        let identities = WindowIdentityRegistry()
        var lifetime = WindowObservationLifetime()
        lifetime.install(old)
        let oldCapture = try #require(lifetime.capture(kind: .created, application: old,
            accessibilityHash: 100, identities: identities))
        lifetime.install(old)
        #expect(lifetime.event(for: oldCapture, identities: identities) == nil)
        let renewed = try #require(lifetime.capture(kind: .created, application: old,
            accessibilityHash: 100, identities: identities))
        lifetime.install(replacement)
        #expect(lifetime.event(for: renewed, identities: identities) == nil)
        #expect(lifetime.capture(kind: .created, application: old,
            accessibilityHash: 100, identities: identities) == nil)
        let fresh = try #require(lifetime.capture(kind: .created, application: replacement,
            accessibilityHash: 100, identities: identities))
        #expect(lifetime.event(for: fresh, identities: identities)?.kind == .created)
    }
}
