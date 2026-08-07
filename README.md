# CodexPlusBar

CodexPlusBar is a native macOS menu bar app for people who use more than one Codex (ChatGPT) or Claude account. It keeps every saved account in a separate local browser profile and shows the remaining usage without making you switch accounts by hand.

The app shows the remaining 5-hour and 7-day usage, reset times, sign-in state, and Codex account expiry when ChatGPT supplies it. You sign in with Google Chrome. No OpenAI or Anthropic API key is needed.

## Screenshots

### Menu bar panel

![CodexPlusBar menu bar panel with profile filters and usage cards](docs/screenshots/codexplusbar-menu-bar-panel.png)

### Profile Manager

![CodexPlusBar Profile Manager with saved profile details and usage](docs/screenshots/codexplusbar-profile-manager.png)

Private values in these screenshots are masked or covered.

## Why It Is Useful

Checking many accounts one by one is slow. CodexPlusBar works like a small fuel gauge for your accounts: you can quickly see which account has enough usage left, which account needs a new sign-in, and when a limit will reset.

## Features

### Menu Bar Dashboard

- Shows a compact profile list directly from the macOS menu bar. The app does not add a normal Dock icon.
- Shows the saved provider, masked email label, manual status tags, 5H and 7D remaining usage, reset countdowns, and account expiry.
- Shows the last update time and how many profiles are currently visible.
- Pins one profile so its label and usage drive the macOS menu bar status. If the pinned profile is missing or not ready, the app chooses a ready profile that needs attention.
- Searches saved profiles by full or partial email address or phone number.
- Filters by provider (`Codex` or `Claude`).
- Filters by manual status tags: `Active`, `Need action`, and `Pending`.
- Filters by usage:
  - `Usable`: every known limit is above 0%.
  - `>35%`: every known limit is above 35%.
  - `Full`: the 5H limit has exactly 100% remaining.
- Shows a count beside each filter and provides one Reset action to clear active filters.
- Sorts profiles by the next 5H or 7D reset, account expiry, or saved order. The selected sort is remembered.
- Gives each profile quick actions to copy its label, open its saved link, open the manager, or pin it.
- Uses `A-` and `A+` controls to change the menu bar panel text size from 90% to 135%.
- Provides footer shortcuts for Refresh all, Profile Manager, Email Tools, theme settings, and Quit.

### Usage and Provider Support

- Supports Codex usage from ChatGPT and Claude usage from Claude.ai.
- Gives every profile its own provider choice. You can change a profile between Codex and Claude.
- Keeps each profile in its own local Chrome sign-in, so accounts do not share provider cookies.
- Refreshes all profiles when the app starts and then every five minutes.
- Refreshes all profiles together or only one selected profile.
- Opens a ready profile on its provider account page in the correct saved Chrome profile.
- Keeps one profile failure local. Other healthy profile cards can still show their usage.
- Shows both remaining percentages and live reset countdowns. A missing provider value is shown as unavailable instead of using a guessed number.
- Fetches Codex account expiry when ChatGPT supplies it. Claude account expiry is not fetched.
- Uses clear provider badges and different provider card colors.

### Profile Manager

- Adds, selects, renames, moves, and removes saved profiles.
- Saves these optional fields for each profile:
  - Profile label
  - Web or email link
  - Password
  - 2FA secret key
  - Phone number
  - Notes
  - Status tags
- Copies the label, password, 2FA key, phone number, or current OTP with one click.
- Hides password and 2FA values until you choose Show.
- Generates a current TOTP code from a saved 2FA secret.
- Keeps the OTP covered by default. You can copy it without showing it on the screen.
- Shows the OTP expiry countdown and reports an invalid 2FA key.
- Uses a searchable phone-number picker made from numbers already saved in other profiles.
- Includes a Phone summary page with three groups: shared numbers, numbers used once, and profiles with no number.
- Shows expiry information in the Phone summary and opens any listed profile directly.
- Uses the Move up and Move down actions to change the real saved order. Changing the display sort does not rewrite that order.
- Repairs duplicate saved profile rows automatically and keeps the first current copy.

### Sign-In and Session Tools

- Opens Codex or Claude sign-in in the correct dedicated Chrome profile.
- Imports the signed-in provider cookies locally when you return to CodexPlusBar, then refreshes usage automatically.
- Can check the Chrome session immediately with `Check now` or cancel an open sign-in flow.
- Tries to restore a saved Claude Chrome sign-in before asking you to log in again.
- Includes `Touch ID help` for Codex passkeys. This opens a fuller Chrome mode that can use Google Password Manager or a synced OpenAI passkey.
- Uses a smaller Chrome mode with extensions and Chrome Sync disabled for normal account pages and background cookie checks.
- Clears only the selected profile session when you want to sign in again.
- Removes the selected profile and its local browser data when you use Remove profile.

### Bulk Import

- Imports many profiles from `email|password|2FA` rows.
- Accepts normal rows and numbered rows such as `1. email|password|2FA`.
- Ignores blank lines and shows the exact line that needs a fix.
- Previews the number of valid profiles before import.
- Creates imported rows as Codex profiles. You can change the provider after import.
- Adds `https://2fa.live` as the saved link for an imported profile. You can replace this link later.
- Does not send the saved 2FA key to that link. The link only opens in your browser.

Example:

```text
person@example.com|your-password|YOURBASE32SECRET
2. second@example.com|another-password|ANOTHERBASE32SECRET
```

### Email Tools

- Opens from the envelope button in the menu bar panel.
- Generates every single-dot Gmail variation for a username. For example, `johndoe` produces `j.ohndoe@gmail.com`, `jo.hndoe@gmail.com`, and the other one-dot positions.
- Removes existing dots and normalizes the username before generation.
- Saves generated sessions locally and avoids duplicate sessions for the same Gmail username.
- Searches a long variation list.
- Copies one variation or all currently unused variations.
- Marks variations as used or unused and remembers that state.
- Shows how many variations exist and how many are already used.
- Removes a saved Email Tools session after a confirmation.

### Appearance and Readability

- Uses an Everforest-based interface.
- Supports System, Dark, and Light appearance.
- Supports Hard, Medium, and Soft contrast.
- Updates theme colors without resetting the current selection, search, or scroll position.
- Uses both icons and colors for provider and status meaning.
- Adds accessibility labels and help text to the main controls.
- Masks the middle of email addresses in compact profile lists while keeping the full saved value available in the detail form.

## Quick Start

1. Open CodexPlusBar. Its status appears in the macOS menu bar.
2. Open Profile Manager from the overlapping-window button.
3. Click Add profile, or click Import to add many profiles.
4. Choose Codex or Claude for the selected profile.
5. Add any useful private fields, phone number, notes, and status tags, then save the changes.
6. Click Open Codex or Open Claude and sign in inside the Chrome window.
7. Return to CodexPlusBar. The app imports the session and refreshes the usage.
8. Pin the profile you want in the top menu bar status.
9. Use search, filters, and sorting to find the best profile quickly.

Passwords are saved only as copyable helper values. CodexPlusBar does not type a password into a provider page for you.

## How Usage Is Shown

- Percentages mean **remaining usage**, not used usage.
- `5H` is the provider's five-hour window.
- `7D` is the provider's seven-day window.
- `—` and `Unavailable` mean the provider did not return that value.
- Reset text is calculated from the real reset date, so the countdown stays useful while the app is open.
- The full 5H state uses its own accent so a profile with 100% remaining is easy to notice.

CodexPlusBar reads the signed-in web services used by ChatGPT and Claude. These are website endpoints, not a stable public API. A provider website change can temporarily break refresh or sign-in until the app is updated.

## Chrome Storage

CodexPlusBar stores helper Chrome data here:

```text
~/Library/Application Support/CodexPlusBar/ChromeProfiles
```

All saved accounts share this one Chrome data folder, but each account has its own named Chrome profile inside it. This avoids storing a full copy of Chrome extensions, speech models, and component downloads for every account.

At startup, the app moves old per-account Chrome folders into the shared layout and removes generated caches and downloads. It keeps cookies, passwords, passkeys, bookmarks, normal and protected Google account settings, web-app metadata, and website data.

Close Chrome before changing this folder by hand.

## Install

Download the latest signed and notarized DMG from GitHub:

- [Latest release page](https://github.com/withLinda/CodexPlusBar/releases/latest)
- [Direct notarized DMG download](https://github.com/withLinda/CodexPlusBar/releases/download/snapshot-2026-08-08-profile-limit-filters/CodexPlusBar-snapshot-2026-08-08-profile-limit-filters.dmg)
- [SHA-256 checksum](https://github.com/withLinda/CodexPlusBar/releases/download/snapshot-2026-08-08-profile-limit-filters/CodexPlusBar-snapshot-2026-08-08-profile-limit-filters.dmg.sha256)

1. Download `CodexPlusBar-snapshot-2026-08-08-profile-limit-filters.dmg`.
2. Optional: download the checksum file into the same folder, open Terminal in that folder, and run:

   ```bash
   shasum -a 256 -c CodexPlusBar-snapshot-2026-08-08-profile-limit-filters.dmg.sha256
   ```

   A correct download prints `CodexPlusBar-snapshot-2026-08-08-profile-limit-filters.dmg: OK`.

3. Double-click the DMG.
4. Drag `CodexPlusBar.app` onto the `Applications` folder shown inside the DMG.
5. Replace the older copy if macOS asks.
6. Eject the DMG and open CodexPlusBar from Applications.

The DMG and app are signed and notarized, so macOS should verify them normally.

## Build From Source

The current project uses Swift 6 with strict concurrency checks and treats warnings as errors.

```bash
git clone https://github.com/withLinda/CodexPlusBar.git
cd CodexPlusBar
make build-and-run
```

Other useful commands:

```bash
make build
make test
make agent-verify
make dmg
```

`make dmg` writes a local developer DMG to `build/dist/CodexPlusBar.dmg`.

## Requirements

- macOS 14 or newer.
- Google Chrome.
- Internet access.
- A ChatGPT or Claude account for each profile you want to track.
- Xcode 26 or newer when building the current source.

## Local Data, Privacy, and Security

CodexPlusBar has no profile-sync server of its own. It connects directly to ChatGPT or Claude with the browser session that you created for each profile.

The profile catalog is stored here:

```text
~/Library/Application Support/CodexPlusBar/profiles.json
```

Email Tools sessions are stored here:

```text
~/Library/Application Support/CodexPlusBar/dot-trick-sessions.json
```

Important: profile labels, saved links, passwords, 2FA secret keys, phone numbers, notes, and tags are stored in the local profile JSON file. Passwords and 2FA keys are **not** stored in the macOS Keychain and are **not** encrypted by CodexPlusBar. Provider cookies also stay in the app's local browser and web-session storage.

Use this app only on a Mac user account that you trust. FileVault can add disk-level protection, but it does not change the plain local file format. Do not share your profile JSON file, Chrome profile folder, screenshots with visible private data, or real import rows.
