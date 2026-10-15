import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test(arguments: [WindowSystemEvent.Kind.moved, .resized, .minimized, .restored, .created, .destroyed, .focused])
func unknownObservationNeverManufacturesAWindowIdentity(kind: WindowSystemEvent.Kind) throws {
    let application = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    let registry = WindowIdentityRegistry()
    var lifetime = WindowObservationLifetime()
    lifetime.install(application)
    let captured = try #require(lifetime.capture(kind: kind, application: application,
        accessibilityHash: 100, identities: registry))
    let event = lifetime.event(for: captured, identities: registry)
    if kind == .created || kind == .destroyed || kind == .focused {
        #expect(event?.kind == kind)
        #expect(event?.windowID == nil)
    } else {
        #expect(event == nil)
    }
    #expect(registry.records.isEmpty)
}

@Test func capturedObservationCannotOutliveWindowOrObserverInstallation() throws {
    let application = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    var registry = WindowIdentityRegistry()
    let id = registry.resolve(application: application, accessibilityHash: 100, exactWindowID: 700)
    var lifetime = WindowObservationLifetime()
    lifetime.install(application)
    let captured = try #require(lifetime.capture(kind: .minimized, application: application,
        accessibilityHash: 100, identities: registry))
    #expect(lifetime.event(for: captured, identities: registry)?.windowID == id)
    registry.remove(id)
    #expect(lifetime.event(for: captured, identities: registry) == nil)
    #expect(registry.records.isEmpty)
    let replacementID = registry.resolve(application: application, accessibilityHash: 100, exactWindowID: 700)
    #expect(replacementID != id)
    #expect(lifetime.event(for: captured, identities: registry) == nil)
    let replacement = try #require(lifetime.capture(kind: .moved, application: application,
        accessibilityHash: 100, identities: registry))
    lifetime.install(application)
    #expect(lifetime.event(for: replacement, identities: registry) == nil)
    let beforeStop = try #require(lifetime.capture(kind: .moved, application: application,
        accessibilityHash: 100, identities: registry))
    lifetime.removeAll()
    lifetime.install(application)
    #expect(lifetime.event(for: beforeStop, identities: registry) == nil)
    lifetime.install(ApplicationLaunchInstance(processIdentifier: 42, generation: 2))
    #expect(lifetime.capture(kind: .moved, application: application,
        accessibilityHash: 100, identities: registry) == nil)
    #expect(lifetime.event(for: replacement, identities: registry) == nil)
    #expect(registry.records.count == 1)
}
