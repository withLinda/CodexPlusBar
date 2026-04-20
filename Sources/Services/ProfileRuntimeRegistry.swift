import Foundation
import WebKit

@MainActor
protocol ProfileDataStoreManaging: AnyObject {
    func dataStore(for identifier: UUID) -> WKWebsiteDataStore
    func removeDataStore(for identifier: UUID) async throws
}

@MainActor
final class DefaultProfileDataStoreManager: ProfileDataStoreManaging {
    func dataStore(for identifier: UUID) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: identifier)
    }

    func removeDataStore(for identifier: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

@MainActor
final class ProfileRuntimeRegistry {
    private var runtimesByProfileID: [UUID: PlusProfileRuntime] = [:]
    private let dataStoreManager: ProfileDataStoreManaging

    init(dataStoreManager: ProfileDataStoreManaging = DefaultProfileDataStoreManager()) {
        self.dataStoreManager = dataStoreManager
    }

    func runtime(for profile: PlusProfile) -> PlusProfileRuntime {
        if let existing = runtimesByProfileID[profile.id] {
            return existing
        }

        let runtime = PlusProfileRuntime(
            profileID: profile.id,
            dataStore: dataStoreManager.dataStore(for: profile.webDataStoreID)
        )
        runtimesByProfileID[profile.id] = runtime
        return runtime
    }

    func clearSession(for profile: PlusProfile) async {
        let runtime = runtime(for: profile)
        await runtime.sessionStore.clear()
    }

    func releaseRuntime(for profileID: UUID) {
        runtimesByProfileID.removeValue(forKey: profileID)
    }

    func removeProfileData(for profile: PlusProfile) async throws {
        releaseRuntime(for: profile.id)
        try await dataStoreManager.removeDataStore(for: profile.webDataStoreID)
    }
}
