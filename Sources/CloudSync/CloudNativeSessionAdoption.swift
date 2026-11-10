import Foundation

enum CloudSessionInstallationPolicy: Sendable { case savedOnly }

struct CloudSessionAdoptionRequest: Equatable, Sendable {
    let profileID: UUID
    let recordName: String
    let sourceRevision: UInt64
}

/// Supplied by the authenticated inbox owner, never by display summaries.
struct CloudSessionAdoptionAuthorization: Sendable {
    let owner: CloudOwner
    let request: CloudSessionAdoptionRequest
    let validate: @MainActor @Sendable () throws -> Void
    var completed: @MainActor @Sendable (CodexSignInIdentity, CloudSessionKind, Bool) throws -> Void = { _, _, _ in }
    var validateGeneration: @MainActor @Sendable (CloudSessionPayload) throws -> Void = { _ in }
    var sourceConsumed = false

    @MainActor func write<T: Sendable>(_ operation: @MainActor @Sendable () throws -> T) throws -> T {
        try validate()
        return try operation()
    }
    func check() async throws { try await validate() }

    @MainActor func check(_ payload: CloudSessionPayload) throws {
        try validate()
        try validateGeneration(payload)
        if let fingerprint = try payload.generationFingerprint,
           CloudSavedSessionChange.isConsumed(fingerprint, kind: payload.kind) { throw CloudSessionError.unavailable }
    }

    /// A consumed source is only a locator for our own durable replacement.
    /// Never authorize replay of the old pair merely because a receipt exists.
    @MainActor func checkSource(_ source: CloudSessionPayload, resolved: CloudSessionPayload,
                                receipt: CloudSessionAdoptionReceipt?) throws {
        let old = try source.generationFingerprint, next = try resolved.generationFingerprint
        if let receipt, receipt.sourceFingerprint != old { throw CloudSessionAdoptionError.changed }
        if old != next {
            guard let receipt, receipt.sourceFingerprint == old,
                  receipt.adoptedRemote != false,
                  receipt.recoveryStarted == true || receipt.committed else { throw CloudSessionError.unavailable }
        } else if sourceConsumed { throw CloudSessionError.unavailable }
        try check(resolved)
    }

    var receiptKey: String {
        get throws {
            CloudSessionPayload.fingerprint(String(decoding: try CloudJournalCoding.encode(
                [owner.container, owner.environment.rawValue, owner.userRecordName, request.profileID.uuidString,
                 request.recordName, String(request.sourceRevision)]), as: UTF8.self))
        }
    }
}

enum CloudSessionAdoptionError: Error, Equatable { case requiresSwitch, changed }

/// The real native client checks this *after* its own maintenance await, at POST.
enum CloudSessionAdoptionContext {
    @TaskLocal static var authorization: CloudSessionAdoptionAuthorization?
    static func check(_ payload: CloudSessionPayload) async throws { try await authorization?.check(payload) }
}

struct CloudSessionAdoptionReceipt: Codable, Sendable {
    let sourceFingerprint: String
    let previousFingerprint: String?
    let targetFingerprint: String
    let nativeID: String?
    var committed: Bool
    var recoveryStarted: Bool? = nil
    var adoptedRemote: Bool? = nil

    static func fingerprint(_ bytes: Data) -> String {
        CloudJournalCoding.digest(bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct CloudSessionAdoptionReceiptStore: Sendable {
    let directory: URL
    let key: String
    private var url: URL { directory.appendingPathComponent("adoption-" + key + ".json") }
    func load() throws -> CloudSessionAdoptionReceipt? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CloudSessionAdoptionReceipt.self, from: Data(contentsOf: url))
    }
    func save(_ receipt: CloudSessionAdoptionReceipt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try OpenCodePrivateFile.write(JSONEncoder().encode(receipt), to: url)
    }
}

struct CloudNativeSessionAdoption: Sendable {
    let authorization: CloudSessionAdoptionAuthorization
    let desktop: CodexAccountSwitchService
    let openChamber: OpenChamberRepairInstaller

    init(authorization: CloudSessionAdoptionAuthorization, desktop: CodexAccountSwitchService = .init(),
         openChamber: OpenChamberRepairInstaller = .init()) {
        self.authorization = authorization; self.desktop = desktop; self.openChamber = openChamber
    }

    func adoptDesktop(_ payload: CloudSessionPayload, for profile: PlusProfile) async throws -> CodexSignInIdentity {
        try validate(payload, profile)
        guard case .desktop(let signIn, _) = try payload.validated() else { throw CloudSessionError.invalidPayload }
        return try await desktop.installCloudSession(signIn, for: profile, policy: .savedOnly, authorization: authorization)
    }

    func adoptOpenChamber(_ payload: CloudSessionPayload, for profile: PlusProfile) async throws -> OpenCodeOpenAIIdentity {
        try validate(payload, profile)
        guard case .openChamber(let value, _) = try payload.validated() else { throw CloudSessionError.invalidPayload }
        return try await CloudSessionAdoptionContext.$authorization.withValue(authorization) {
            try await openChamber.installCloudSession(value, for: profile, policy: .savedOnly, authorization: authorization)
        }
    }

    private func validate(_ payload: CloudSessionPayload, _ profile: PlusProfile) throws {
        guard profile.provider == .codex, profile.id == authorization.request.profileID else { throw CloudSessionError.identityMismatch }
        try payload.identity.validateBindings(of: profile)
    }
}
