import Darwin
import Foundation
import Testing
@testable import CodexPlusBar

struct CloudSyncPreferencesTests {
    private static let first = CloudOwner(container: "iCloud.com.linda.CodexPlusBar", environment: .development, userRecordName: "synthetic-A")
    private static let second = CloudOwner(container: "iCloud.com.linda.CodexPlusBar", environment: .development, userRecordName: "synthetic-B")

    @Test func legacyUnboundEnablementNeverAuthorizesAnOwner() throws {
        let bytes = Data(#"{"enabled":true,"paused":false,"includeSavedSessions":false}"#.utf8)
        let preferences = try JSONDecoder().decode(CloudSyncPreferences.self, from: bytes)
        #expect(!preferences.canResume(for: Self.first))
        #expect(!preferences.canResume(for: Self.second))
        #expect(!preferences.includeSavedSessions)
    }

    @Test func constructionAndOffStartupReadDoNotCreateFiles() throws {
        let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSyncPreferencesStore(root: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try store.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func ownerSwitchAndRestartRequireFreshConsentEvenForPreviouslyEnabledOwner() throws {
        let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSyncPreferencesStore(root: root)
        let initial = try store.update { $0.setConsent(enabled: true, for: Self.second) }
        _ = try store.update { $0.setConsent(enabled: true, for: Self.first) }
        let restarted = try #require(try store.read())
        #expect(restarted.deviceID == initial.deviceID)
        #expect(restarted.preferences.canResume(for: Self.first))
        #expect(!restarted.preferences.canResume(for: Self.second))
        _ = try store.update { $0.observeOwner(Self.second) }
        let switched = try #require(try CloudSyncPreferencesStore(root: root).read())
        #expect(!switched.preferences.enabled)
        #expect(!switched.preferences.canResume(for: Self.first))
        #expect(!switched.preferences.canResume(for: Self.second))
        let approved = try store.update { $0.setConsent(enabled: true, for: Self.second) }
        #expect(approved.preferences.canResume(for: Self.second))
        #expect(!approved.preferences.canResume(for: Self.first))
        #expect(approved.preferences.previousActiveOwner == Self.second)
    }

    @Test func environmentAndContainerCannotReuseConsent() {
        var preferences = CloudSyncPreferences()
        preferences.setConsent(enabled: true, for: Self.first)
        #expect(!preferences.canResume(for: .init(container: Self.first.container, environment: .production, userRecordName: Self.first.userRecordName)))
        #expect(!preferences.canResume(for: .init(container: "another-container", environment: .development, userRecordName: Self.first.userRecordName)))
    }

    @Test func sessionPreferenceBelongsToOwnerAndDisableSurvivesRestart() throws {
        let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSyncPreferencesStore(root: root)
        _ = try store.update {
            $0.setConsent(enabled: true, for: Self.first)
            $0.setIncludesSessions(false, for: Self.first)
            $0.setConsent(enabled: true, for: Self.second)
        }
        let device = try #require(try store.read())
        #expect(!device.preferences.includesSessions(for: Self.first))
        #expect(device.preferences.includesSessions(for: Self.second))
        _ = try store.update { $0.setConsent(enabled: false, for: Self.second) }
        let restarted = try #require(try store.read())
        #expect(!restarted.preferences.canResume(for: Self.second))
    }

    @Test func journalAndPreferenceStoreShareOneDeviceIdentityWithoutOwnerPartitionCreation() async throws {
        let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSyncPreferencesStore(root: root)
        let device = try store.update { $0.setConsent(enabled: true, for: Self.first) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("owners").path))
        let journal = CloudSyncJournal(root: root, owner: Self.first)
        #expect(try await journal.deviceState() == device)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("owners").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("device.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func corruptPreferencesAreNotReplacedByDefaults() throws {
        let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSyncPreferencesStore(root: root)
        _ = try store.update { $0.setConsent(enabled: true, for: Self.first) }
        let file = root.appendingPathComponent("device.json")
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: file)
        #expect(throws: (any Error).self) { try store.read() }
        #expect(throws: (any Error).self) { try store.update { $0.enabled = true } }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func restartAfterRestoreCommitAttemptStaysPausedAndCannotBeCancelledBackToEnabled() throws {
        let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSyncPreferencesStore(root: root)
        _ = try store.update {
            $0.setConsent(enabled: true, for: Self.first)
            try $0.beginTransfer(restoring: true)
        }
        let beforeCommit = try #require(try store.read())
        #expect(beforeCommit.preferences.paused)
        #expect(!beforeCommit.preferences.canResume(for: Self.first))
        _ = try store.update { try $0.markRestoreCommitAttempt() }
        // A crash/throw after the swap is ambiguous. A false `restored` value must
        // not be enough to restore consent after that durable boundary.
        let restarted = CloudSyncPreferencesStore(root: root)
        let after = try restarted.update { $0.finishTransfer(restored: false) }
        #expect(after.preferences.paused)
        #expect(!after.preferences.canResume(for: Self.first))
        #expect(after.preferences.transferPause?.phase == .commitAttempted)
        let attemptedEnable = try restarted.update { $0.setConsent(enabled: true, for: Self.first) }
        #expect(!attemptedEnable.preferences.canResume(for: Self.first))
    }

    @Test(arguments: [false, true])
    func transferCancellationBeforeCommitRestoresPriorEnablement(restoring: Bool) throws {
        let root = rootURL(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSyncPreferencesStore(root: root)
        _ = try store.update {
            $0.setConsent(enabled: true, for: Self.first)
            try $0.beginTransfer(restoring: restoring)
        }
        let resumed = try store.update { $0.finishTransfer(restored: false) }
        #expect(resumed.preferences.canResume(for: Self.first))
        #expect(resumed.preferences.transferPause == nil)
        _ = try store.update {
            $0.setConsent(enabled: false, for: Self.first)
            try $0.beginTransfer(restoring: restoring)
        }
        let off = try store.update { $0.finishTransfer(restored: false) }
        #expect(!off.preferences.enabled)
        #expect(!off.preferences.paused)
    }

    private func rootURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cloud-preferences-\(UUID())")
    }
}
