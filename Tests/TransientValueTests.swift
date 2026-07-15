import Testing
@testable import CodexPlusBar

@MainActor
struct TransientValueTests {
    @Test
    func showReplacesCurrentValueAndClearRemovesIt() {
        let value = TransientValue<String>()

        value.show("first", for: .seconds(60))
        #expect(value.current == "first")

        value.show("second", for: .seconds(60))
        #expect(value.current == "second")

        value.clear()
        #expect(value.current == nil)
    }

    @Test
    func valueClearsAfterItsDuration() async throws {
        let value = TransientValue<String>()

        value.show("copied", for: .milliseconds(10))
        #expect(value.current == "copied")

        try await Task.sleep(for: .milliseconds(50))
        #expect(value.current == nil)
    }
}
