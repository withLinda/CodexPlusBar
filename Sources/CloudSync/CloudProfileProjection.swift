import Foundation

enum CloudProfileProjection {
    static func values(from profile: PlusProfile) -> CloudProfileValues {
        CloudProfileValues(
            provider: profile.provider.rawValue,
            label: profile.label,
            emailLink: profile.emailLink,
            password: profile.password,
            twoFactorCode: profile.twoFactorCode,
            phoneNumber: profile.phoneNumber,
            notes: profile.notes,
            tags: profile.tags.map(\.rawValue)
        )
    }
}
