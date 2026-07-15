import Foundation
import Observation

@MainActor
@Observable
final class DotTrickController {
    private(set) var sessions: [DotTrickSession] = []
    var selectedSessionID: UUID?

    private let store: DotTrickSessionStore

    init(store: DotTrickSessionStore = DotTrickSessionStore()) {
        self.store = store
        loadFromDisk()
    }

    var selectedSession: DotTrickSession? {
        guard let selectedSessionID else {
            return nil
        }

        return sessions.first(where: { $0.id == selectedSessionID })
    }

    func addSession(localPart: String) {
        let canonical = DotTrickGenerator.canonicalize(localPart)
        guard canonical.count >= 2 else {
            return
        }

        // Avoid duplicates with the same canonical local part.
        if let existing = sessions.first(where: { $0.localPart == canonical }) {
            selectedSessionID = existing.id
            return
        }

        let session = DotTrickSession(
            localPart: canonical,
            sortOrder: sessions.count
        )

        sessions.append(session)
        selectedSessionID = session.id
        saveToDisk()
    }

    func removeSession(id: UUID) {
        sessions.removeAll(where: { $0.id == id })

        if selectedSessionID == id {
            selectedSessionID = sessions.first?.id
        }

        saveToDisk()
    }

    func toggleUsed(variation: String, inSession sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        if sessions[index].usedVariations.contains(variation) {
            sessions[index].usedVariations.remove(variation)
        } else {
            sessions[index].usedVariations.insert(variation)
        }

        saveToDisk()
    }

    func selectSession(id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else {
            return
        }

        selectedSessionID = id
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        do {
            sessions = try store.loadSessions()
            if selectedSessionID == nil {
                selectedSessionID = sessions.first?.id
            }
        } catch {
            sessions = []
        }
    }

    private func saveToDisk() {
        do {
            try store.saveSessions(sessions)
        } catch {
            // Persistence failure is non-fatal; sessions remain in memory.
        }
    }
}
