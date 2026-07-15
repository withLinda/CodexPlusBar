import Foundation
import Observation

@Observable
@MainActor
final class AppMinuteClock {
    private(set) var now: Date

    @ObservationIgnored private let nowProvider: @Sendable () async -> Date
    @ObservationIgnored private let sleep: @Sendable (UInt64) async throws -> Void
    @ObservationIgnored private var tickerTask: Task<Void, Never>?

    init(
        now: Date = .now,
        nowProvider: @escaping @Sendable () async -> Date = { .now },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(for: .nanoseconds(Int64(clamping: $0)))
        }
    ) {
        self.now = now
        self.nowProvider = nowProvider
        self.sleep = sleep
    }

    deinit {
        tickerTask?.cancel()
    }

    func start() {
        guard tickerTask == nil else { return }

        tickerTask = Task { [weak self] in
            await self?.runTickerLoop()
        }
    }

    func stop() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    static func nanosecondsUntilNextMinute(after date: Date) -> UInt64 {
        let seconds = date.timeIntervalSinceReferenceDate
        let nextMinute = (floor(seconds / 60) * 60) + 60
        let remainingSeconds = max(0, nextMinute - seconds)
        return UInt64((remainingSeconds * 1_000_000_000).rounded(.up))
    }

    private func runTickerLoop() async {
        now = await nowProvider()

        while Task.isCancelled == false {
            let delay = Self.nanosecondsUntilNextMinute(after: now)

            do {
                try await sleep(delay)
            } catch {
                break
            }

            guard Task.isCancelled == false else {
                break
            }

            now = await nowProvider()
        }
    }
}
