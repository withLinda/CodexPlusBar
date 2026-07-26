import Foundation
import WebKit

enum PlusProfileStoredState: String, Codable, Equatable, Sendable {
    case unknown
    case active
    case needsLogin
    case failed
}

enum ProfileProvider: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case codex
    case claude

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }

    var systemImage: String {
        switch self {
        case .codex:
            return "terminal.fill"
        case .claude:
            return "sparkles"
        }
    }
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

    var profileTagTone: CodexProfileTagTone {
        switch self {
        case .active:
            return .active
        case .needAction:
            return .needAction
        case .pending:
            return .pending
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
    var provider: ProfileProvider
    var label: String
    var emailLink: String?
    var detectedNote: String?
    var password: String?
    var twoFactorCode: String?
    var phoneNumber: String?
    var notes: String?
    var expiresAt: Date?
    var tags: [PlusProfileTag]
    let webDataStoreID: UUID
    var sortOrder: Int
    let createdAt: Date
    var lastRefreshAt: Date?
    var lastKnownState: PlusProfileStoredState

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case label
        case emailLink
        case detectedNote
        case password
        case twoFactorCode
        case phoneNumber
        case notes
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
        provider: ProfileProvider = .codex,
        label: String,
        emailLink: String?,
        detectedNote: String?,
        password: String? = nil,
        twoFactorCode: String? = nil,
        phoneNumber: String? = nil,
        notes: String? = nil,
        expiresAt: Date? = nil,
        tags: [PlusProfileTag] = [],
        webDataStoreID: UUID,
        sortOrder: Int,
        createdAt: Date,
        lastRefreshAt: Date?,
        lastKnownState: PlusProfileStoredState
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.emailLink = emailLink
        self.detectedNote = detectedNote
        self.password = password
        self.twoFactorCode = twoFactorCode
        self.phoneNumber = phoneNumber
        self.notes = notes
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
        provider = (try? container.decodeIfPresent(ProfileProvider.self, forKey: .provider)) ?? .codex
        label = try container.decode(String.self, forKey: .label)
        emailLink = try container.decodeIfPresent(String.self, forKey: .emailLink)
        detectedNote = try container.decodeIfPresent(String.self, forKey: .detectedNote)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        twoFactorCode = try container.decodeIfPresent(String.self, forKey: .twoFactorCode)
        phoneNumber = try container.decodeIfPresent(String.self, forKey: .phoneNumber)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
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
        try container.encode(provider, forKey: .provider)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(emailLink, forKey: .emailLink)
        try container.encodeIfPresent(detectedNote, forKey: .detectedNote)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encodeIfPresent(twoFactorCode, forKey: .twoFactorCode)
        try container.encodeIfPresent(phoneNumber, forKey: .phoneNumber)
        try container.encodeIfPresent(notes, forKey: .notes)
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

struct BulkProfileImportEntry: Equatable, Sendable {
    let email: String
    let password: String
    let twoFactorCode: String
}

struct BulkProfileImportIssue: Equatable, Sendable {
    let lineNumber: Int
    let message: String
}

struct BulkProfileImportPreview: Equatable, Sendable {
    let entries: [BulkProfileImportEntry]
    let issues: [BulkProfileImportIssue]

    var canSubmit: Bool {
        entries.isEmpty == false && issues.isEmpty
    }

    var countText: String {
        switch entries.count {
        case 0:
            return "No profiles ready"
        case 1:
            return "1 profile ready"
        default:
            return "\(entries.count) profiles ready"
        }
    }

    var issueSummary: String? {
        guard issues.isEmpty == false else {
            return nil
        }

        let lineNumbers = issues.map(\.lineNumber)
        if lineNumbers.count == 1, let lineNumber = lineNumbers.first {
            return "Fix line \(lineNumber)"
        }

        return "Fix lines \(lineNumbers.map(String.init).joined(separator: ", "))"
    }
}

enum BulkProfileImporter {
    static let twoFactorLiveLink = "https://2fa.live"

    static func preview(from rawText: String) -> BulkProfileImportPreview {
        var entries: [BulkProfileImportEntry] = []
        var issues: [BulkProfileImportIssue] = []
        let lines = rawText.components(separatedBy: .newlines)

        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            let contentLine = removingLeadingOrderedListMarker(from: line)
            let trimmedLine = contentLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.isEmpty == false else {
                continue
            }

            let fields = contentLine
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

            guard fields.count == 3 else {
                issues.append(BulkProfileImportIssue(lineNumber: lineNumber, message: "Use email|password|2FA"))
                continue
            }

            guard fields[0].isEmpty == false else {
                issues.append(BulkProfileImportIssue(lineNumber: lineNumber, message: "Email is empty"))
                continue
            }

            guard isPlausibleEmail(fields[0]) else {
                issues.append(BulkProfileImportIssue(lineNumber: lineNumber, message: "Email looks wrong"))
                continue
            }

            guard fields[1].isEmpty == false else {
                issues.append(BulkProfileImportIssue(lineNumber: lineNumber, message: "Password is empty"))
                continue
            }

            guard fields[2].isEmpty == false else {
                issues.append(BulkProfileImportIssue(lineNumber: lineNumber, message: "2FA code is empty"))
                continue
            }

            entries.append(
                BulkProfileImportEntry(
                    email: fields[0],
                    password: fields[1],
                    twoFactorCode: fields[2]
                )
            )
        }

        return BulkProfileImportPreview(entries: entries, issues: issues)
    }

    private static func removingLeadingOrderedListMarker(from line: String) -> String {
        var cursor = line.startIndex

        while cursor < line.endIndex, isHorizontalWhitespace(line[cursor]) {
            cursor = line.index(after: cursor)
        }

        let firstDigit = cursor
        while cursor < line.endIndex, isASCIIDigit(line[cursor]) {
            cursor = line.index(after: cursor)
        }

        guard cursor != firstDigit,
              cursor < line.endIndex,
              line[cursor] == "." else {
            return line
        }

        cursor = line.index(after: cursor)
        guard cursor < line.endIndex, isHorizontalWhitespace(line[cursor]) else {
            return line
        }

        while cursor < line.endIndex, isHorizontalWhitespace(line[cursor]) {
            cursor = line.index(after: cursor)
        }

        return String(line[cursor...])
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func isHorizontalWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains)
    }

    private static func isPlausibleEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let localPart = parts.first,
              let domain = parts.last,
              localPart.isEmpty == false,
              domain.contains("."),
              domain.hasPrefix(".") == false,
              domain.hasSuffix(".") == false else {
            return false
        }

        return value.contains(" ") == false
    }
}

struct PlusProfileDetailsDraft: Equatable, Sendable {
    var label: String
    var emailLink: String
    var password: String
    var twoFactorCode: String
    var phoneNumber: String
    var notes: String

    init(
        label: String = "",
        emailLink: String = "",
        password: String = "",
        twoFactorCode: String = "",
        phoneNumber: String = "",
        notes: String = ""
    ) {
        self.label = label
        self.emailLink = emailLink
        self.password = password
        self.twoFactorCode = twoFactorCode
        self.phoneNumber = phoneNumber
        self.notes = notes
    }

    init(profile: PlusProfile) {
        self.init(
            label: profile.label,
            emailLink: profile.emailLink ?? "",
            password: profile.password ?? "",
            twoFactorCode: profile.twoFactorCode ?? "",
            phoneNumber: profile.phoneNumber ?? "",
            notes: profile.notes ?? ""
        )
    }

    func applying(to profile: PlusProfile) -> PlusProfile {
        var updated = profile
        updated.label = label
        updated.emailLink = PlusProfile.normalizedEmailLink(emailLink)
        updated.password = normalizedPrivateValue(password)
        updated.twoFactorCode = normalizedPrivateValue(twoFactorCode)
        updated.phoneNumber = normalizedTrimmedValue(phoneNumber)
        updated.notes = normalizedTrimmedValue(notes)
        return updated
    }

    private func normalizedPrivateValue(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private func normalizedTrimmedValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    var hasFullFiveHourLimit: Bool {
        usage?.fiveHourRemainingPercent == 100
    }

    var nextResetAt: Date? {
        guard let usage else {
            return nil
        }

        return [usage.primaryWindow.resetAt, usage.secondaryWindow?.resetAt]
            .compactMap { $0 }
            .min()
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

    static func expiryFirstDisplayOrder(_ snapshots: [PlusProfileSnapshot]) -> [PlusProfileSnapshot] {
        ProfileDisplayOrder.accountExpiry.apply(to: snapshots)
    }

    static func displayOrder(
        _ snapshots: [PlusProfileSnapshot],
        by order: ProfileDisplayOrder
    ) -> [PlusProfileSnapshot] {
        order.apply(to: snapshots)
    }
}

enum ProfileDisplayOrder: String, CaseIterable, Identifiable, Sendable {
    case nextReset
    case accountExpiry
    case saved

    static let defaultOrder = ProfileDisplayOrder.nextReset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextReset:
            return "Next reset"
        case .accountExpiry:
            return "Account expiry"
        case .saved:
            return "Saved order"
        }
    }

    var compactTitle: String {
        switch self {
        case .nextReset:
            return "Reset"
        case .accountExpiry:
            return "Expiry"
        case .saved:
            return "Saved"
        }
    }

    var systemImage: String {
        switch self {
        case .nextReset:
            return "clock"
        case .accountExpiry:
            return "calendar"
        case .saved:
            return "line.3.horizontal"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .nextReset:
            return "Next 5-hour or 7-day reset, soonest first"
        case .accountExpiry:
            return "Account expiry, soonest first"
        case .saved:
            return "Saved profile order"
        }
    }

    func apply(to snapshots: [PlusProfileSnapshot]) -> [PlusProfileSnapshot] {
        switch self {
        case .nextReset:
            return snapshots.sorted { lhs, rhs in
                compareOptionalDates(
                    lhs.nextResetAt,
                    rhs.nextResetAt,
                    lhs: lhs,
                    rhs: rhs
                )
            }
        case .accountExpiry:
            return snapshots.sorted { lhs, rhs in
                compareOptionalDates(
                    lhs.expiresAt,
                    rhs.expiresAt,
                    lhs: lhs,
                    rhs: rhs
                )
            }
        case .saved:
            return snapshots.sorted(by: Self.savedOrderSort)
        }
    }

    private func compareOptionalDates(
        _ lhsDate: Date?,
        _ rhsDate: Date?,
        lhs: PlusProfileSnapshot,
        rhs: PlusProfileSnapshot
    ) -> Bool {
        switch (lhsDate, rhsDate) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }

        return Self.savedOrderSort(lhs, rhs)
    }

    private static func savedOrderSort(_ lhs: PlusProfileSnapshot, _ rhs: PlusProfileSnapshot) -> Bool {
        if lhs.profile.sortOrder != rhs.profile.sortOrder {
            return lhs.profile.sortOrder < rhs.profile.sortOrder
        }

        if lhs.profile.createdAt != rhs.profile.createdAt {
            return lhs.profile.createdAt < rhs.profile.createdAt
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct ProfileFilter: Equatable, Sendable {
    private(set) var selectedTags: [PlusProfileTag]
    private(set) var showsOnlyFullFiveHourLimit: Bool
    private(set) var selectedProvider: ProfileProvider?

    init(
        _ selectedTags: [PlusProfileTag] = [],
        showsOnlyFullFiveHourLimit: Bool = false,
        provider: ProfileProvider? = nil
    ) {
        self.selectedTags = PlusProfile.normalizedTags(selectedTags)
        self.showsOnlyFullFiveHourLimit = showsOnlyFullFiveHourLimit
        selectedProvider = provider
    }

    var isEmpty: Bool {
        selectedTags.isEmpty
            && showsOnlyFullFiveHourLimit == false
            && selectedProvider == nil
    }

    func isSelected(_ tag: PlusProfileTag) -> Bool {
        selectedTags.contains(tag)
    }

    func isSelected(_ provider: ProfileProvider) -> Bool {
        selectedProvider == provider
    }

    func includes(_ snapshot: PlusProfileSnapshot) -> Bool {
        let matchesSelectedTags = selectedTags.isEmpty || selectedTags.contains { selectedTag in
            snapshot.tags.contains(selectedTag)
        }
        let matchesFullFiveHourLimit = showsOnlyFullFiveHourLimit == false || snapshot.hasFullFiveHourLimit
        let matchesProvider = selectedProvider == nil || snapshot.profile.provider == selectedProvider

        return matchesSelectedTags && matchesFullFiveHourLimit && matchesProvider
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

    mutating func toggle(_ provider: ProfileProvider) {
        selectedProvider = selectedProvider == provider ? nil : provider
    }

    mutating func toggleFullFiveHourLimit() {
        showsOnlyFullFiveHourLimit.toggle()
    }

    mutating func clear() {
        selectedTags = []
        showsOnlyFullFiveHourLimit = false
        selectedProvider = nil
    }
}

struct ProfileProviderCounts: Equatable, Sendable {
    let codex: Int
    let claude: Int

    init(codex: Int = 0, claude: Int = 0) {
        self.codex = codex
        self.claude = claude
    }

    init(snapshots: [PlusProfileSnapshot]) {
        codex = snapshots.count { $0.profile.provider == .codex }
        claude = snapshots.count { $0.profile.provider == .claude }
    }

    var total: Int {
        codex + claude
    }

    func count(for provider: ProfileProvider) -> Int {
        switch provider {
        case .codex:
            return codex
        case .claude:
            return claude
        }
    }

    var accessibilityText: String {
        let codexText = codex == 1 ? "1 Codex profile" : "\(codex) Codex profiles"
        let claudeText = claude == 1 ? "1 Claude profile" : "\(claude) Claude profiles"
        return "\(codexText), \(claudeText)"
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

    var accessibilityText: String {
        "\(active) active, \(needAction) need action, \(pending) pending"
    }
}

struct ProfileTagSummary: Equatable, Sendable {
    let tags: [PlusProfileTag]
    let primaryTag: PlusProfileTag?
    let overflowCount: Int

    init(tags: [PlusProfileTag]) {
        let normalizedTags = PlusProfile.normalizedTags(tags)
        self.tags = normalizedTags

        let priorityOrder: [PlusProfileTag] = [.needAction, .pending, .active]
        primaryTag = priorityOrder.first { normalizedTags.contains($0) }
        overflowCount = max(normalizedTags.count - 1, 0)
    }

    var accessibilityValue: String {
        guard let primaryTag else {
            return "No tags"
        }

        let orderedTags = [primaryTag] + tags.filter { $0 != primaryTag }
        return orderedTags.map(\.displayName).joined(separator: ", ")
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
    let sessionStore: WebSessionStore
    let transport: any HTTPTransport
    private let authContextWritable: (any ChatGPTAuthContextWritable)?
    private(set) var authContext: ChatGPTAuthContext?
    private(set) var claudeOrganizationID: String?

    init(
        dataStore: WKWebsiteDataStore,
        transport: (any HTTPTransport)? = nil
    ) {
        self.sessionStore = WebSessionStore(dataStore: dataStore)
        let resolvedTransport = transport ?? CookieBackedTransport(sessionStore: sessionStore)
        self.transport = resolvedTransport
        self.authContextWritable = resolvedTransport as? any ChatGPTAuthContextWritable
    }

    func updateAuthContext(_ context: ChatGPTAuthContext?) {
        authContext = context
        authContextWritable?.updateAuthContext(context)
    }

    func updateClaudeOrganizationID(_ organizationID: String?) {
        claudeOrganizationID = organizationID
    }
}
