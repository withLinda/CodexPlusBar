import Foundation

struct WorkspaceLimitWindow: Equatable, Sendable {
    let usedPercent: Int
    let resetAt: Date

    var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    func remainingResetSeconds(referenceDate: Date = .now) -> Int {
        max(0, Int(resetAt.timeIntervalSince(referenceDate).rounded(.down)))
    }

    func resetDescription(referenceDate: Date = .now) -> String {
        DisplayFormatter.duration(seconds: remainingResetSeconds(referenceDate: referenceDate))
    }
}

struct WorkspaceLimitSnapshot: Equatable, Sendable {
    let workspaceID: String
    let accountID: String
    let planType: String
    let primaryWindow: WorkspaceLimitWindow
    let secondaryWindow: WorkspaceLimitWindow?
    let fetchedAt: Date
}
