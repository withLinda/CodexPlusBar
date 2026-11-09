import Foundation

enum CloudEnvironment: String, Codable, Equatable, Sendable {
    case development
    case production
}

struct CloudOwner: Codable, Equatable, Sendable {
    let container: String
    let environment: CloudEnvironment
    let userRecordName: String
}

enum CloudSyncModelError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case profileIdentityMismatch
    case counterOverflow
    /// A source reused the same logical version for different content.
    case conflictingVersion
}

enum CloudSyncSchema {
    static let currentVersion = 1

    static func validateForWriting(_ version: Int) throws {
        guard version == currentVersion else {
            throw CloudSyncModelError.unsupportedSchema(version)
        }
    }
}

struct CloudVersion: Codable, Equatable, Comparable, Sendable {
    let counter: UInt64
    let deviceID: UUID

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.deviceID.uuidString < rhs.deviceID.uuidString
    }

    /// Callers persist the returned counter with their local mutation.
    static func next(after localCounter: UInt64, observing versions: [Self], deviceID: UUID) throws -> Self {
        let greatest = versions.reduce(localCounter) { max($0, $1.counter) }
        let (counter, overflow) = greatest.addingReportingOverflow(1)
        guard !overflow else { throw CloudSyncModelError.counterOverflow }
        return Self(counter: counter, deviceID: deviceID)
    }
}

/// The optional value inside a present field is an explicit clear. A missing field is no edit.
struct CloudField<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let value: Value
    let version: CloudVersion
}

/// Advisory metadata only. There is deliberately no authentication or verification state here.
struct CloudObservation<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let value: Value
    let capturedAt: Date
    let deviceID: UUID
}

struct CloudTombstone: Codable, Equatable, Sendable {
    let version: CloudVersion
    let deletedAt: Date
}

struct CloudOrderDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let ids: [UUID]
    let version: CloudVersion

    init(schemaVersion: Int = CloudSyncSchema.currentVersion, ids: [UUID], version: CloudVersion) {
        self.schemaVersion = schemaVersion
        self.ids = ids
        self.version = version
    }

    func validateForWriting() throws {
        try CloudSyncSchema.validateForWriting(schemaVersion)
    }
}

enum CloudSessionKind: String, Codable, Equatable, Sendable {
    case browser
    case desktop
    case openChamber
}

/// Payload stays opaque here; session-specific validation and adoption are separate boundaries.
struct CloudSessionDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let profileID: UUID
    let sourceDeviceID: UUID
    let sourceName: String
    let kind: CloudSessionKind
    let revision: UInt64
    let capturedAt: Date
    let payload: Data

    init(
        schemaVersion: Int = CloudSyncSchema.currentVersion,
        profileID: UUID,
        sourceDeviceID: UUID,
        sourceName: String,
        kind: CloudSessionKind,
        revision: UInt64,
        capturedAt: Date,
        payload: Data
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.sourceDeviceID = sourceDeviceID
        self.sourceName = sourceName
        self.kind = kind
        self.revision = revision
        self.capturedAt = capturedAt
        self.payload = payload
    }

    func validateForWriting() throws {
        try CloudSyncSchema.validateForWriting(schemaVersion)
    }
}

enum CloudRecordBody: Codable, Equatable, Sendable {
    case profile(CloudProfileDocument)
    case order(CloudOrderDocument)
    case session(CloudSessionDocument)

    /// Encoding also serves local retention, so publication must explicitly pass this gate.
    func validateForWriting() throws {
        switch self {
        case .profile(let document): try document.validateForWriting()
        case .order(let document): try document.validateForWriting()
        case .session(let document): try document.validateForWriting()
        }
    }
}
