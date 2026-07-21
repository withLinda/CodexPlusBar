import Foundation

enum DisplayFormatter {
    struct LabeledValue: Equatable, Sendable {
        let label: String?
        let value: String
    }

    static func privateProfileLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let emailParts = parsedEmailParts(from: trimmed) else {
            return trimmed
        }

        return "\(maskedEmailLocal(emailParts.local))@\(emailParts.domain)"
    }

    static func compactStatusProfileLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return "Profile"
        }

        if let emailParts = parsedEmailParts(from: trimmed) {
            return "\(maskedEmailLocal(emailParts.local))@\(emailParts.domain.prefix(3))"
        }

        let compactSource: String
        if let atSignIndex = trimmed.firstIndex(of: "@"),
           atSignIndex > trimmed.startIndex {
            compactSource = String(trimmed[..<atSignIndex])
        } else {
            compactSource = trimmed
        }

        let cleanSource = compactSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanSource.count > 7 else {
            return cleanSource.isEmpty ? "Profile" : cleanSource
        }

        return String(cleanSource.prefix(7))
    }

    private struct EmailParts {
        let local: String
        let domain: String
    }

    private static func parsedEmailParts(from label: String) -> EmailParts? {
        guard let atIndex = label.lastIndex(of: "@"),
              atIndex > label.startIndex,
              atIndex < label.index(before: label.endIndex) else {
            return nil
        }

        let local = String(label[..<atIndex])
        let domain = String(label[label.index(after: atIndex)...])
        guard local.contains(where: \.isWhitespace) == false,
              domain.contains("."),
              domain.contains(where: \.isWhitespace) == false else {
            return nil
        }

        return EmailParts(local: local, domain: domain)
    }

    private static func maskedEmailLocal(_ local: String) -> String {
        switch local.count {
        case 11...:
            return "\(local.prefix(6))**\(local.suffix(4))"
        case 7...10:
            return "\(local.prefix(3))**\(local.suffix(2))"
        case 3...6:
            return "\(local.prefix(1))**\(local.suffix(1))"
        default:
            return "**"
        }
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

}
