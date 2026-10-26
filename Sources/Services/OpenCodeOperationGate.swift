actor OpenCodeOperationGate {
    static let shared = OpenCodeOperationGate()
    private var busy = false
    func withOperation<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        guard !busy else { throw OpenCodeOpenAIAuthError.busy }
        busy = true
        defer { busy = false }
        return try await operation()
    }
}
