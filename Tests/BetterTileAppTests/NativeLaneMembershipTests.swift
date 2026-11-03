import Testing

@Suite(.appTestApplication)
struct NativeLaneMembershipTests {
    @Test func laneFunctionsMatchThePinnedListForEachProduct() throws {
        try NativeLaneMembership.check()
    }

    @Test func inventoryFindsNewNestedTestsWithoutCountingFixtureText() {
        let source = #"""
        @Suite(.nativeFocus) struct Lane {
            // @Test func commentIsNotATest() { }
            let fixture = "{ @Test func stringIsNotATest() { } }"
            let interpolated = "\(["}"].map { "\($0)" })"
            @Test(arguments: [1, 2]) func first(value: Int) { func helper() {} }
            @Suite struct Nested { @Test func newlyAdded() {} }
        }
        @Suite struct Default { @Test func ordinary() {} }
        """#
        #expect(NativeLaneMembership.functions(in: source) == ["first", "newlyAdded"])
    }
}
