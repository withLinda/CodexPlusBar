import Foundation

/// Ordered in-process notification of an actual disk commit. Restart reconciliation
/// still reads the trusted catalog; this notification is not a durable work queue.
struct CloudCatalogCommit: Sendable {
    enum Origin: Sendable { case local, remote, restore, migration }
    let before: [PlusProfile]
    let after: [PlusProfile]
    let explicitDeletedIDs: Set<UUID>
    let sequence: UInt64
    let origin: Origin
    let trustedPreimage: Bool
}
