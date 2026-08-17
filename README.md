# CodexPlusBar

> Stop checking accounts one by one. See the right Codex or Claude account before you work.

CodexPlusBar is a native macOS menu bar app for people who use more than one ChatGPT/Codex or Claude browser account. It keeps every account in its own local Chrome profile and puts live remaining usage, reset times, and sign-in status in one place.

[Download CodexPlusBar.dmg](https://github.com/withLinda/CodexPlusBar/releases/latest/download/CodexPlusBar.dmg) · [Release notes and checksum](https://github.com/withLinda/CodexPlusBar/releases/latest) · [View the source](https://github.com/withLinda/CodexPlusBar)

## Why use it?

Opening accounts one at a time is slow and easy to get wrong. CodexPlusBar works like a small control panel: check your limits at a glance, choose an account with enough capacity, and fix a sign-in before it blocks your work.

- **One glance:** See every saved account from the menu bar.
- **Better account choice:** Find accounts with usable, high, or full limits before starting a task.
- **Less account confusion:** Each account has its own named Chrome profile and provider session.
- **Faster recovery:** Profiles that need login or failed refresh are clearly marked.
- **No API key setup:** Sign in through Chrome and let the app read the signed-in web session.

## See it in action

### Menu bar dashboard

![CodexPlusBar menu bar dashboard with profile filters and usage cards](docs/screenshots/codexplusbar-menu-bar-panel.png)

### Profile Manager

![CodexPlusBar Profile Manager with saved profile details and usage](docs/screenshots/codexplusbar-profile-manager.png)

Private values in these screenshots are masked or covered.

## What you can do

### Check usage without account hopping

- Track **Codex (ChatGPT)** and **Claude** profiles together.
- See remaining **5H** and **7D** usage, live reset countdowns, refresh time, sign-in state, and Codex account expiry when ChatGPT provides it.
- Refresh all profiles on launch, every five minutes, or on demand; refresh one profile when you only need a quick check.
- Keep healthy cards visible when another profile fails to refresh.

### Find the right profile quickly

- Search by full or partial email address or phone number.
- Filter by provider (`Codex` or `Claude`), tag (`Active`, `Need action`, `Pending`), or limit (`Usable`, `>35%`, `Full`).
- Sort by next reset, account expiry, or saved order; the selected sort is remembered.
- See counts beside filters and clear all filters with one action.
- Copy a profile label, open its saved link, open Profile Manager, or pin a profile from its card.
- Pin one profile so its label and usage appear in the macOS menu bar status.
- Adjust panel text size with `A-` and `A+` controls.

### Keep profile details together

Profile Manager lets you add, rename, reorder, select a provider for, and remove profiles. Optional fields include:

- profile label and web/email link
- password and 2FA secret (copy helpers)
- phone number and private notes
- status tags

Private fields stay covered until you choose **Show**. A saved 2FA secret can generate a current TOTP code, show its expiry countdown, and copy the code without revealing it first. The phone summary groups shared numbers, one-use numbers, and profiles with no number, then opens a profile directly.

### Sign in through the correct Chrome profile

- Open Codex or Claude in the profile's dedicated Chrome window.
- Sign in yourself, then return to CodexPlusBar; the app imports the local session and refreshes usage.
- Use **Check now**, **Cancel**, or **Clear session** when a sign-in needs attention.
- Use **Touch ID help** when a Codex passkey needs a fuller Chrome sign-in flow.
- A ready profile opens its saved provider account page; a profile that needs login opens the repair flow.

The app does not type passwords into provider pages for you.

### Import many profiles at once

Bulk import accepts one profile per line in this format:

```text
person@example.com|your-password|YOURBASE32SECRET
2. second@example.com|another-password|ANOTHERBASE32SECRET
```

It previews valid rows, reports the exact lines that need fixing, ignores blank lines, and creates the imported rows as Codex profiles. You can change the provider after import. Imported rows use `https://2fa.live` as their starting saved link; the app does not send your 2FA key to that link.

### Generate Gmail dot variations

**Email Tools** generates every single-dot variation for a Gmail username, such as `johndoe@gmail.com` → `j.ohndoe@gmail.com`. Save sessions, search long lists, copy one or all unused variations, and mark variations as used so you do not repeat work.

### Make the interface fit your workflow

- Everforest-based interface with **System**, **Dark**, and **Light** appearance.
- **Hard**, **Medium**, and **Soft** contrast choices.
- Provider colors, status icons, accessibility labels, and masked email labels for quick scanning.

## Quick start

1. Open CodexPlusBar. Its status appears in the macOS menu bar; it does not add a normal Dock icon.
2. Choose **Profile Manager** from the menu bar panel.
3. Select **Add profile**, or choose **Import** for multiple profiles.
4. Select **Codex** or **Claude**, add a label, and save.
5. Choose **Open Codex** or **Open Claude** and sign in in the Chrome window that opens.
6. Return to CodexPlusBar. If needed, select **Check now**; usage will then refresh automatically.
7. Pin a profile, or use search, filters, and sorting to choose one for your next task.

## How usage is shown

- Percentages are **remaining** usage, not used usage.
- `5H` is the provider's five-hour window; `7D` is its seven-day window.
- `—` or `Unavailable` means the provider did not return that value; the app does not guess.
- Countdown text uses the provider's reset time, so it stays useful while the app is open.
- Codex expiry comes from ChatGPT account data. Claude expiry is not fetched.

CodexPlusBar reads the signed-in web services used by ChatGPT and Claude. These are provider website endpoints, not stable public APIs, so a provider website change can temporarily affect refresh or sign-in until the app is updated.

## Install

1. [Download `CodexPlusBar.dmg`](https://github.com/withLinda/CodexPlusBar/releases/latest/download/CodexPlusBar.dmg).
2. Optional: download [`CodexPlusBar.dmg.sha256`](https://github.com/withLinda/CodexPlusBar/releases/latest/download/CodexPlusBar.dmg.sha256) into the same folder, then verify the DMG:

   ```bash
   shasum -a 256 -c CodexPlusBar.dmg.sha256
   ```

3. Open the DMG and drag `CodexPlusBar.app` to **Applications**.
4. Eject the DMG and open CodexPlusBar from **Applications**.

The published DMG is signed and notarized. You do not need Xcode to install it.

## Requirements

- macOS 14 or newer
- Google Chrome
- Internet access
- One ChatGPT or Claude account for each profile you want to track

## Build from source

Developers can build the current macOS project with Xcode 26 or newer:

```bash
git clone https://github.com/withLinda/CodexPlusBar.git
cd CodexPlusBar
make build-and-run
```

Useful checks:

```bash
make test
make agent-verify
make dmg
```

`make dmg` writes a local developer DMG to `build/dist/CodexPlusBar.dmg`.

## Local data and privacy

CodexPlusBar has no profile-sync server of its own. It connects directly to ChatGPT or Claude through the browser sessions created on your Mac.

- Profile data is stored at `~/Library/Application Support/CodexPlusBar/profiles.json`.
- Email Tools sessions are stored at `~/Library/Application Support/CodexPlusBar/dot-trick-sessions.json`.
- Named Chrome profiles are stored at `~/Library/Application Support/CodexPlusBar/ChromeProfiles`.
- Profile labels, links, passwords, 2FA keys, phone numbers, notes, and tags stay on your Mac.
- Passwords and 2FA keys are **not** stored in the macOS Keychain and are **not encrypted by CodexPlusBar**.
- Removing a profile also removes its local browser data.

Use the app only on a Mac user account you trust. Do not share the profile JSON file, Chrome profile folder, screenshots with private values, or real import rows.
