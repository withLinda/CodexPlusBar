import Foundation
import Testing
@testable import CodexPlusBar

@MainActor
struct SelectorExportPublisherTests {
    @Test
    func constructionAndUpdatesDoNotPublishBeforeLifecycleStarts() {
        let harness = PublisherHarness()
        harness.publisher.update(profiles: [harness.profile], observations: [:], trusted: true)
        #expect(harness.writes.isEmpty)
    }

    @Test
    func lifecycleSchedulesThirtySecondHeartbeatAndDoesNotRetainPublisher() async throws {
        let harness = PublisherHarness()
        let sleeper = PublisherSleepGate()
        var publisher: SelectorExportPublisher? = SelectorExportPublisher(binding: { _ in "credential-a" },
            write: { harness.writes.append($0) }, sleep: { await sleeper.sleep($0) })
        weak let weakPublisher = publisher
        publisher?.update(profiles: [harness.profile], observations: [:], trusted: true)
        publisher?.start()
        while harness.writes.isEmpty || sleeper.intervals.isEmpty { await Task.yield() }
        let count = harness.writes.count
        #expect(sleeper.intervals == [30])
        sleeper.release()
        while harness.writes.count == count { await Task.yield() }
        publisher?.stop()
        publisher = nil
        #expect(weakPublisher == nil)
        sleeper.release()
    }

    @Test
    func heartbeatDoesNotRefreshEvidenceAndRestartStartsUnknown() async throws {
        let harness = PublisherHarness()
        harness.publisher.update(profiles: [harness.profile], observations: [:], trusted: true)
        let ticket = try #require(await harness.publisher.beginRefresh(profileID: harness.profile.id))
        await harness.publisher.completeRefresh(ticket: ticket, observation: harness.observation)
        await harness.publisher.publishNow()
        let first = try #require(harness.writes.last)
        harness.now += 30
        await harness.publisher.publishNow()
        let second = try #require(harness.writes.last)
        #expect(second.sequence == first.sequence + 1)
        #expect(second.generatedAtMs == first.generatedAtMs + 30_000)
        #expect(second.accounts[0].usage?.observedAtMs == first.accounts[0].usage?.observedAtMs)
        #expect(second.accounts[0].entitlement?.observedAtMs == first.accounts[0].entitlement?.observedAtMs)
        let restarted = harness.makePublisher()
        restarted.update(profiles: [harness.profile], observations: [:], trusted: true)
        await restarted.publishNow()
        #expect(harness.writes.last?.sourceInstanceID != second.sourceInstanceID)
        #expect(harness.writes.last?.accounts.first?.usage == nil)
    }

    @Test
    func rebindDuringRefreshDiscardsCompletionAndPriorEvidence() async throws {
        let harness = PublisherHarness()
        harness.publisher.update(profiles: [harness.profile], observations: [:], trusted: true)
        let ticket = try #require(await harness.publisher.beginRefresh(profileID: harness.profile.id))
        harness.binding = "replacement-id"
        await harness.publisher.completeRefresh(ticket: ticket, observation: harness.observation)
        await harness.publisher.publishNow()
        #expect(harness.writes.last?.accounts.first?.usage == nil)
        #expect(harness.writes.last?.accounts.first?.credentialID == "replacement-id")
    }

    @Test
    func newerRefreshAdmissionRejectsAnOlderCompletion() async throws {
        let harness = PublisherHarness()
        harness.publisher.update(profiles: [harness.profile], observations: [:], trusted: true)
        let old = try #require(await harness.publisher.beginRefresh(profileID: harness.profile.id))
        let current = try #require(await harness.publisher.beginRefresh(profileID: harness.profile.id))
        await harness.publisher.completeRefresh(ticket: current, observation: nil)
        await harness.publisher.completeRefresh(ticket: old, observation: harness.observation)
        await harness.publisher.publishNow()
        #expect(harness.writes.last?.accounts.first?.usage == nil)
    }

    @Test
    func stoppedPublisherCannotCompleteAnOutstandingBindingRead() async throws {
        let harness = PublisherHarness()
        let gate = PublisherBindingGate()
        let publisher = SelectorExportPublisher(binding: { _ in await gate.read() }, write: { harness.writes.append($0) })
        publisher.update(profiles: [harness.profile], observations: [:], trusted: true)
        let pending = Task { await publisher.publishNow() }
        while !gate.waiting { await Task.yield() }
        publisher.stop()
        let count = harness.writes.count
        gate.release()
        await pending.value
        #expect(harness.writes.count == count)
    }

    @Test
    func removalAndSignOutInvalidateImmediatelyAndRejectLateCompletion() async throws {
        let harness = PublisherHarness()
        harness.publisher.update(profiles: [harness.profile], observations: [:], trusted: true)
        let ticket = try #require(await harness.publisher.beginRefresh(profileID: harness.profile.id))
        await harness.publisher.completeRefresh(ticket: ticket, observation: harness.observation)
        await harness.publisher.publishNow()
        #expect(harness.writes.last?.accounts.first?.usage != nil)
        harness.publisher.invalidate(profileID: harness.profile.id)
        #expect(harness.writes.last?.accounts.first?.usage == nil)
        await harness.publisher.completeRefresh(ticket: ticket, observation: harness.observation)
        await harness.publisher.publishNow()
        #expect(harness.writes.last?.accounts.first?.usage == nil)
        harness.publisher.update(profiles: [], observations: [:], trusted: true)
        #expect(harness.writes.last?.accounts.isEmpty == true)
    }

    @Test
    func catalogTrustAndBusyBindingNeverManufactureFreshEvidence() async throws {
        let harness = PublisherHarness()
        harness.publisher.update(profiles: [harness.profile], observations: [:], trusted: true)
        await harness.publisher.publishNow()
        let old = try #require(harness.writes.last?.accounts.first?.bindingObservedAtMs)
        harness.busy = true
        harness.now += 30
        await harness.publisher.publishNow()
        #expect(harness.writes.last?.accounts.first?.bindingObservedAtMs == old)
        harness.publisher.update(profiles: [harness.profile], observations: [:], trusted: false)
        #expect(harness.writes.last?.catalogTrusted == false)
    }

    @Test
    func failedExpiryRefreshRetainsTimestampButExplicitUnknownReplacesIt() async throws {
        let harness = PublisherHarness()
        harness.publisher.update(profiles: [harness.profile], observations: [:], trusted: true)
        let first = try #require(await harness.publisher.beginRefresh(profileID: harness.profile.id))
        await harness.publisher.completeRefresh(ticket: first, observation: harness.observation)
        let next = try #require(await harness.publisher.beginRefresh(profileID: harness.profile.id))
        let old = harness.observation
        let failed = SelectorObservation(identityKey: old.identityKey, accountID: old.accountID, usage: old.usage,
            entitlement: nil, unavailableReasons: ["expiry-refresh-failed"])
        await harness.publisher.completeRefresh(ticket: next, observation: failed)
        await harness.publisher.publishNow()
        #expect(harness.writes.last?.accounts.first?.entitlement?.observedAtMs == 1_800_000_000_000)
        let unknown = SelectorObservation(identityKey: old.identityKey, accountID: old.accountID, usage: old.usage,
            entitlement: nil, unavailableReasons: ["expiry-unknown"])
        await harness.publisher.completeRefresh(ticket: next, observation: unknown)
        await harness.publisher.publishNow()
        #expect(harness.writes.last?.accounts.first?.entitlement == nil)
    }
}

@MainActor
private final class PublisherBindingGate {
    private var continuation: CheckedContinuation<String?, Never>?
    var waiting: Bool { continuation != nil }
    func read() async -> String? { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: "credential-a"); continuation = nil }
}

@MainActor
private final class PublisherSleepGate {
    var intervals: [TimeInterval] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func sleep(_ interval: TimeInterval) async {
        intervals.append(interval)
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class PublisherHarness {
    var now: TimeInterval = 1_800_000_000
    var binding = "credential-a"
    var busy = false
    var writes: [SelectorExport] = []
    lazy var publisher = makePublisher()
    let identity = OpenCodeOpenAIIdentity(accountID: "account-a", userID: "user-a", email: "private@example.test")
    lazy var profile: PlusProfileSnapshot = {
        let profile = PlusProfile(id: UUID(), label: "Alpha", openCodeOpenAIAccount: identity,
            emailLink: nil, detectedNote: nil, webDataStoreID: UUID(), sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: now), lastRefreshAt: nil, lastKnownState: .active)
        return PlusProfileSnapshot(profile: profile, state: .ready, usage: nil, statusMessage: nil, isRefreshing: false)
    }()
    var observation: SelectorObservation {
        SelectorObservation(identityKey: identity.storageKey, accountID: identity.accountID,
            usage: SelectorUsageObservation(observedAt: Date(timeIntervalSince1970: 1_800_000_000), identityKey: identity.storageKey,
                allowed: true, limitReached: false, fiveHour: .init(remainingPercent: 25, resetAt: Date(timeIntervalSince1970: 1_800_003_600)), sevenDay: .notApplicable),
            entitlement: SelectorEntitlementObservation(observedAt: Date(timeIntervalSince1970: 1_800_000_000), accountID: identity.accountID,
                expiresAt: Date(timeIntervalSince1970: 1_800_086_400), active: true, deactivated: false, usable: true, match: .canonical), unavailableReasons: [])
    }
    func makePublisher() -> SelectorExportPublisher {
        SelectorExportPublisher(binding: { [unowned self] _ in
            if self.busy { throw OpenCodeOpenAIAuthError.busy }
            return self.binding
        }, write: { [unowned self] in self.writes.append($0) }, now: { [unowned self] in Date(timeIntervalSince1970: self.now) })
    }
}
