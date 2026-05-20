import Foundation
import WebKit

enum PlusProfileStoredState: String, Codable, Equatable, Sendable {
    case unknown
    case active
    case needsLogin
    case failed
}

enum PlusProfileTag: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case active
    case needAction = "need_action"
    case pending

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .active:
            return "Active"
        case .needAction:
            return "Need action"
        case .pending:
            return "Pending"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .active:
            return "Active"
        case .needAction:
            return "Action"
        case .pending:
            return "Pending"
        }
    }

    var statusTone: CodexStatusTone {
        switch self {
        case .active:
            return .success
        case .needAction:
            return .critical
        case .pending:
            return .info
        }
    }

    var systemImage: String {
        switch self {
        case .active:
            return "checkmark.circle"
        case .needAction:
            return "exclamationmark.triangle"
        case .pending:
            return "clock"
        }
    }
}

struct PlusProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var label: String
    var emailLink: String?
    var detectedNote: String?
    var expiresAt: Date?
    var tags: [PlusProfileTag]
    let webDataStoreID: UUID
    var sortOrder: Int
    let createdAt: Date
    var lastRefreshAt: Date?
    var lastKnownState: PlusProfileStoredState

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case emailLink
        case detectedNote
        case expiresAt
        case tags
        case webDataStoreID
        case sortOrder
        case createdAt
        case lastRefreshAt
        case lastKnownState
    }

    init(
        id: UUID,
        label: String,
        emailLink: String?,
        detectedNote: String?,
        expiresAt: Date? = nil,
        tags: [PlusProfileTag] = [],
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
        self.tags = Self.normalizedTags(tags)
        self.webDataStoreID = webDataStoreID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.lastRefreshAt = lastRefreshAt
        self.lastKnownState = lastKnownState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        emailLink = try container.decodeIfPresent(String.self, forKey: .emailLink)
        detectedNote = try container.decodeIfPresent(String.self, forKey: .detectedNote)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        webDataStoreID = try container.decode(UUID.self, forKey: .webDataStoreID)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastRefreshAt = try container.decodeIfPresent(Date.self, forKey: .lastRefreshAt)
        lastKnownState = try container.decode(PlusProfileStoredState.self, forKey: .lastKnownState)

        let rawTags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        tags = Self.normalizedTags(rawTags.compactMap(PlusProfileTag.init(rawValue:)))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(emailLink, forKey: .emailLink)
        try container.encodeIfPresent(detectedNote, forKey: .detectedNote)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encode(Self.normalizedTags(tags).map(\.rawValue), forKey: .tags)
        try container.encode(webDataStoreID, forKey: .webDataStoreID)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastRefreshAt, forKey: .lastRefreshAt)
        try container.encode(lastKnownState, forKey: .lastKnownState)
    }

    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled profile" : trimmed
    }

    var normalizedEmailLink: String? {
        Self.normalizedEmailLink(emailLink)
    }

    var normalizedTags: [PlusProfileTag] {
        Self.normalizedTags(tags)
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

    static func normalizedTags(_ tags: [PlusProfileTag]) -> [PlusProfileTag] {
        let selectedTags = Set(tags)
        return PlusProfileTag.allCases.filter { selectedTags.contains($0) }
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

    var tags: [PlusProfileTag] {
        profile.normalizedTags
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

struct ProfileTagFilter: Equatable, Sendable {
    private(set) var selectedTags: [PlusProfileTag]

    init(_ selectedTags: [PlusProfileTag] = []) {
        self.selectedTags = PlusProfile.normalizedTags(selectedTags)
    }

    var isEmpty: Bool {
        selectedTags.isEmpty
    }

    func isSelected(_ tag: PlusProfileTag) -> Bool {
        selectedTags.contains(tag)
    }

    func includes(_ snapshot: PlusProfileSnapshot) -> Bool {
        guard isEmpty == false else {
            return true
        }

        return selectedTags.contains { selectedTag in
            snapshot.tags.contains(selectedTag)
        }
    }

    func apply(to snapshots: [PlusProfileSnapshot]) -> [PlusProfileSnapshot] {
        guard isEmpty == false else {
            return snapshots
        }

        return snapshots.filter(includes)
    }

    mutating func toggle(_ tag: PlusProfileTag) {
        if selectedTags.contains(tag) {
            selectedTags.removeAll { $0 == tag }
        } else {
            selectedTags.append(tag)
        }

        selectedTags = PlusProfile.normalizedTags(selectedTags)
    }

    mutating func clear() {
        selectedTags = []
    }
}

struct ProfileTagCounts: Equatable, Sendable {
    let active: Int
    let needAction: Int
    let pending: Int

    init(active: Int = 0, needAction: Int = 0, pending: Int = 0) {
        self.active = active
        self.needAction = needAction
        self.pending = pending
    }

    init(snapshots: [PlusProfileSnapshot]) {
        active = snapshots.count { $0.tags.contains(.active) }
        needAction = snapshots.count { $0.tags.contains(.needAction) }
        pending = snapshots.count { $0.tags.contains(.pending) }
    }

    func count(for tag: PlusProfileTag) -> Int {
        switch tag {
        case .active:
            return active
        case .needAction:
            return needAction
        case .pending:
            return pending
        }
    }

    var statusText: String {
        "\(active) active · \(needAction) need action · \(pending) pending"
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
