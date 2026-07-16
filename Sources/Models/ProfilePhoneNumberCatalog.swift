import Foundation

struct ProfilePhoneNumberGroup: Identifiable, Equatable, Sendable {
    let id: String
    let phoneNumber: String
    let profiles: [PlusProfileSnapshot]
}

enum ProfilePhoneNumberCatalog {
    private struct RankedNumber {
        let value: String
        let tier: Int
        let offset: Int
        let fallbackIndex: Int
    }

    static func savedNumbers(in snapshots: [PlusProfileSnapshot]) -> [String] {
        var seenKeys: Set<String> = []
        var numbers: [String] = []

        for snapshot in snapshots {
            guard let rawNumber = snapshot.profile.phoneNumber else {
                continue
            }

            let number = rawNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            guard number.isEmpty == false else {
                continue
            }

            let digits = normalizedDigits(number)
            let key = digits.isEmpty ? normalizedFallback(number) : digits
            guard seenKeys.insert(key).inserted else {
                continue
            }

            numbers.append(number)
        }

        return numbers
    }

    static func numberGroups(in snapshots: [PlusProfileSnapshot]) -> [ProfilePhoneNumberGroup] {
        var orderedKeys: [String] = []
        var displayNumbers: [String: String] = [:]
        var groupedProfiles: [String: [PlusProfileSnapshot]] = [:]

        for snapshot in snapshots {
            guard let rawNumber = snapshot.profile.phoneNumber else {
                continue
            }

            let number = rawNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            guard number.isEmpty == false else {
                continue
            }

            let key = groupingKey(number)
            if groupedProfiles[key] == nil {
                orderedKeys.append(key)
                displayNumbers[key] = number
            }
            groupedProfiles[key, default: []].append(snapshot)
        }

        return orderedKeys
            .enumerated()
            .compactMap { index, key -> (index: Int, group: ProfilePhoneNumberGroup)? in
                guard let profiles = groupedProfiles[key],
                      let phoneNumber = displayNumbers[key] else {
                    return nil
                }

                return (
                    index,
                    ProfilePhoneNumberGroup(
                        id: key,
                        phoneNumber: phoneNumber,
                        profiles: profiles
                    )
                )
            }
            .sorted { lhs, rhs in
                let lhsIsShared = lhs.group.profiles.count > 1
                let rhsIsShared = rhs.group.profiles.count > 1
                if lhsIsShared != rhsIsShared {
                    return lhsIsShared
                }

                if lhs.group.profiles.count != rhs.group.profiles.count {
                    return lhs.group.profiles.count > rhs.group.profiles.count
                }

                return lhs.index < rhs.index
            }
            .map(\.group)
    }

    static func profilesWithoutNumber(in snapshots: [PlusProfileSnapshot]) -> [PlusProfileSnapshot] {
        snapshots.filter { snapshot in
            guard let phoneNumber = snapshot.profile.phoneNumber else {
                return true
            }

            return phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func matches(_ savedNumbers: [String], query rawQuery: String) -> [String] {
        let queryDigits = normalizedDigits(rawQuery)
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            return savedNumbers
        }

        var rankedNumbers: [RankedNumber] = []
        rankedNumbers.reserveCapacity(savedNumbers.count)

        for (index, number) in savedNumbers.enumerated() {
            let candidateDigits = normalizedDigits(number)
            if queryDigits.isEmpty == false,
               candidateDigits.isEmpty == false,
               let range = candidateDigits.range(of: queryDigits) {
                let offset = candidateDigits.distance(
                    from: candidateDigits.startIndex,
                    to: range.lowerBound
                )
                let tier: Int
                if candidateDigits == queryDigits {
                    tier = 0
                } else if offset == 0 {
                    tier = 1
                } else {
                    tier = 2
                }

                rankedNumbers.append(
                    RankedNumber(
                        value: number,
                        tier: tier,
                        offset: offset,
                        fallbackIndex: index
                    )
                )
                continue
            }

            let candidate = normalizedFallback(number)
            let query = normalizedFallback(trimmedQuery)
            guard query.isEmpty == false,
                  let range = candidate.range(of: query) else {
                continue
            }

            rankedNumbers.append(
                RankedNumber(
                    value: number,
                    tier: candidate.hasPrefix(query) ? 3 : 4,
                    offset: candidate.distance(from: candidate.startIndex, to: range.lowerBound),
                    fallbackIndex: index
                )
            )
        }

        rankedNumbers.sort { lhs, rhs in
            if lhs.tier != rhs.tier {
                return lhs.tier < rhs.tier
            }

            if lhs.offset != rhs.offset {
                return lhs.offset < rhs.offset
            }

            return lhs.fallbackIndex < rhs.fallbackIndex
        }

        return rankedNumbers.map(\.value)
    }

    static func normalizedDigits(_ rawValue: String) -> String {
        rawValue.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func groupingKey(_ rawValue: String) -> String {
        let digits = normalizedDigits(rawValue)
        return digits.isEmpty ? normalizedFallback(rawValue) : digits
    }

    private static func normalizedFallback(_ rawValue: String) -> String {
        rawValue
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isWhitespace == false }
    }
}
