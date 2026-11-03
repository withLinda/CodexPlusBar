import Foundation

struct ProfileListItem: Identifiable, Equatable, Sendable {
    let snapshot: PlusProfileSnapshot
    let ordinal: Int

    var id: UUID {
        snapshot.id
    }
}

extension ProfileListPresentation {
    var numberedProfiles: [ProfileListItem] {
        displayedProfiles.enumerated().map { offset, snapshot in
            ProfileListItem(snapshot: snapshot, ordinal: offset + 1)
        }
    }
}

enum ProfileListNavigationDirection: Sendable {
    case up
    case down
}

enum ProfileListNavigation {
    static func targetID(
        currentID: UUID?,
        items: [ProfileListItem],
        direction: ProfileListNavigationDirection
    ) -> UUID? {
        guard items.isEmpty == false else {
            return nil
        }

        guard let currentID,
              let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
            return items.first?.id
        }

        let offset: Int = switch direction {
        case .up:
            -1
        case .down:
            1
        }
        let targetIndex = min(max(currentIndex + offset, 0), items.count - 1)
        return items[targetIndex].id
    }
}
