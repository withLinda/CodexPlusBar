import Foundation
import Security

enum CloudSyncAvailabilityError: Error { case unavailable }

struct CloudSignedEntitlements: Sendable {
    var isAdHoc: Bool
    var containers: [String]
    var services: [String]
    var environment: String?
    var pushEnvironment: String?
    var teamIdentifier: String?
    var applicationIdentifier: String?
    var keychainGroups: [String]
}

struct CloudSyncAvailability: Sendable {
    static let containerIdentifier = "iCloud.com.linda.CodexPlusBar"
    static let teamIdentifier = "2Z8N5KTWQZ"
    static let applicationIdentifier = "2Z8N5KTWQZ.com.linda.CodexPlusBar"
    let inspect: @Sendable () -> CloudSignedEntitlements?
    init(inspect: @escaping @Sendable () -> CloudSignedEntitlements? = Self.signedEntitlements) { self.inspect = inspect }

    var environment: CloudEnvironment? {
        guard let signed = inspect(), !signed.isAdHoc,
              signed.teamIdentifier == Self.teamIdentifier,
              signed.applicationIdentifier == Self.applicationIdentifier,
              signed.containers.contains(Self.containerIdentifier), signed.services.contains("CloudKit"),
              signed.keychainGroups.contains(CloudKeyStore.accessGroup) else { return nil }
        switch (signed.environment, signed.pushEnvironment) {
        case ("Production", "production"): return .production
        case ("Development", "development"): return .development
        default: return nil
        }
    }

    /// The factory is deliberately behind signed-entitlement inspection. Constructing
    /// a CKContainer first can terminate an ad-hoc process before Swift can catch it.
    func withContainer<T>(environment: CloudEnvironment? = nil, factory: (String) throws -> T) throws -> T {
        guard let available = self.environment, environment == nil || available == environment else {
            throw CloudSyncAvailabilityError.unavailable
        }
        return try factory(Self.containerIdentifier)
    }

    private static func signedEntitlements() -> CloudSignedEntitlements? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var result: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &result) == errSecSuccess,
              let info = result as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber else { return nil }
        return .init(isAdHoc: flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0,
                     containers: entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] ?? [],
                     services: entitlements["com.apple.developer.icloud-services"] as? [String] ?? [],
                     environment: entitlements["com.apple.developer.icloud-container-environment"] as? String,
                     pushEnvironment: entitlements["com.apple.developer.aps-environment"] as? String,
                     teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
                     applicationIdentifier: entitlements["com.apple.application-identifier"] as? String,
                     keychainGroups: entitlements["keychain-access-groups"] as? [String] ?? [])
    }
}
