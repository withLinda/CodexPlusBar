import Foundation

struct BackupManifest: Codable, Sendable {
    var schemaVersion = 1
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    var createdAt = Date()
    var profileCount: Int
    var preferences: BackupPreferences
    var cookies: [String: [BackupCookie]]

    func validate(profiles: [PlusProfile]) throws {
        guard schemaVersion == 1 else { throw BackupError.unsupportedVersion }
        guard profileCount == profiles.count, profiles.count <= 10_000,
              Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map(\.webDataStoreID)).count == profiles.count,
              createdAt.timeIntervalSince1970.isFinite,
              appVersion.utf8.count < 128 else { throw BackupError.invalidData }
        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id.uuidString, $0) })
        for (id, values) in cookies {
            guard let profile = profilesByID[id], values.count <= 1_000,
                  values.allSatisfy({ $0.isValid(for: profile.provider) }) else { throw BackupError.invalidData }
        }
        try preferences.validate()
    }
}

struct BackupPreferences: Codable, Sendable, Equatable {
    var appearance: String?
    var contrast: String?
    var displayOrder: String?
    var pinnedProfile: String?
    var textScale: Double?
    var automaticSync: Bool?

    func validate() throws {
        guard appearance.map({ ["system", "light", "dark"].contains($0) }) ?? true,
              contrast.map({ ["hard", "medium", "soft"].contains($0) }) ?? true,
              displayOrder.map({ ProfileDisplayOrder(rawValue: $0) != nil }) ?? true,
              pinnedProfile.map({ $0.isEmpty || UUID(uuidString: $0) != nil }) ?? true,
              textScale.map({ $0.isFinite && (0.5...3).contains($0) }) ?? true else { throw BackupError.invalidData }
    }
}

struct BackupCookie: Codable, Sendable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    var expires: Date?
    var sameSite: String?

    init(name: String, value: String, domain: String, path: String, secure: Bool, httpOnly: Bool, expires: Date?, sameSite: String?) {
        self.name = name; self.value = value; self.domain = domain; self.path = path
        self.secure = secure; self.httpOnly = httpOnly; self.expires = expires; self.sameSite = sameSite
    }

    init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
        secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly; expires = cookie.expiresDate
        sameSite = cookie.properties?[HTTPCookiePropertyKey("SameSite")] as? String
    }

    func isValid(for provider: ProfileProvider) -> Bool {
        let host = provider == .codex ? "chatgpt.com" : "claude.ai"
        let normalized = domain.hasPrefix(".") ? String(domain.dropFirst()).lowercased() : domain.lowercased()
        return (normalized == host || normalized.hasSuffix("." + host)) &&
            !name.isEmpty && name.utf8.count < 1_024 && value.utf8.count <= 65_536 &&
            path.hasPrefix("/") && path.utf8.count <= 4_096 &&
            [name, value, domain, path].allSatisfy { !$0.contains("\0") && !$0.contains("\r") && !$0.contains("\n") } &&
            (expires?.timeIntervalSince1970.isFinite ?? true) && cookie != nil
    }

    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires { properties[.expires] = expires }
        if let sameSite { properties[HTTPCookiePropertyKey("SameSite")] = sameSite }
        return HTTPCookie(properties: properties)
    }
}
