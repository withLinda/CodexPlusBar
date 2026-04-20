import Foundation
import Testing
import WebKit
@testable import CodexPlusBar

@MainActor
struct PlusProfileControllerTests {
    @Test
    func refreshAllUpdatesEachProfileWithoutCollapsingOtherRows() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let first = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        let second = sampleProfile(label: "beta@example.com", sortOrder: 1)
        try store.saveProfiles([first, second])

        let firstUsage = makeUsage(accountID: "acct_alpha", primaryUsedPercent: 22, secondaryUsedPercent: 35)
        let service = StubPlusProfileDataService(
            refreshResults: [
                first.id: .success(
                    PlusProfileRefreshResult(
                        usage: firstUsage,
                        detectedNote: "Chatgpt Plus · alpha"
                    )
                ),
                second.id: .failure(.unauthorized),
            ]
        )
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.refreshAll()

        let rows = controller.profiles
        #expect(rows.count == 2)
        #expect(rows[0].state == .ready)
        #expect(rows[0].usage?.primaryWindow.remainingPercent == 78)
        #expect(rows[0].profile.detectedNote == "Chatgpt Plus · alpha")
        #expect(rows[1].state == .needsLogin)
        #expect(rows[1].usage == nil)

        let persisted = try store.loadProfiles()
        #expect(persisted[0].lastKnownState == .active)
        #expect(persisted[1].lastKnownState == .needsLogin)
    }

    @Test
    func refreshAllUsesAtMostThreeConcurrentProfiles() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profiles = (0..<6).map { index in
            sampleProfile(label: "account-\(index + 1)@example.com", sortOrder: index)
        }
        try store.saveProfiles(profiles)

        let service = ConcurrencyRecordingProfileDataService(delayNanoseconds: 50_000_000)
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.refreshAll()

        #expect(await service.maxConcurrent == 3)
    }

    @Test
    func clearSessionKeepsProfileButMarksItForLogin() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let store = ProfileCatalogStore(
            fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        )
        let profile = sampleProfile(label: "alpha@example.com", sortOrder: 0)
        try store.saveProfiles([profile])

        let service = StubPlusProfileDataService(
            refreshResults: [
                profile.id: .success(
                    PlusProfileRefreshResult(
                        usage: makeUsage(accountID: "acct_alpha", primaryUsedPercent: 25, secondaryUsedPercent: 40),
                        detectedNote: "Chatgpt Plus · alpha"
                    )
                ),
            ]
        )
        let controller = PlusProfileController(
            catalogStore: store,
            dataService: service,
            autoStart: false
        )

        await controller.refreshAll()
        await controller.clearSession(for: profile.id)

        let row = try #require(controller.profiles.first)
        #expect(row.state == .needsLogin)
        #expect(row.usage == nil)
        #expect(service.clearedProfileIDs == [profile.id])
        #expect(try store.loadProfiles().first?.lastKnownState == .needsLogin)
    }
}

@MainActor
private final class StubPlusProfileDataService: PlusProfileDataServing {
    private let refreshResults: [UUID: Result<PlusProfileRefreshResult, ChatGPTAPIError>]
    private(set) var clearedProfileIDs: [UUID] = []
    private(set) var removedProfileIDs: [UUID] = []
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    init(refreshResults: [UUID: Result<PlusProfileRefreshResult, ChatGPTAPIError>]) {
        self.refreshResults = refreshResults
    }

    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
        let result = try #require(refreshResults[profile.id])
        return try result.get()
    }

    func clearSession(for profile: PlusProfile) async throws {
        clearedProfileIDs.append(profile.id)
    }

    func removeProfileData(for profile: PlusProfile) async throws {
        removedProfileIDs.append(profile.id)
    }

    func dataStore(for profile: PlusProfile) -> WKWebsiteDataStore {
        if let existing = dataStores[profile.id] {
            return existing
        }

        let store = WKWebsiteDataStore.nonPersistent()
        dataStores[profile.id] = store
        return store
    }
}

private actor ConcurrencyRecorder {
    private var current = 0
    private(set) var maxConcurrent = 0

    func begin() {
        current += 1
        maxConcurrent = max(maxConcurrent, current)
    }

    func end() {
        current = max(0, current - 1)
    }
}

@MainActor
private final class ConcurrencyRecordingProfileDataService: PlusProfileDataServing {
    private let delayNanoseconds: UInt64
    private let recorder = ConcurrencyRecorder()

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    var maxConcurrent: Int {
        get async {
            await recorder.maxConcurrent
        }
    }

    func refreshProfile(_ profile: PlusProfile) async throws -> PlusProfileRefreshResult {
        await recorder.begin()
        defer {
            Task {
                await recorder.end()
            }
        }

        try await Task.sleep(nanoseconds: delayNanoseconds)
        return PlusProfileRefreshResult(
            usage: makeUsage(
                accountID: "acct_\(profile.sortOrder)",
                primaryUsedPercent: 20 + profile.sortOrder,
                secondaryUsedPercent: 30 + profile.sortOrder
            ),
            detectedNote: "Chatgpt Plus · \(profile.sortOrder)"
        )
    }

    func clearSession(for profile: PlusProfile) async throws {
    }

    func removeProfileData(for profile: PlusProfile) async throws {
    }

    func dataStore(for profile: PlusProfile) -> WKWebsiteDataStore {
        .nonPersistent()
    }
}

private func makeUsage(
    accountID: String,
    primaryUsedPercent: Int,
    secondaryUsedPercent: Int
) -> PlusProfileUsage {
    PlusProfileUsage(
        accountID: accountID,
        planType: "chatgpt_plus",
        primaryWindow: WorkspaceLimitWindow(
            usedPercent: primaryUsedPercent,
            limitWindowSeconds: 18_000,
            resetAfterSeconds: 900,
            resetAt: Date(timeIntervalSince1970: 1_776_000_900)
        ),
        secondaryWindow: WorkspaceLimitWindow(
            usedPercent: secondaryUsedPercent,
            limitWindowSeconds: 604_800,
            resetAfterSeconds: 86_400,
            resetAt: Date(timeIntervalSince1970: 1_776_086_400)
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_776_000_000)
    )
}

private func sampleProfile(label: String, sortOrder: Int) -> PlusProfile {
    PlusProfile(
        id: UUID(),
        label: label,
        detectedNote: nil,
        webDataStoreID: UUID(),
        sortOrder: sortOrder,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000 + TimeInterval(sortOrder)),
        lastRefreshAt: nil,
        lastKnownState: .unknown
    )
}

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
