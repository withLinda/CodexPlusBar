import Foundation

enum ProfileSearch {
    private struct MatchRank: Comparable {
        let tier: Int
        let offset: Int
        let remainingLength: Int

        static func < (lhs: MatchRank, rhs: MatchRank) -> Bool {
            if lhs.tier != rhs.tier {
                return lhs.tier < rhs.tier
            }

            if lhs.offset != rhs.offset {
                return lhs.offset < rhs.offset
            }

            return lhs.remainingLength < rhs.remainingLength
        }

        func shifted(by amount: Int) -> MatchRank {
            MatchRank(
                tier: tier + amount,
                offset: offset,
                remainingLength: remainingLength
            )
        }
    }

    private struct RankedProfile {
        let snapshot: PlusProfileSnapshot
        let rank: MatchRank
        let fallbackIndex: Int
    }

    static func normalizedQuery(_ rawValue: String) -> String {
        var normalized = normalizeText(rawValue)
        if normalized.hasPrefix("mailto:") {
            normalized.removeFirst("mailto:".count)
        }

        return normalized
    }

    static func filter(
        _ orderedProfiles: [PlusProfileSnapshot],
        query rawQuery: String
    ) -> [PlusProfileSnapshot] {
        let query = normalizedQuery(rawQuery)
        guard query.isEmpty == false else {
            return orderedProfiles
        }

        let phoneDigits = ProfilePhoneNumberCatalog.normalizedDigits(rawQuery)
        let prefersPhoneMatches = isPhoneLikeQuery(rawQuery)
        var matches: [RankedProfile] = []
        matches.reserveCapacity(orderedProfiles.count)

        for (index, snapshot) in orderedProfiles.enumerated() {
            let emailRank = emailMatchRank(label: snapshot.profile.label, query: query)
                .map { prefersPhoneMatches ? $0.shifted(by: 4) : $0 }
            let phoneRank = prefersPhoneMatches
                ? phoneMatchRank(
                    phoneNumber: snapshot.profile.phoneNumber,
                    queryDigits: phoneDigits
                )
                : nil
            guard let rank = [emailRank, phoneRank].compactMap({ $0 }).min() else {
                continue
            }

            matches.append(
                RankedProfile(
                    snapshot: snapshot,
                    rank: rank,
                    fallbackIndex: index
                )
            )
        }

        matches.sort { lhs, rhs in
            if lhs.rank == rhs.rank {
                return lhs.fallbackIndex < rhs.fallbackIndex
            }

            return lhs.rank < rhs.rank
        }

        return matches.map(\.snapshot)
    }

    static func matchingPhoneNumber(
        in snapshot: PlusProfileSnapshot,
        query rawQuery: String
    ) -> String? {
        let queryDigits = ProfilePhoneNumberCatalog.normalizedDigits(rawQuery)
        guard isPhoneLikeQuery(rawQuery),
              phoneMatchRank(
                phoneNumber: snapshot.profile.phoneNumber,
                queryDigits: queryDigits
              ) != nil,
              let phoneNumber = snapshot.profile.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              phoneNumber.isEmpty == false else {
            return nil
        }

        return phoneNumber
    }

    private static func emailMatchRank(label: String, query: String) -> MatchRank? {
        emailCandidates(in: label)
            .compactMap { emailRank(candidate: $0, query: query) }
            .min()
    }

    private static func emailRank(candidate rawCandidate: String, query: String) -> MatchRank? {
        let candidate = normalizeText(rawCandidate)
        guard candidate.isEmpty == false else {
            return nil
        }

        if candidate == query {
            return MatchRank(tier: 0, offset: 0, remainingLength: 0)
        }

        if candidate.hasPrefix(query) {
            return MatchRank(
                tier: 1,
                offset: 0,
                remainingLength: candidate.count - query.count
            )
        }

        let parts = emailParts(candidate)
        let domainQuery = query.hasPrefix("@") ? String(query.dropFirst()) : query

        if parts.local == query || parts.domain == domainQuery {
            return MatchRank(
                tier: 2,
                offset: 0,
                remainingLength: candidate.count - query.count
            )
        }

        if parts.local.hasPrefix(query) {
            return MatchRank(
                tier: 3,
                offset: 0,
                remainingLength: parts.local.count - query.count
            )
        }

        if domainQuery.isEmpty == false, parts.domain.hasPrefix(domainQuery) {
            return MatchRank(
                tier: 4,
                offset: 0,
                remainingLength: parts.domain.count - domainQuery.count
            )
        }

        guard let range = candidate.range(of: query) else {
            return nil
        }

        let offset = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        let startsAtBoundary: Bool
        if range.lowerBound == candidate.startIndex {
            startsAtBoundary = true
        } else {
            let previousIndex = candidate.index(before: range.lowerBound)
            startsAtBoundary = "@.+-_".contains(candidate[previousIndex])
        }

        return MatchRank(
            tier: startsAtBoundary ? 5 : 6,
            offset: offset,
            remainingLength: candidate.count - query.count
        )
    }

    private static func phoneMatchRank(
        phoneNumber: String?,
        queryDigits: String
    ) -> MatchRank? {
        guard queryDigits.isEmpty == false,
              let phoneNumber,
              phoneNumber.isEmpty == false else {
            return nil
        }

        let candidate = ProfilePhoneNumberCatalog.normalizedDigits(phoneNumber)
        guard candidate.isEmpty == false else {
            return nil
        }

        if candidate == queryDigits {
            return MatchRank(tier: 0, offset: 0, remainingLength: 0)
        }

        if candidate.hasPrefix(queryDigits) {
            return MatchRank(
                tier: 1,
                offset: 0,
                remainingLength: candidate.count - queryDigits.count
            )
        }

        guard let range = candidate.range(of: queryDigits) else {
            return nil
        }

        return MatchRank(
            tier: 2,
            offset: candidate.distance(from: candidate.startIndex, to: range.lowerBound),
            remainingLength: candidate.count - queryDigits.count
        )
    }

    private static func isPhoneLikeQuery(_ rawValue: String) -> Bool {
        let formattingCharacters = CharacterSet(charactersIn: "+-().")
            .union(.whitespacesAndNewlines)
        let meaningfulCharacters = rawValue.unicodeScalars.filter {
            formattingCharacters.contains($0) == false
        }

        return meaningfulCharacters.isEmpty == false && meaningfulCharacters.allSatisfy {
            CharacterSet.decimalDigits.contains($0)
        }
    }

    private static func emailParts(_ email: String) -> (local: String, domain: String) {
        guard let atIndex = email.lastIndex(of: "@") else {
            return (email, "")
        }

        return (
            String(email[..<atIndex]),
            String(email[email.index(after: atIndex)...])
        )
    }

    private static func emailCandidates(in label: String) -> [String] {
        let normalizedLabel = normalizeText(label)
        guard normalizedLabel.contains("@") else {
            return []
        }

        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".!#$%&'*+/=?^_`{|}~@-")
        )
        let extracted = label
            .components(separatedBy: allowedCharacters.inverted)
            .filter { candidate in
                let parts = emailParts(candidate)
                return parts.local.isEmpty == false && parts.domain.isEmpty == false
            }

        var candidates: [String] = []
        for candidate in extracted + [label] {
            let normalizedCandidate = normalizeText(candidate)
            guard normalizedCandidate.contains("@"),
                  candidates.contains(normalizedCandidate) == false else {
                continue
            }

            candidates.append(normalizedCandidate)
        }

        return candidates
    }

    private static func normalizeText(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isWhitespace == false }
    }
}
