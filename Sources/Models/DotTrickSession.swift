import Foundation

struct DotTrickSession: Identifiable, Equatable, Sendable {
    let id: UUID
    var localPart: String
    var createdAt: Date
    var sortOrder: Int
    var usedVariations: Set<String>

    init(
        id: UUID = UUID(),
        localPart: String,
        createdAt: Date = .now,
        sortOrder: Int = 0,
        usedVariations: Set<String> = []
    ) {
        self.id = id
        self.localPart = DotTrickGenerator.canonicalize(localPart)
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.usedVariations = usedVariations
    }

    var canonicalEmail: String {
        "\(localPart)@gmail.com"
    }

    var variations: [String] {
        DotTrickGenerator.singleDotVariations(for: localPart)
    }

    var variationCount: Int {
        let length = localPart.count
        return length >= 2 ? length - 1 : 0
    }

    var usedCount: Int {
        // Only count variations that actually exist in the current set.
        let current = Set(variations)
        return usedVariations.intersection(current).count
    }

    func isUsed(_ variation: String) -> Bool {
        usedVariations.contains(variation)
    }
}

// MARK: - Codable (backward-compatible)

extension DotTrickSession: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case localPart
        case createdAt
        case sortOrder
        case usedVariations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        localPart = try container.decode(String.self, forKey: .localPart)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        // Existing JSON files lack this key — fall back to empty set.
        usedVariations = try container.decodeIfPresent(Set<String>.self, forKey: .usedVariations) ?? []
    }
}
