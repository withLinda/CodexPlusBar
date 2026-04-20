import Foundation
import Testing
@testable import CodexPlusBar

@MainActor
struct AppMinuteClockTests {
    @Test
    func schedulerWaitsForNextMinuteBoundaryThenUsesFullMinutes() async {
        let harness = MinuteClockHarness(
            dates: [
                Date(timeIntervalSince1970: 1_773_819_030),
                Date(timeIntervalSince1970: 1_773_819_060),
            ],
            finishAfterSleepCalls: 2
        )
        let clock = AppMinuteClock(
            now: Date(timeIntervalSince1970: 1_773_819_030),
            nowProvider: { await harness.nextDate() },
            sleep: { nanoseconds in
                try await harness.sleep(for: nanoseconds)
            }
        )

        clock.start()
        await harness.waitUntilTargetSleepCount()
        clock.stop()

        let sleepCalls = await harness.recordedSleepCalls()
        #expect(sleepCalls == [30_000_000_000, 60_000_000_000])
    }

    @Test
    func alignedMinuteStillSchedulesOneFullMinute() {
        let alignedDate = Date(timeIntervalSince1970: 1_773_819_060)

        #expect(AppMinuteClock.nanosecondsUntilNextMinute(after: alignedDate) == 60_000_000_000)
    }
}

private actor MinuteClockHarness {
    private var dates: [Date]
    private let finishAfterSleepCalls: Int
    private var sleepCalls: [UInt64] = []
    private var waitContinuation: CheckedContinuation<Void, Never>?

    init(dates: [Date], finishAfterSleepCalls: Int) {
        self.dates = dates
        self.finishAfterSleepCalls = finishAfterSleepCalls
    }

    func nextDate() -> Date {
        if dates.isEmpty {
            return .now
        }

        return dates.removeFirst()
    }

    func sleep(for nanoseconds: UInt64) async throws {
        sleepCalls.append(nanoseconds)

        if sleepCalls.count >= finishAfterSleepCalls {
            waitContinuation?.resume()
            waitContinuation = nil
            try await Task.sleep(nanoseconds: .max)
        }
    }

    func waitUntilTargetSleepCount() async {
        if sleepCalls.count >= finishAfterSleepCalls {
            return
        }

        await withCheckedContinuation { continuation in
            waitContinuation = continuation
        }
    }

    func recordedSleepCalls() -> [UInt64] {
        sleepCalls
    }
}
