import Foundation

enum OpenChamberSignInCheckOutcome: String, Codable, Equatable, Sendable {
    case verified, needsSignIn, unchecked
}

/// Evidence only; never contains credentials or server response bodies.
struct OpenChamberSignInCheckRecord: Codable, Equatable, Sendable {
    let identityKey: String?
    let outcome: OpenChamberSignInCheckOutcome
    let checkedAt: Date
}

struct OpenChamberSignInCheckUpdate: Sendable {
    let profileID: UUID
    let record: OpenChamberSignInCheckRecord
}

struct OpenChamberSignInCheckProgress: Equatable {
    var completed: Int
    let total: Int
}

extension PlusProfile {
    var currentOpenChamberSignInCheck: OpenChamberSignInCheckRecord? {
        guard provider == .codex, let record = openChamberSignInCheck,
              record.identityKey == openCodeOpenAIAccount?.storageKey else { return nil }
        return record
    }
}
