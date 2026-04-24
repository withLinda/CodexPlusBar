import Foundation
import WebKit

enum PlusProfileStoredState: String, Codable, Equatable, Sendable {
    case unknown
    case active
    case needsLogin
    case failed
}

struct PlusProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var label: String
    var emailLink: String?
    var detectedNote: String?
    var expiresAt: Date?
    let webDataStoreID: UUID
    var sortOrder: Int
    let createdAt: Date
    var lastRefreshAt: Date?
    var lastKnownState: PlusProfileStoredState

    init(
        id: UUID,
        label: String,
        emailLink: String?,
        detectedNote: String?,
        expiresAt: Date? = nil,
        webDataStoreID: UUID,
        sortOrder: Int,
        createdAt: Date,
        lastRefreshAt: Date?,
        lastKnownState: PlusProfileStoredState
    ) {
        self.id = id
        self.label = label
        self.emailLink = emailLink
        self.detectedNote = detectedNote
        self.expiresAt = expiresAt
        self.webDataStoreID = webDataStoreID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.lastRefreshAt = lastRefreshAt
        self.lastKnownState = lastKnownState
    }

    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled profile" : trimmed
    }

    var normalizedEmailLink: String? {
        Self.normalizedEmailLink(emailLink)
    }

    var resolvedEmailLinkURL: URL? {
        Self.resolvedEmailLinkURL(from: emailLink)
    }

    static func normalizedEmailLink(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func resolvedEmailLinkURL(from rawValue: String?) -> URL? {
        guard let normalized = normalizedEmailLink(rawValue) else {
            return nil
        }

        if let directURL = validatedEmailLinkURL(from: normalized) {
            return directURL
        }

        guard normalized.contains("://") == false else {
            return nil
        }

        return validatedEmailLinkURL(from: "https://\(normalized)")
    }

    private static func validatedEmailLinkURL(from candidate: String) -> URL? {
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.trimmingCharacters(in: .whitespacesAndNewlines),
              scheme.isEmpty == false else {
            return nil
        }

        let normalizedScheme = scheme.lowercased()
        if normalizedScheme == "http" || normalizedScheme == "https" {
            guard let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
                  host.isEmpty == false else {
                return nil
            }
        }

        return components.url
    }
}

enum PlusProfileState: String, Equatable, Sendable {
    case idle
    case loading
    case ready
    case needsLogin
    case failed

    var title: String {
        switch self {
        case .idle:
            return "Waiting"
        case .loading:
            return "Loading"
        case .ready:
            return "Ready"
        case .needsLogin:
            return "Login needed"
        case .failed:
            return "Issue"
        }
    }

    var tone: CodexStatusTone {
        switch self {
        case .idle:
            return .neutral
        case .loading:
            return .info
        case .ready:
            return .success
        case .needsLogin:
            return .warning
        case .failed:
            return .critical
        }
    }

    var storedState: PlusProfileStoredState {
        switch self {
        case .idle, .loading:
            return .unknown
        case .ready:
            return .active
        case .needsLogin:
            return .needsLogin
        case .failed:
            return .failed
        }
    }
}

extension PlusProfileStoredState {
    var profileState: PlusProfileState {
        switch self {
        case .unknown:
            return .idle
        case .active:
            return .ready
        case .needsLogin:
            return .needsLogin
        case .failed:
            return .failed
        }
    }
}

struct PlusProfileUsage: Equatable, Sendable {
    let accountID: String
    let planType: String
    let primaryWindow: WorkspaceLimitWindow
    let secondaryWindow: WorkspaceLimitWindow?
    let fetchedAt: Date

    var fiveHourRemainingPercent: Int {
        primaryWindow.remainingPercent
    }

    var sevenDayRemainingPercent: Int? {
        secondaryWindow?.remainingPercent
    }

    func usageSummary(referenceDate: Date = .now) -> ProfileUsageSummary {
        ProfileUsageSummary(
            primary: .available(
                shortTitle: "5H",
                remainingPercent: fiveHourRemainingPercent,
                resetText: primaryWindow.resetDescription(referenceDate: referenceDate)
            ),
            secondary: secondaryWindow.map {
                .available(
                    shortTitle: "7D",
                    remainingPercent: $0.remainingPercent,
                    resetText: $0.resetDescription(referenceDate: referenceDate)
                )
            } ?? .unavailable(shortTitle: "7D")
        )
    }
}

struct ProfileUsageMetricSummary: Equatable, Sendable {
    let shortTitle: String
    let remainingPercent: Int?
    let valueText: String
    let resetText: String
    let isAvailable: Bool

    static func available(
        shortTitle: String,
        remainingPercent: Int,
        resetText: String
    ) -> ProfileUsageMetricSummary {
        ProfileUsageMetricSummary(
            shortTitle: shortTitle,
            remainingPercent: remainingPercent,
            valueText: "\(remainingPercent)%",
            resetText: resetText,
            isAvailable: true
        )
    }

    static func unavailable(shortTitle: String) -> ProfileUsageMetricSummary {
        ProfileUsageMetricSummary(
            shortTitle: shortTitle,
            remainingPercent: nil,
            valueText: "—",
            resetText: "Unavailable",
            isAvailable: false
        )
    }

    var accessibilityValue: String {
        if isAvailable {
            return "\(shortTitle) \(valueText), resets in \(resetText)"
        }

        return "\(shortTitle) unavailable"
    }
}

struct ProfileUsageSummary: Equatable, Sendable {
    let primary: ProfileUsageMetricSummary
    let secondary: ProfileUsageMetricSummary

    var metrics: [ProfileUsageMetricSummary] {
        [primary, secondary]
    }

    var accessibilityValue: String {
        metrics.map(\.accessibilityValue).joined(separator: ". ") + "."
    }
}

struct PlusProfileRefreshResult: Equatable, Sendable {
    let usage: PlusProfileUsage
    let detectedNote: String?
    let expiryRefresh: ProfileExpiryRefresh

    init(
        usage: PlusProfileUsage,
        detectedNote: String?,
        expiryRefresh: ProfileExpiryRefresh = .unchanged
    ) {
        self.usage = usage
        self.detectedNote = detectedNote
        self.expiryRefresh = expiryRefresh
    }
}

enum ProfileExpiryRefresh: Equatable, Sendable {
    case unchanged
    case value(Date?)
}

struct PlusProfileSnapshot: Identifiable, Equatable, Sendable {
    let profile: PlusProfile
    let state: PlusProfileState
    let usage: PlusProfileUsage?
    let statusMessage: String?
    let isRefreshing: Bool

    var id: UUID {
        profile.id
    }

    var label: String {
        profile.displayLabel
    }

    var note: String? {
        profile.detectedNote
    }

    var expiresAt: Date? {
        profile.expiresAt
    }

    var lastRefreshAt: Date? {
        profile.lastRefreshAt
    }

    var fiveHourText: String {
        usage.map { "\($0.fiveHourRemainingPercent)%" } ?? "—"
    }

    var sevenDayText: String {
        if let remaining = usage?.sevenDayRemainingPercent {
            return "\(remaining)%"
        }

        return "—"
    }

    func usageSummary(referenceDate: Date = .now) -> ProfileUsageSummary? {
        usage?.usageSummary(referenceDate: referenceDate)
    }

    func updating(
        profile: PlusProfile? = nil,
        state: PlusProfileState? = nil,
        usage: PlusProfileUsage?? = nil,
        statusMessage: String?? = nil,
        isRefreshing: Bool? = nil
    ) -> PlusProfileSnapshot {
        PlusProfileSnapshot(
            profile: profile ?? self.profile,
            state: state ?? self.state,
            usage: usage ?? self.usage,
            statusMessage: statusMessage ?? self.statusMessage,
            isRefreshing: isRefreshing ?? self.isRefreshing
        )
    }
}

enum PlusDashboardStatus: Equatable, Sendable {
    case empty
    case refreshing
    case ready
    case needsLogin
    case mixedAttention
    case failed

    var title: String {
        switch self {
        case .empty:
            return "No profiles"
        case .refreshing:
            return "Refreshing"
        case .ready:
            return "Ready"
        case .needsLogin:
            return "Login needed"
        case .mixedAttention:
            return "Needs attention"
        case .failed:
            return "Issue"
        }
    }

    var tone: CodexStatusTone {
        switch self {
        case .empty:
            return .neutral
        case .refreshing:
            return .info
        case .ready:
            return .success
        case .needsLogin:
            return .warning
        case .mixedAttention:
            return .warning
        case .failed:
            return .critical
        }
    }

    var symbolName: String {
        switch self {
        case .empty:
            return "person.crop.circle.badge.plus"
        case .refreshing:
            return "arrow.triangle.2.circlepath.circle"
        case .ready:
            return "figure.run"
        case .needsLogin:
            return "person.crop.circle.badge.exclamationmark"
        case .mixedAttention:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }
}

@MainActor
final class PlusProfileRuntime {
    let profileID: UUID
    let dataStore: WKWebsiteDataStore
    let sessionStore: WebSessionStore
    let transport: any HTTPTransport
    private let authContextWritable: (any ChatGPTAuthContextWritable)?
    private(set) var authContext: ChatGPTAuthContext?

    init(
        profileID: UUID,
        dataStore: WKWebsiteDataStore,
        transport: (any HTTPTransport)? = nil
    ) {
        self.profileID = profileID
        self.dataStore = dataStore
        self.sessionStore = WebSessionStore(dataStore: dataStore)
        let resolvedTransport = transport ?? CookieBackedTransport(sessionStore: sessionStore)
        self.transport = resolvedTransport
        self.authContextWritable = resolvedTransport as? any ChatGPTAuthContextWritable
    }

    func updateAuthContext(_ context: ChatGPTAuthContext?) {
        authContext = context
        authContextWritable?.updateAuthContext(context)
    }
}
