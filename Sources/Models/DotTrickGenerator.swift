import Foundation

enum DotTrickGenerator {
    /// Returns single-dot Gmail address variations for the given local part.
    ///
    /// The input is normalized first (existing dots stripped, lowercased).
    /// For a canonical username of length `n`, this produces exactly `n − 1`
    /// variations, each with one dot inserted at a different position.
    ///
    /// Example: `"johndoe"` → `["j.ohndoe@gmail.com", "jo.hndoe@gmail.com", …]`
    static func singleDotVariations(for localPart: String) -> [String] {
        let canonical = canonicalize(localPart)
        guard canonical.count >= 2 else {
            return []
        }

        return (1 ..< canonical.count).map { insertionIndex in
            let prefix = canonical.prefix(insertionIndex)
            let suffix = canonical.suffix(canonical.count - insertionIndex)
            return "\(prefix).\(suffix)@gmail.com"
        }
    }

    /// Strips dots and lowercases the local part to produce the canonical form.
    static func canonicalize(_ localPart: String) -> String {
        localPart
            .replacingOccurrences(of: ".", with: "")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
