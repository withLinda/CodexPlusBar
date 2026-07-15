import Foundation
import Observation

@MainActor
@Observable
final class TransientValue<Value: Equatable & Sendable> {
    private(set) var current: Value?

    @ObservationIgnored private var clearTask: Task<Void, Never>?

    func show(
        _ value: Value,
        for duration: Duration = .milliseconds(1_400)
    ) {
        current = value
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard Task.isCancelled == false, self?.current == value else {
                return
            }

            self?.current = nil
            self?.clearTask = nil
        }
    }

    func clear() {
        clearTask?.cancel()
        clearTask = nil
        current = nil
    }

    deinit {
        clearTask?.cancel()
    }
}
