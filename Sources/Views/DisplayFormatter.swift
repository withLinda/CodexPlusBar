import Foundation

enum DisplayFormatter {
    struct LabeledValue: Equatable, Sendable {
        let label: String?
        let value: String
    }

    static func duration(seconds: Int) -> String {
        let totalSeconds = max(0, seconds)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let days = hours / 24

        if days > 0 {
            let remainingHours = hours % 24
            return remainingHours > 0 ? "\(days)d \(remainingHours)h" : "\(days)d"
        }

        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }

        return "\(minutes)m"
    }

    static func remainingDuration(until date: Date?, referenceDate: Date = .now) -> String? {
        guard let date else {
            return nil
        }

        let seconds = Int(date.timeIntervalSince(referenceDate).rounded(.down))
        guard seconds > 0 else {
            return nil
        }

        return duration(seconds: max(seconds, 60))
    }

    static func plan(_ planType: String) -> String {
        planType
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static func expiresText(_ date: Date?, referenceDate: Date = .now, capitalized: Bool = true) -> String {
        guard let date else {
            return capitalized ? "Expiry unavailable" : "expiry unavailable"
        }

        guard let remaining = remainingDuration(until: date, referenceDate: referenceDate) else {
            return capitalized ? "Expired" : "expired"
        }

        let prefix = capitalized ? "Expires in" : "expires in"
        return "\(prefix) \(remaining)"
    }

    static func expiryValue(_ date: Date?, referenceDate: Date = .now, capitalized: Bool = true) -> LabeledValue {
        guard let date else {
            return LabeledValue(
                label: nil,
                value: capitalized ? "Expiry unavailable" : "expiry unavailable"
            )
        }

        guard let remaining = remainingDuration(until: date, referenceDate: referenceDate) else {
            return LabeledValue(
                label: nil,
                value: capitalized ? "Expired" : "expired"
            )
        }

        return LabeledValue(
            label: capitalized ? "Expires in" : "expires in",
            value: remaining
        )
    }

    static func updatedText(_ date: Date?, referenceDate: Date = .now) -> String? {
        guard let date else {
            return nil
        }

        let seconds = max(0, Int(referenceDate.timeIntervalSince(date).rounded(.down)))
        if seconds < 60 {
            return "Updated just now"
        }

        return "Updated \(duration(seconds: seconds)) ago"
    }

    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "Unavailable" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
