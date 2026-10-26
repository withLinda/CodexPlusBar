import Foundation
import Testing
@testable import CodexPlusBar

struct OpenChamberSyncIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCHAMBER_V2_TEST_URL"] != nil))
    func isolatedNativeReconciliationThroughProductionClient() async throws {
        try await IsolatedOpenChamberTestGate.shared.run { try await exerciseNativeSync() }
    }

    private func exerciseNativeSync() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["OPENCHAMBER_V2_TEST_URL"])
        let url = try #require(URL(string: raw))
        #expect(url.host == "127.0.0.1")
        let fixture = try SyncServiceFixture(); defer { fixture.remove() }
        let directory = try #require(ProcessInfo.processInfo.environment["OPENCHAMBER_NATIVE_TEST_DIRECTORY"])
        let authorization = "Basic " + Data("opencode:fixture-password".utf8).base64EncodedString()
        let client = OpenCodeCredentialClient(baseURL: url, authorization: authorization, directory: directory)
        let otherLocation = OpenCodeCredentialClient(baseURL: url, authorization: authorization, directory: directory + "/bridge")
        let original = try await client.inventory()
        for entry in original.oauth { try await client.remove(id: entry.id) }
        let untouched = try await client.inventory().entries
        #expect(!untouched.isEmpty) // Harness seeds an unrelated provider and an OpenAI API key.

        let a = try nativeCredential("nativealpha"), b = try nativeCredential("nativebeta")
        _ = try await client.create(id: a.id, label: a.label, value: a.value, activate: true)
        _ = try await client.create(id: "cred_nativeduplicate", label: a.label, value: a.value, activate: false)
        let old = try nativeCredential("nativesurplus")
        _ = try await client.create(id: old.id, label: old.label, value: old.value, activate: false)
        try fixture.snapshots.saveNative(b, identity: b.openAIIdentity())
        var profileA = try syncProfile(a); profileA.label = "Friendly Alpha"
        var profileB = try syncProfile(b); profileB.sortOrder = 1
        var missing = try syncProfile(nativeCredential("nativemissing")); missing.openCodeOpenAIAccount = nil; missing.sortOrder = 2
        var profiles = [profileA, profileB, missing]
        let service = OpenChamberSyncService(resolveClient: { client }, gate: .init(), snapshots: fixture.snapshots,
                                            stateStore: fixture.state, verifier: SyncTestVerifier())
        func catalog() -> OpenChamberSyncCatalog { .init(generation: 1, profiles: profiles, isTrusted: true) }
        let first = try await service.reconcile(catalog: catalog(), isCurrent: { _ in true })
        #expect(first.matchedCount == 2)
        #expect(first.needsSignInProfileIDs == [missing.id])
        let entries = try await otherLocation.inventory().oauth
        #expect(entries.count == 2)
        #expect(entries.first(where: \.active)?.id == a.id)
        #expect(entries.first(where: { $0.id == a.id })?.label == "Friendly Alpha")
        #expect(entries.first(where: { $0.id != a.id })?.value == b.value)
        _ = try await service.reconcile(catalog: catalog(), isCurrent: { _ in true })
        #expect(try await client.inventory().oauth.sorted { $0.id < $1.id } == entries.sorted { $0.id < $1.id })

        let pending = try nativeCredential("nativepending")
        _ = try await client.create(id: pending.id, label: pending.label, value: pending.value, activate: true)
        let waiting = try await service.reconcile(catalog: catalog(), isCurrent: { _ in true })
        #expect(waiting.pendingCredentialCount == 1)
        var added = try syncProfile(pending); added.openCodeOpenAIAccount = nil
        let runtime = OpenCodeLocalRuntime(authURL: fixture.home.appendingPathComponent("auth.json"), credentials: client)
        let auth = OpenCodeOpenAIAuthService(homeDirectory: fixture.home, resolveRuntime: { runtime }, operationGate: .init())
        added.openCodeOpenAIAccount = try await auth.saveCurrent(for: added)
        profiles.append(added)
        let captured = try await service.reconcile(catalog: catalog(), isCurrent: { _ in true })
        #expect(captured.matchedCount == 3 && captured.pendingCredentialCount == 0)
        #expect(try await client.inventory().oauth.count == 3)

        profiles = []
        _ = try await service.reconcile(catalog: catalog(), isCurrent: { _ in true })
        #expect(try await otherLocation.inventory().oauth.isEmpty)
        let final = try await client.inventory()
        #expect(final.entries.map(\.id).sorted() == untouched.map(\.id).sorted())
        for entry in untouched { #expect(final.entries.first(where: { $0.id == entry.id })?.value == entry.value) }

        // Restore synthetic bridge fixtures before its independently scheduled test.
        for entry in original.oauth {
            _ = try await client.create(id: entry.id, label: entry.label, value: entry.value, activate: false)
        }
        if let active = original.openAI.first(where: \.active) { try await client.activate(id: active.id) }
    }
}

/// The two opt-in suites share one disposable backend, never production discovery.
actor IsolatedOpenChamberTestGate {
    static let shared = IsolatedOpenChamberTestGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func run(_ operation: @Sendable () async throws -> Void) async throws {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        try await operation()
    }
}
