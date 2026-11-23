/// A mutable test value shared with main-actor closures, such as an injected clock
/// or pointer. A captured local `var` would warn: Swift treats main-actor function
/// types as Sendable. Main-actor isolation makes this box Sendable without a lock.
@MainActor public final class MainActorBox<Value> {
    public var value: Value
    public init(_ value: Value) { self.value = value }
}
