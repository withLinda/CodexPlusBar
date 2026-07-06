# Profile Details and Email Privacy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add locally saved password, 2FA text, phone number, and notes fields, then mask email labels in every summary surface.

**Architecture:** Extend `PlusProfile` with optional backward-compatible fields and use one `PlusProfileDetailsDraft` value for atomic form edits. Keep email masking in one pure formatter used by sidebar rows, menu panel rows, and the macOS status item. Build the Profile Manager as one quiet form with one Save action and field-specific Copy or Show actions.

**Tech Stack:** Swift 6, SwiftUI, Observation, Codable JSON persistence, Swift Testing, AppKit pasteboard, Xcode/macOS 14+

---

## File Map

- Modify `Sources/Models/PlusProfileModels.swift`: persisted fields, normalization, and the atomic edit draft.
- Modify `Sources/Controllers/PlusProfileController.swift`: one whole-form update and masked status-item label.
- Modify `Sources/Views/DisplayFormatter.swift`: shared email-label masking.
- Modify `Sources/Views/ProfileSummaryRow.swift`: masked sidebar and menu-panel title.
- Modify `Sources/Views/AccountWindowView.swift`: the six-field form, private-field controls, copy state, and one Save action.
- Modify `Tests/PlusProfileModelsTests.swift`: Codable compatibility and value normalization.
- Modify `Tests/ProfileCatalogStoreTests.swift`: local JSON round trip.
- Modify `Tests/PlusProfileControllerTests.swift`: atomic save and status-item masking.
- Modify `Tests/DisplayFormatterTests.swift`: all email masking rules.
- Modify `Tests/ProfileSummaryRowTests.swift`: sidebar and menu-panel masking.
- Modify `Tests/ProfileManagerWindowViewTests.swift`: form, copy, reveal, and save presentation contracts.
- Modify `Learnings.md` only if implementation or visual verification reveals a non-obvious trap.

### Task 1: Persist Optional Profile Details

**Files:**
- Modify: `Tests/PlusProfileModelsTests.swift`
- Modify: `Tests/ProfileCatalogStoreTests.swift`
- Modify: `Sources/Models/PlusProfileModels.swift`

- [ ] **Step 1: Write failing model and catalog tests**

Add tests that decode old JSON without new keys, preserve exact password and 2FA
text, normalize whitespace-only values to `nil`, and round-trip all new values:

```swift
@Test
func profileDecoderDefaultsMissingOptionalDetailsToNil() throws {
    let json = """
    {
      "id" : "4D3DD8D1-7408-4B71-A72D-4ED8CB2616EB",
      "label" : "legacy@example.com",
      "emailLink" : null,
      "detectedNote" : null,
      "webDataStoreID" : "CC19D410-7A2C-4D41-967A-97FCA178D0F2",
      "sortOrder" : 0,
      "createdAt" : 777600000,
      "lastRefreshAt" : null,
      "lastKnownState" : "unknown"
    }
    """
    let profile = try JSONDecoder().decode(
        PlusProfile.self,
        from: try #require(json.data(using: .utf8))
    )

    #expect(profile.password == nil)
    #expect(profile.twoFactorCode == nil)
    #expect(profile.phoneNumber == nil)
    #expect(profile.notes == nil)
}

@Test
func detailsDraftPreservesPrivateTextAndNormalizesEmptyOptionalValues() {
    let updated = PlusProfileDetailsDraft(
        label: "owner@example.com",
        emailLink: "  mail.example.com  ",
        password: " pass with spaces ",
        twoFactorCode: " JBSW Y3DP ",
        phoneNumber: "  +62 812 3456  ",
        notes: "  Temporary account  "
    ).applying(to: sampleProfile(emailLink: nil))

    #expect(updated.emailLink == "mail.example.com")
    #expect(updated.password == " pass with spaces ")
    #expect(updated.twoFactorCode == " JBSW Y3DP ")
    #expect(updated.phoneNumber == "+62 812 3456")
    #expect(updated.notes == "Temporary account")
}

@Test
func saveAndLoadProfilesPreservesOptionalDetails() throws {
    let tempDirectory = makeTemporaryDirectory()
    let store = ProfileCatalogStore(
        fileURL: tempDirectory.appendingPathComponent("profiles.json")
    )
    var profile = sampleProfile(label: "owner@example.com", sortOrder: 0)
    profile.password = "temporary-password"
    profile.twoFactorCode = "JBSWY3DPEHPK3PXP"
    profile.phoneNumber = "+62 812 3456"
    profile.notes = "Expires after handoff"

    try store.saveProfiles([profile])
    let loaded = try #require(store.loadProfiles().first)

    #expect(loaded.password == profile.password)
    #expect(loaded.twoFactorCode == profile.twoFactorCode)
    #expect(loaded.phoneNumber == profile.phoneNumber)
    #expect(loaded.notes == profile.notes)
}
```

- [ ] **Step 2: Run the complete test suite and verify RED**

Run:

```bash
make test
```

Expected: build failure because `PlusProfileDetailsDraft` and the four new
`PlusProfile` properties do not exist.

- [ ] **Step 3: Add the optional Codable fields and edit draft**

Extend `PlusProfile` with optional properties and defaulted initializer arguments
so existing call sites continue compiling:

```swift
var password: String?
var twoFactorCode: String?
var phoneNumber: String?
var notes: String?

init(
    id: UUID,
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
)
```

Add each key to `CodingKeys`, decode with `decodeIfPresent`, and encode with
`encodeIfPresent`.

Add the atomic draft:

```swift
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
```

- [ ] **Step 4: Run tests and verify GREEN**

Run `make test`.

Expected: all Swift Testing tests pass, including the three new storage tests.

- [ ] **Step 5: Commit the storage slice**

```bash
git add Sources/Models/PlusProfileModels.swift Tests/PlusProfileModelsTests.swift Tests/ProfileCatalogStoreTests.swift
git commit -m "feat(profile): persist optional account details"
```

### Task 2: Save the Whole Form Atomically

**Files:**
- Modify: `Tests/PlusProfileControllerTests.swift`
- Modify: `Sources/Controllers/PlusProfileController.swift`

- [ ] **Step 1: Write the failing controller test**

```swift
@Test
func updateDetailsPersistsAllFieldsWithoutChangingRuntimeStateOrOrder() throws {
    let tempDirectory = makeTemporaryDirectory()
    let store = ProfileCatalogStore(
        fileURL: tempDirectory.appendingPathComponent("profiles.json")
    )
    let first = sampleProfile(label: "old@example.com", sortOrder: 0)
    let second = sampleProfile(label: "second@example.com", sortOrder: 1)
    try store.saveProfiles([first, second])
    let controller = PlusProfileController(
        catalogStore: store,
        dataService: StubPlusProfileDataService(refreshResults: [:]),
        autoStart: false
    )
    let originalState = try #require(controller.profiles.first?.state)

    controller.updateDetails(
        for: first.id,
        draft: PlusProfileDetailsDraft(
            label: "new@example.com",
            emailLink: "mail.example.com",
            password: "secret",
            twoFactorCode: "JBSWY3DP",
            phoneNumber: "+62 812",
            notes: "Temporary"
        )
    )

    let row = try #require(controller.profiles.first)
    let persisted = try store.loadProfiles()
    #expect(persisted.map(\.id) == [first.id, second.id])
    #expect(row.state == originalState)
    #expect(row.profile.password == "secret")
    #expect(persisted.first?.twoFactorCode == "JBSWY3DP")
    #expect(persisted.first?.phoneNumber == "+62 812")
    #expect(persisted.first?.notes == "Temporary")
}

@Test
func updateDetailsKeepsSavedProfileAndReportsFailureWhenDiskWriteFails() throws {
    let tempDirectory = makeTemporaryDirectory()
    let fileURL = tempDirectory.appendingPathComponent("profiles.json")
    let store = ProfileCatalogStore(fileURL: fileURL)
    let profile = sampleProfile(label: "old@example.com", sortOrder: 0)
    try store.saveProfiles([profile])
    let controller = PlusProfileController(
        catalogStore: store,
        dataService: StubPlusProfileDataService(refreshResults: [:]),
        autoStart: false
    )
    try FileManager.default.removeItem(at: tempDirectory)
    try Data().write(to: tempDirectory)

    var draft = PlusProfileDetailsDraft(profile: profile)
    draft.label = "new@example.com"
    let didSave = controller.updateDetails(for: profile.id, draft: draft)

    #expect(didSave == false)
    #expect(controller.profiles.first?.profile.label == "old@example.com")
    #expect(controller.statusMessage == "The profile list could not be saved locally.")
}
```

- [ ] **Step 2: Run `make test` and verify RED**

Expected: compile failure because `updateDetails(for:draft:)` does not exist.

- [ ] **Step 3: Implement one atomic controller update**

```swift
@discardableResult
func updateDetails(for profileID: UUID, draft: PlusProfileDetailsDraft) -> Bool {
    guard let index = indexOfProfile(profileID) else { return false }
    let previousProfiles = profiles
    let snapshot = profiles[index]
    let updatedProfile = draft.applying(to: snapshot.profile)
    profiles[index] = snapshot.updating(profile: updatedProfile)
    guard persistProfiles() else {
        profiles = previousProfiles
        return false
    }
    return true
}
```

Change `persistProfiles()` to return `true` after `catalogStore.saveProfiles`
succeeds and `false` after it sets the existing save-error status. Its existing
callers may ignore the result. Remove `updateLabel` and `updateEmailLink` only
after all UI callers move to the new API in Task 5. Until then, leave them in
place to keep this slice compiling.

- [ ] **Step 4: Run `make test` and verify GREEN**

Expected: all tests pass and the new atomic update test passes.

- [ ] **Step 5: Commit the controller slice**

```bash
git add Sources/Controllers/PlusProfileController.swift Tests/PlusProfileControllerTests.swift
git commit -m "feat(profile): save account details atomically"
```

### Task 3: Mask Email Labels Everywhere They Are Summarized

**Files:**
- Modify: `Tests/DisplayFormatterTests.swift`
- Modify: `Tests/ProfileSummaryRowTests.swift`
- Modify: `Tests/PlusProfileControllerTests.swift`
- Modify: `Sources/Views/DisplayFormatter.swift`
- Modify: `Sources/Views/ProfileSummaryRow.swift`
- Modify: `Sources/Controllers/PlusProfileController.swift`

- [ ] **Step 1: Write failing formatter and presentation tests**

```swift
@Test(arguments: [
    ("putrigildarahimah13@gmail.com", "putrig**ah13@gmail.com"),
    ("abcdefghij@outlook.com", "abc**ij@outlook.com"),
    ("abcdef@icloud.com", "a**f@icloud.com"),
    ("ab@hotmail.com", "**@hotmail.com"),
    ("Work account", "Work account"),
    ("not-an-email@", "not-an-email@"),
])
func privateProfileLabelMasksEmailLocalPart(input: String, expected: String) {
    #expect(DisplayFormatter.privateProfileLabel(input) == expected)
}
```

Update the test snapshot helper to accept a `label` argument, then add row
assertions for a snapshot labeled `alphaexample@example.com`:

```swift
#expect(sidebarPresentation.title == "alphae**mple@example.com")
#expect(menuPresentation.title == "alphae**mple@example.com")
```

Add a status-item assertion:

```swift
#expect(content.profileLabel == "putrig**ah13@gmail.com")
```

- [ ] **Step 2: Run `make test` and verify RED**

Expected: compile failure because `privateProfileLabel(_:)` does not exist.

- [ ] **Step 3: Implement the shared pure formatter**

Add to `DisplayFormatter`:

```swift
static func privateProfileLabel(_ label: String) -> String {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let atIndex = trimmed.lastIndex(of: "@"),
          atIndex > trimmed.startIndex,
          atIndex < trimmed.index(before: trimmed.endIndex) else {
        return trimmed
    }

    let local = String(trimmed[..<atIndex])
    let domain = String(trimmed[trimmed.index(after: atIndex)...])
    guard local.contains(where: \.isWhitespace) == false,
          domain.contains("."),
          domain.contains(where: \.isWhitespace) == false else {
        return trimmed
    }

    let maskedLocal: String
    switch local.count {
    case 11...:
        maskedLocal = "\(local.prefix(6))**\(local.suffix(4))"
    case 7...10:
        maskedLocal = "\(local.prefix(3))**\(local.suffix(2))"
    case 3...6:
        maskedLocal = "\(local.prefix(1))**\(local.suffix(1))"
    default:
        maskedLocal = "**"
    }

    return "\(maskedLocal)@\(domain)"
}
```

- [ ] **Step 4: Route every summary title through the formatter**

In `ProfileSummaryRowPresentation.init`, replace:

```swift
title = snapshot.label
```

with:

```swift
title = DisplayFormatter.privateProfileLabel(snapshot.label)
```

In `compactStatusLabel(for:)`, return the full masked email when masking changes
the label, while keeping the old seven-character behavior for non-email labels:

```swift
let privateLabel = DisplayFormatter.privateProfileLabel(trimmed)
if privateLabel != trimmed {
    return privateLabel
}
```

Place this before the existing non-email compaction logic.

- [ ] **Step 5: Run `make test` and verify GREEN**

Expected: all formatter, sidebar/menu-panel, and status-item tests pass.

- [ ] **Step 6: Commit the masking slice**

```bash
git add Sources/Views/DisplayFormatter.swift Sources/Views/ProfileSummaryRow.swift Sources/Controllers/PlusProfileController.swift Tests/DisplayFormatterTests.swift Tests/ProfileSummaryRowTests.swift Tests/PlusProfileControllerTests.swift
git commit -m "feat(privacy): mask email labels in summary surfaces"
```

### Task 4: Define Calm Form Presentation Contracts

**Files:**
- Modify: `Tests/ProfileManagerWindowViewTests.swift`
- Modify: `Sources/Views/AccountWindowView.swift`

- [ ] **Step 1: Write failing tests for copy, reveal, and save state**

```swift
@Test
func privateFieldPresentationCopiesRealValueWithoutRevealingIt() {
    let hidden = ProfileManagerPrivateFieldPresentation(
        title: "Password",
        value: "secret-value",
        isRevealed: false,
        isCopied: false
    )
    let revealed = ProfileManagerPrivateFieldPresentation(
        title: "Password",
        value: "secret-value",
        isRevealed: true,
        isCopied: true
    )

    #expect(hidden.copyText == "secret-value")
    #expect(hidden.revealTitle == "Show")
    #expect(hidden.revealSymbolName == "eye")
    #expect(revealed.copyTitle == "Copied")
    #expect(revealed.revealTitle == "Hide")
    #expect(revealed.revealSymbolName == "eye.slash")
}

@Test
func detailsFormPresentationShowsOneSaveActionOnlyWhenDirty() {
    let profile = sampleProfile(label: "alpha@example.com", sortOrder: 0)
    let clean = ProfileManagerDetailsFormPresentation(
        draft: PlusProfileDetailsDraft(profile: profile),
        profile: profile,
        isSaved: false
    )
    var changedDraft = PlusProfileDetailsDraft(profile: profile)
    changedDraft.notes = "Temporary"
    let changed = ProfileManagerDetailsFormPresentation(
        draft: changedDraft,
        profile: profile,
        isSaved: false
    )

    #expect(clean.isSaveEnabled == false)
    #expect(changed.isSaveEnabled)
    #expect(changed.saveTitle == "Save changes")
}
```

- [ ] **Step 2: Run `make test` and verify RED**

Expected: compile failure because the two presentation types do not exist.

- [ ] **Step 3: Add small presentation values**

```swift
struct ProfileManagerPrivateFieldPresentation: Equatable, Sendable {
    let title: String
    let copyText: String
    let isRevealed: Bool
    let isCopied: Bool

    init(title: String, value: String, isRevealed: Bool, isCopied: Bool) {
        self.title = title
        copyText = value
        self.isRevealed = isRevealed
        self.isCopied = isCopied
    }

    var isCopyDisabled: Bool {
        copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var copyTitle: String { isCopied ? "Copied" : "Copy" }
    var copySymbolName: String { isCopied ? "checkmark" : "doc.on.doc" }
    var revealTitle: String { isRevealed ? "Hide" : "Show" }
    var revealSymbolName: String { isRevealed ? "eye.slash" : "eye" }
}

struct ProfileManagerDetailsFormPresentation: Equatable, Sendable {
    let draft: PlusProfileDetailsDraft
    let savedDraft: PlusProfileDetailsDraft
    let isSaved: Bool

    init(draft: PlusProfileDetailsDraft, profile: PlusProfile, isSaved: Bool) {
        self.draft = draft
        savedDraft = PlusProfileDetailsDraft(profile: profile)
        self.isSaved = isSaved
    }

    var isSaveEnabled: Bool { draft != savedDraft }
    var saveTitle: String { isSaved ? "Saved" : "Save changes" }
    var saveSymbolName: String { isSaved ? "checkmark" : "square.and.arrow.down" }
}
```

- [ ] **Step 4: Run `make test` and verify GREEN**

Expected: all tests pass.

- [ ] **Step 5: Commit the presentation slice**

```bash
git add Sources/Views/AccountWindowView.swift Tests/ProfileManagerWindowViewTests.swift
git commit -m "test(profile): define account details form states"
```

### Task 5: Build the Six-Field Profile Form

**Files:**
- Modify: `Tests/ProfileManagerWindowViewTests.swift`
- Modify: `Sources/Views/AccountWindowView.swift`
- Modify: `Sources/Controllers/PlusProfileController.swift`

- [ ] **Step 1: Replace the old two-field structure test with a failing form test**

```swift
@Test
func selectedProfileBuildsSixEditableProfileFields() throws {
    let tempDirectory = makeTemporaryDirectory()
    let store = ProfileCatalogStore(
        fileURL: tempDirectory.appendingPathComponent("profiles.json")
    )
    let profile = sampleProfile(label: "alpha@example.com", sortOrder: 0)
    try store.saveProfiles([profile])
    let controller = PlusProfileController(
        catalogStore: store,
        dataService: StubProfileViewDataService(),
        autoStart: false
    )
    let hostingView = makeHostingView(controller: controller)
    let window = hostInWindow(hostingView)
    defer { window.orderOut(nil) }

    flushViewHierarchy(for: hostingView)

    #expect(editableTextFieldCount(in: hostingView) >= 5)
    #expect(textEditorCount(in: hostingView) == 1)
}
```

Count at least five single-line editors because AppKit can expose a revealed
`SecureField` differently. Require exactly one multi-line notes editor.

- [ ] **Step 2: Run `make test` and verify RED**

Expected: the form structure test fails because only Label and Email link exist.

- [ ] **Step 3: Replace separate field drafts with one atomic draft**

Use these states in `ProfileManagerWindowView`:

```swift
@State private var detailsDraft = PlusProfileDetailsDraft()
@State private var revealedPrivateFields: Set<ProfilePrivateField> = []
@State private var copiedField: ProfileDetailsCopyField?
@State private var copyResetTask: Task<Void, Never>?
@State private var showsSavedConfirmation = false
@State private var saveResetTask: Task<Void, Never>?
```

Define small enums:

```swift
enum ProfilePrivateField: Hashable {
    case password
    case twoFactorCode
}

enum ProfileDetailsCopyField: Hashable {
    case label
    case password
    case twoFactorCode
    case phoneNumber
}
```

On profile selection, call:

```swift
detailsDraft = snapshot.map { PlusProfileDetailsDraft(profile: $0.profile) } ?? .init()
revealedPrivateFields.removeAll()
copiedField = nil
showsSavedConfirmation = false
```

- [ ] **Step 4: Build reusable normal, private, and notes field rows**

The normal field row uses a plain `TextField`. The private field row switches
between `SecureField` and `TextField` from the same binding:

```swift
Group {
    if presentation.isRevealed {
        TextField(placeholder, text: $text)
    } else {
        SecureField(placeholder, text: $text)
    }
}
.textFieldStyle(.plain)
```

Use `ProfileManagerInlineFieldActionButton` for Show/Hide and Copy. Copy reads
`presentation.copyText`, not the visible field. The notes row uses:

```swift
TextEditor(text: $detailsDraft.notes)
    .font(ProfileManagerTypography.body)
    .scrollContentBackground(.hidden)
    .frame(minHeight: 72, maxHeight: 108)
```

Render fields in the approved order: Label, Email link, Password, 2FA code,
Phone number, Notes. Keep tags below the form.

- [ ] **Step 5: Add one quiet Save action**

Create the form presentation from the draft and current profile. Place one button
above the fields, aligned to the trailing edge:

```swift
if formPresentation.isSaveEnabled || showsSavedConfirmation {
    Button {
        saveDetailsDraft(for: snapshot)
    } label: {
        Label(formPresentation.saveTitle, systemImage: formPresentation.saveSymbolName)
    }
    .buttonStyle(ProfileManagerSecondaryButtonStyle())
    .disabled(formPresentation.isSaveEnabled == false)
}
```

Save through:

```swift
let didSave = controller.updateDetails(for: snapshot.id, draft: detailsDraft)
guard didSave else { return }
detailsDraft = controller.profiles
    .first(where: { $0.id == snapshot.id })
    .map { PlusProfileDetailsDraft(profile: $0.profile) } ?? detailsDraft
showsSavedConfirmation = true
```

Reset confirmation after 1.4 seconds. Keep the draft unchanged if persistence
sets the controller's save-error status.

- [ ] **Step 6: Add field-specific Copy and reveal behavior**

Use `NSPasteboard.general` with one shared helper:

```swift
private func copy(_ text: String, field: ProfileDetailsCopyField) {
    guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    copiedField = field
    scheduleCopyReset(for: field)
}
```

Toggle reveal state without changing the saved value. Switching profiles and
closing the window cancels both reset tasks and hides private fields.

- [ ] **Step 7: Remove obsolete per-field save code**

Delete `labelDraft`, `emailLinkDraft`, `saveLabelDraft`,
`saveEmailLinkDraft`, `isLabelSaveEnabled`, `isEmailLinkSaveEnabled`, and the
field-level Save control from `ProfileManagerEditableField`.

After the UI has no callers, remove `updateLabel` and `updateEmailLink` from
`PlusProfileController` and update their old tests to cover `updateDetails`.

- [ ] **Step 8: Run `make test` and verify GREEN**

Expected: all tests pass, the form structure test sees all six editors, and no
warning is emitted because warnings are treated as errors.

- [ ] **Step 9: Commit the finished form**

```bash
git add Sources/Views/AccountWindowView.swift Sources/Controllers/PlusProfileController.swift Tests/ProfileManagerWindowViewTests.swift Tests/PlusProfileControllerTests.swift
git commit -m "feat(profile): add minimal account details form"
```

### Task 6: Full Verification and Visual QA

**Files:**
- Modify: `Learnings.md` only if a non-obvious reusable trap was found.

- [ ] **Step 1: Check the complete diff**

Run:

```bash
git status --short
git diff --check HEAD~4..HEAD
git diff --stat HEAD~4..HEAD
```

Expected: only intended source, test, spec, and plan files; no whitespace errors.
Leave the user's existing untracked `commit_message.txt` untouched.

- [ ] **Step 2: Run strict build and all tests**

Run:

```bash
make agent-verify
```

Expected: `BUILD SUCCEEDED`, the Swift Testing summary reports the full test
count, and there are zero failures.

- [ ] **Step 3: Launch the app**

Run:

```bash
TRACE_PRIVATE_API=0 make build-and-run-background
```

Expected: CodexPlusBar launches without a crash.

- [ ] **Step 4: Verify the Profile Manager visually**

Open `CodexPlusBar Profiles`, select a profile, and confirm:

- The six fields appear in the approved order.
- Password and 2FA text are hidden.
- Show/Hide changes only the chosen field.
- Copy works while the value stays hidden.
- Notes is compact and multi-line.
- Only one Save action appears after an edit.
- The sidebar email uses `first6**last4@domain`.
- Tags, Usage, Actions, and Chrome sign-in remain readable.
- The form fits at the minimum `1080 x 760` window size without horizontal clipping.

Capture a screenshot with:

```bash
screencapture -x /tmp/codexplusbar-profile-details.png
```

Inspect the image before continuing.

- [ ] **Step 5: Verify the menu surfaces visually**

Open the menu bar panel and confirm its email label is masked with the domain
visible. Confirm the top macOS menu-bar text also uses the same mask and is not
clipped in a way that hides the domain.

Capture and inspect:

```bash
screencapture -x /tmp/codexplusbar-menu-email-mask.png
```

- [ ] **Step 6: Record only hard-won knowledge**

If a build, test, AppKit bridge, or layout problem required extra investigation,
append one dated note under the closest `Learnings.md` section with the trap,
fix, and prevention. If no such trap occurred, do not add noise.

- [ ] **Step 7: Re-run verification after any visual fix**

Run:

```bash
make agent-verify
git diff --check
git status --short
```

Expected: build and tests pass again; no whitespace errors; only intended files
remain changed.
