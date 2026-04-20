import Foundation

enum MenuBarProfilePreference {
    static let preferredProfileIDKey = "MenuBarPreferredProfileID"

    static func normalizedProfileID(from rawValue: String?) -> UUID? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        return UUID(uuidString: trimmed)
    }

    static func storedValue(for profileID: UUID?) -> String {
        profileID?.uuidString ?? ""
    }

    static func setPreferredProfileID(
        _ profileID: UUID?,
        defaults: UserDefaults = .standard
    ) {
        let storedValue = storedValue(for: profileID)

        if storedValue.isEmpty {
            defaults.removeObject(forKey: preferredProfileIDKey)
        } else {
            defaults.set(storedValue, forKey: preferredProfileIDKey)
        }
    }

    static func preferredProfileID<S: Sequence>(
        defaults: UserDefaults = .standard,
        validProfileIDs: S
    ) -> UUID? where S.Element == UUID {
        let validIDs = Set(validProfileIDs)
        let rawValue = defaults.string(forKey: preferredProfileIDKey)

        guard let profileID = normalizedProfileID(from: rawValue) else {
            if let rawValue,
               rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                defaults.removeObject(forKey: preferredProfileIDKey)
            }
            return nil
        }

        guard validIDs.contains(profileID) else {
            defaults.removeObject(forKey: preferredProfileIDKey)
            return nil
        }

        return profileID
    }
}
