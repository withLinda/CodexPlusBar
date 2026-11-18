import Foundation

struct ProfileListItem: Identifiable, Equatable, Sendable {
    let snapshot: PlusProfileSnapshot
    let ordinal: Int

    var id: UUID {
        snapshot.id
    }
}

enum ProfileListNavigationDirection: Sendable {
    case up
    case down
}

extension ProfileListPresentation {
    var numberedProfiles: some RandomAccessCollection<ProfileListItem> {
        displayedProfiles.indices.lazy.map { [displayedProfiles] index in
            ProfileListItem(snapshot: displayedProfiles[index], ordinal: index + 1)
        }
    }

    func navigationTarget(
        from currentID: UUID?,
        direction: ProfileListNavigationDirection
    ) -> UUID? {
        guard let currentID,
              let currentIndex = displayedProfiles.firstIndex(where: { $0.id == currentID }) else {
            return displayedProfiles.first?.id
        }

        let offset: Int = switch direction {
        case .up:
            -1
        case .down:
            1
        }
        let targetIndex = min(max(currentIndex + offset, 0), displayedProfiles.count - 1)
        return displayedProfiles[targetIndex].id
    }
}
