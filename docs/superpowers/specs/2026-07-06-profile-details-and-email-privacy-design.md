# Profile Details and Email Privacy Design

Date: 2026-07-06

Status: Approved design

## Goal

Add four optional profile fields:

- Password
- 2FA code text
- Phone number
- Notes

Also hide most of an email address anywhere profiles are summarized, while keeping
the email domain visible.

## Scope

This work changes:

- The saved profile data model and local JSON catalog
- The Profile Manager detail form
- Profile labels in the manager sidebar
- Profile labels in the menu bar panel
- Profile labels in the macOS status item
- Automated tests for storage, editing, masking, and presentation

This work does not:

- Generate changing 2FA codes
- Send profile details to a server
- Store profile details in Apple Keychain
- Show notes or private values in summary rows

## Storage

The new values are optional strings stored in the existing local
`profiles.json` file:

- `password`
- `twoFactorCode`
- `phoneNumber`
- `notes`

The user chose plain local-file storage. The app does not encrypt these values.
Missing keys decode as `nil`, so existing profile files remain compatible.
Whitespace-only values normalize to `nil`.

The existing server-derived `detectedNote` stays separate from the new
user-written `notes` field.

## Profile Manager Form

The main profile card uses one clear vertical form in this order:

1. Profile label
2. Email link
3. Password
4. 2FA code
5. Phone number
6. Notes

Password and 2FA code use hidden text by default. Each private field has:

- A Show or Hide action
- A Copy action that copies the real value without revealing it

Phone number has a Copy action. Notes uses a compact multi-line editor.

The current repeated field-level Save buttons are replaced with one
`Save changes` action for the whole form. This action appears or becomes active
only when the draft differs from the saved profile. After saving, the form gives
small temporary confirmation without changing layout.

Copy confirmation is local to the field that was copied. Switching profiles
clears reveal and copy-confirmation state, so private values do not remain visible.

Tags and server-derived status information remain below the editable fields.
The rest of the detail pane keeps its current usage, actions, and Chrome sign-in
sections.

## Email Masking

Mask only labels that contain a valid-looking email address with a nonempty local
part and domain. Non-email labels remain unchanged.

For a local part longer than 10 characters:

```text
first 6 characters + ** + last 4 characters + @ + full domain
```

Example:

```text
putrigildarahimah13@gmail.com
putrig**ah13@gmail.com
```

Short local parts use safer fallback masks:

- 7 to 10 characters: first 3, `**`, last 2
- 3 to 6 characters: first 1, `**`, last 1
- 1 to 2 characters: `**`

The domain remains visible for every domain, including Gmail, Outlook, Hotmail,
iCloud, and other valid-looking domains.

Use one shared pure formatter for all summary surfaces:

- Profile Manager sidebar
- Menu bar panel profile rows
- Top macOS menu-bar status text

The Profile Manager editor continues showing the full label because it is the
place for editing and copying the source value.

## Data Flow

1. Selecting a profile loads all editable values into a local draft.
2. Editing the draft does not write partial values to disk.
3. `Save changes` normalizes and sends the complete draft to the controller.
4. The controller updates the matching profile once and persists the catalog.
5. Summary presentations derive their masked label from the saved profile.

The controller exposes one whole-profile details update instead of four unrelated
write paths. This keeps persistence atomic and avoids repeated disk writes.

## Accessibility

- Every icon action has a clear help and accessibility label.
- Show and Hide labels describe the current action.
- Copy confirmation is also available to accessibility tools.
- Hidden fields remain properly labeled as Password and 2FA code.
- Notes has a visible label that does not disappear when text is entered.

## Error Handling

The catalog already reports persistence failures through the controller. The new
whole-form save uses the same path. A failed save keeps the draft on screen and
shows the existing profile-manager status message so the user can retry.

Empty optional values are saved as `nil`. Copy actions are disabled when their
normalized value is empty.

## Tests

Use test-driven development for each behavior:

- Old JSON without the four new keys still decodes
- New values survive JSON encode, save, and reload
- Whitespace-only optional values normalize to `nil`
- One controller update persists every changed field
- Long and short email local parts follow the masking rules
- Domains remain unchanged
- Non-email labels remain unchanged
- Sidebar and menu-bar presentations use the shared masked label
- The full label remains available to the editor
- Password and 2FA copy presentations use the real hidden value
- Empty values disable Copy
- Reveal and Save state follow the current draft

Final verification uses the repository's complete test command and a macOS build.
The running app is then checked visually in both the Profile Manager and menu bar
panel.
