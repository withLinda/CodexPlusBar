import Foundation

struct OpenChamberSyncState: Codable, Equatable, Sendable {
    var hasBaseline = false
    var seenCredentialIDs: Set<String> = []
    var pendingSince: [String: Date] = [:]

    static func baseline(_ accounts: [OpenChamberSyncAccount]) -> Self {
        Self(hasBaseline: true, seenCredentialIDs: Set(accounts.map(\.id)), pendingSince: [:])
    }

    func observing(accounts: [OpenChamberSyncAccount], now: Date) -> Self {
        guard hasBaseline else { return .baseline(accounts) }
        var result = self
        let ids = Set(accounts.map(\.id))
        for id in ids.subtracting(seenCredentialIDs) { result.pendingSince[id] = now }
        result.seenCredentialIDs.formUnion(ids)
        result.pendingSince = result.pendingSince.filter { ids.contains($0.key) }
        return result
    }
}

struct OpenChamberSyncStateStore: Sendable {
    let fileURL: URL
    init(fileURL: URL = JSONFileStorage.applicationSupportFileURL(named: "OpenChamberSyncState.json")) { self.fileURL = fileURL }
    func load() throws -> OpenChamberSyncState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .init() }
        guard let data = try? Data(contentsOf: fileURL), let result = try? JSONDecoder().decode(OpenChamberSyncState.self, from: data),
              result.pendingSince.keys.allSatisfy({ result.seenCredentialIDs.contains($0) }) else {
            throw OpenChamberSyncError.stateUnavailable
        }
        return result
    }
    func save(_ state: OpenChamberSyncState) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try OpenCodePrivateFile.write(JSONEncoder().encode(state), to: fileURL)
        } catch { throw OpenChamberSyncError.stateUnavailable }
    }
}
