# Menubar Inline Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore visible `Copy`, `Email link`, and `Show on top` controls inside each menu bar profile row without bringing back the older heavier card layout.

**Architecture:** Keep the current `ProfileSummaryRow` as the base row view and extend its menu bar mode with a small trailing action rail. Let `MenuBarRootView` keep ownership of the actual behaviors like pinning, copy, and opening links, and pass those actions into the row only for menu bar usage.

**Tech Stack:** SwiftUI, AppKit pasteboard and workspace APIs, Swift Testing

---

### Task 1: Add failing presentation tests for inline menu bar actions

**Files:**
- Modify: `Tests/ProfileSummaryRowTests.swift`
- Test: `Tests/ProfileSummaryRowTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test
func menuBarPresentationShowsInlineSecondaryActions() {
    let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)
    let snapshot = sampleSnapshot(
        state: .ready,
        usage: sampleUsage(referenceDate: referenceDate, sevenDayRemainingPercent: 62),
        note: "Plus · Alpha",
        statusMessage: nil,
        isRefreshing: false,
        emailLink: "https://mail.google.com"
    )

    let presentation = ProfileSummaryRowPresentation(
        snapshot: snapshot,
        referenceDate: referenceDate,
        mode: .menuBar(isPinned: false)
    )

    #expect(presentation.showsInlineSecondaryActions == true)
    #expect(presentation.canOpenEmailLink == true)
    #expect(presentation.showsPinnedCapsule == true)
    #expect(presentation.pinnedCapsuleTitle == "Show on top")
}

@Test
func pinnedMenuBarPresentationUsesCalmPinnedCapsule() {
    let referenceDate = Date(timeIntervalSince1970: 1_776_000_000)
    let snapshot = sampleSnapshot(
        state: .ready,
        usage: sampleUsage(referenceDate: referenceDate, sevenDayRemainingPercent: 62),
        note: "Plus · Epsilon",
        statusMessage: nil,
        isRefreshing: false,
        emailLink: nil
    )

    let presentation = ProfileSummaryRowPresentation(
        snapshot: snapshot,
        referenceDate: referenceDate,
        mode: .menuBar(isPinned: true)
    )

    #expect(presentation.showsInlineSecondaryActions == true)
    #expect(presentation.canOpenEmailLink == false)
    #expect(presentation.pinnedCapsuleTitle == "On top")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project CodexPlusBar.xcodeproj -scheme CodexPlusBar -destination 'platform=macOS' -only-testing:CodexPlusBarTests/ProfileSummaryRowTests`

Expected: FAIL because the new presentation properties do not exist yet and current menu bar presentation still hides inline actions.

- [ ] **Step 3: Write minimal implementation**

```swift
struct ProfileSummaryRowPresentation: Equatable, Sendable {
    let showsInlineSecondaryActions: Bool
    let canOpenEmailLink: Bool
    let showsPinnedCapsule: Bool
    let pinnedCapsuleTitle: String

    init(snapshot: PlusProfileSnapshot, referenceDate: Date = .now, mode: ProfileSummaryRowMode) {
        switch mode {
        case let .menuBar(isPinned):
            showsInlineSecondaryActions = true
            canOpenEmailLink = snapshot.profile.resolvedEmailLinkURL != nil
            showsPinnedCapsule = true
            pinnedCapsuleTitle = isPinned ? "On top" : "Show on top"
        case .sidebar:
            showsInlineSecondaryActions = false
            canOpenEmailLink = false
            showsPinnedCapsule = false
            pinnedCapsuleTitle = ""
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project CodexPlusBar.xcodeproj -scheme CodexPlusBar -destination 'platform=macOS' -only-testing:CodexPlusBarTests/ProfileSummaryRowTests`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Tests/ProfileSummaryRowTests.swift Sources/Views/ProfileSummaryRow.swift
git commit -m "test: cover menubar inline action presentation"
```

### Task 2: Add failing menu bar view test and wire the inline controls

**Files:**
- Modify: `Sources/Views/ProfileSummaryRow.swift`
- Modify: `Sources/Views/MenuBarRootView.swift`
- Modify: `Tests/MenuBarRootViewTests.swift`
- Test: `Tests/MenuBarRootViewTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test
func menuBarRootViewUsesInteractiveProfileSummaryRows() throws {
    let tempDirectory = makeTemporaryDirectory()
    let store = ProfileCatalogStore(
        fileURL: tempDirectory.appendingPathComponent("profiles.json", isDirectory: false)
    )
    let profile = PlusProfile(
        id: UUID(),
        label: "alpha@example.com",
        emailLink: "https://mail.google.com",
        detectedNote: "Plus",
        webDataStoreID: UUID(),
        sortOrder: 0,
        createdAt: Date(timeIntervalSince1970: 1_776_000_000),
        lastRefreshAt: nil,
        lastKnownState: .active
    )
    try store.saveProfiles([profile])

    let controller = PlusProfileController(catalogStore: store, autoStart: false)
    let (defaults, suiteName) = makeUserDefaults()
    let rootView = MenuBarRootView(
        controller: controller,
        currentTime: AppMinuteClock(now: Date(timeIntervalSince1970: 1_776_000_000)),
        userDefaults: defaults,
        openManagerWindow: { _ in }
    )

    let bodyDescription = String(reflecting: type(of: rootView.body))
    #expect(bodyDescription.contains("MenuBarProfileRow") == true)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project CodexPlusBar.xcodeproj -scheme CodexPlusBar -destination 'platform=macOS' -only-testing:CodexPlusBarTests/MenuBarRootViewTests`

Expected: FAIL because the current root view still mounts plain `ProfileSummaryRow` inside a wrapper button.

- [ ] **Step 3: Write minimal implementation**

```swift
private struct MenuBarProfileRow: View {
    let snapshot: PlusProfileSnapshot
    let referenceDate: Date
    let isPinned: Bool
    let openManagerWindow: () -> Void
    let copyProfileLabel: () -> Void
    let openEmailLink: () -> Void
    let pinProfile: () -> Void

    var body: some View {
        ProfileSummaryRow(
            snapshot: snapshot,
            referenceDate: referenceDate,
            mode: .menuBar(isPinned: isPinned),
            primaryAction: openManagerWindow,
            copyAction: copyProfileLabel,
            emailAction: openEmailLink,
            pinAction: pinProfile
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project CodexPlusBar.xcodeproj -scheme CodexPlusBar -destination 'platform=macOS' -only-testing:CodexPlusBarTests/MenuBarRootViewTests`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Views/ProfileSummaryRow.swift Sources/Views/MenuBarRootView.swift Tests/MenuBarRootViewTests.swift
git commit -m "feat: restore inline menubar row actions"
```

### Task 3: Verify full regression surface and record learnings if needed

**Files:**
- Modify if needed: `Learnings.md`
- Test: `Tests/ProfileSummaryRowTests.swift`
- Test: `Tests/MenuBarRootViewTests.swift`
- Test: `Tests/MenuBarStatusItemControllerTests.swift`

- [ ] **Step 1: Run focused regression tests**

Run: `xcodebuild test -project CodexPlusBar.xcodeproj -scheme CodexPlusBar -destination 'platform=macOS' -only-testing:CodexPlusBarTests/ProfileSummaryRowTests -only-testing:CodexPlusBarTests/MenuBarRootViewTests -only-testing:CodexPlusBarTests/MenuBarStatusItemControllerTests`

Expected: PASS

- [ ] **Step 2: Run the main repo verification command**

Run: `xcodebuild test -project CodexPlusBar.xcodeproj -scheme CodexPlusBar -destination 'platform=macOS'`

Expected: PASS with exit code `0`

- [ ] **Step 3: Append a learning note only if this work exposed a new non-obvious trap**

```markdown
- 2026-04-20: [trap]. Fix: [fix]. Prevent by [prevention].
```

- [ ] **Step 4: Commit any final cleanup**

```bash
git add Learnings.md Sources/Views/ProfileSummaryRow.swift Sources/Views/MenuBarRootView.swift Tests/ProfileSummaryRowTests.swift Tests/MenuBarRootViewTests.swift Tests/MenuBarStatusItemControllerTests.swift
git commit -m "test: verify menubar inline action restoration"
```
