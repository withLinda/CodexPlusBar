# CloudKit Developer ID DMG

## Identifiers and configurations

- Bundle: `com.linda.CodexPlusBar`; team: `2Z8N5KTWQZ`.
- Private CloudKit container: `iCloud.com.linda.CodexPlusBar`; zone: `AccountSyncV1`.
- `Debug`, `Release`, tests and `scripts/render_design.sh` remain cloud-disabled. Runtime entitlement inspection rejects ad-hoc signatures before constructing `CKContainer`.
- `CodexPlusBar-CloudDevelopment` / `CloudDevelopment` use Apple Development signing and the Development profile.
- `CodexPlusBar-CloudProduction` / `CloudProduction` use Developer ID signing and the Production profile.
- Cloud configurations enable hardened runtime, preserve this app's unsandboxed architecture, and exclude debugger entitlement injection.
- macOS APNs uses [`com.apple.developer.aps-environment`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment), not the iOS `aps-environment` key. Development pairs with `development`; Production pairs with `production`.
- The app-owned Keychain access group is `2Z8N5KTWQZ.com.linda.CodexPlusBar`. Keys use synchronizable data-protection Keychain items. Enable iCloud Passwords & Keychain on both Macs.

## Provisioning verified 2026-11-09

The Apple Developer account contains explicit App ID `PQRT3CMR2K`, associated container `TXM55JK775`, iCloud/CloudKit and Push Notifications.

Local profiles (do not commit their bytes):

- Development: `~/Downloads/CodexPlusBar_macOS_Development_CloudKit.provisionprofile`, UUID `6c6d447c-d46f-4ace-8553-ad287e949de4`, expires 2027-11-09.
- Developer ID: `~/Downloads/CodexPlusBar_Developer_ID_CloudKit.provisionprofile`, UUID `a5ea227b-c3ad-4618-aa12-11cbfcf1ccbc`, expires 2044-11-04. The embedded certificate has a separate, shorter lifetime.
- Both installed under `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.

Renew through Certificates, Identifiers & Profiles when the profile/certificate expires. Reconfirm team, exact app/container, APNs environment and included signing certificate. Never substitute another app's profile.

## Build and verify

```bash
python3 -m unittest discover -s Tests/Release -p 'test_cloud_signing_preflight.py'
make cloud-dmg \
  CLOUD_PROFILE="$HOME/Downloads/CodexPlusBar_Developer_ID_CloudKit.provisionprofile" \
  CLOUD_SIGN_IDENTITY="Developer ID Application: Linda Fitriani (2Z8N5KTWQZ)" \
  NOTARY_PROFILE=CodexPlusBar-notary
```

`cloud-archive` runs only the universal archive, embedding, signing and preflight stages. `cloud-preflight CLOUD_APP=/absolute/path/CodexPlusBar.app` inspects an existing Production artifact. For a Development artifact use the Python CLI with `--environment Development`.

To resume packaging an unchanged successful archive, pass `--package-archive /absolute/path/CodexPlusBar.xcarchive` to `scripts/notarize_cloud_dmg.sh` with the same environment variables. It copies the archived app into a new release workspace and signs/verifies that copy; it does not rebuild or alter the source archive.

Every release uses a unique directory under `build/cloud-releases/`. The script:

1. Archives arm64 and x86_64 with strict concurrency and warnings as errors.
2. Embeds the supplied profile before timestamped Developer ID signing with explicit Production entitlements.
3. Checks both architectures, signature, profile lifetime/certificate/team/app/container/environment/push/Keychain and absence of sandbox/debugger access.
4. Notarizes and staples the app, then builds, signs, notarizes and staples the DMG. Each staple precedes its validation.
5. Assesses Gatekeeper and mounts the DMG read-only to check the actual packaged app and its ticket.
6. Writes a basename-relative SHA-256 checksum after all stapling is complete.

Keep `archive.log`, `app-notary.json`, `dmg-notary.json`, preflight results and checksum beside the DMG. If notarization is rejected, inspect its submission ID with `xcrun notarytool log <id> --keychain-profile CodexPlusBar-notary`. Do not mutate a notarized signed app. Rebuild a new release directory instead.

Building never publishes, installs or replaces `/Applications/CodexPlusBar.app`.

## Schema and live evidence

`CPBEncryptedRecordV1` is deployed to Production with `schemaVersion` (Int64), `kind`, `keyID`, `profileID` (String), and `payload` (Asset). No query indexes are needed. `_creator` has READ/WRITE and `_icloud` CREATE. The application uses the private database; user payloads inside assets are AES-GCM encrypted.

Separate provisioned synthetic Development and Developer ID Production probes passed account availability, encrypted CKAsset save/readback, and app-owned synchronizable Keychain add/read/delete. Production APNs registration and private-zone subscription save/readback also passed. Temporary zones/subscriptions/keys were removed. New offline preflight validates both signed probe bundles.

Those checks do not prove cross-device key delivery, push delivery, or the finished app's two-Mac operation. Follow the acceptance document and record those observations from the final installed artifact before declaring cross-Mac acceptance complete.
