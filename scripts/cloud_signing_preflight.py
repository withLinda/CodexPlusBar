"""Offline CloudKit signing contract; system inspection lives in main's adapters."""
from dataclasses import dataclass
import argparse
import datetime as dt
import hashlib
import pathlib
import plistlib
import re
import subprocess
import tempfile


@dataclass
class Result:
    errors: list[str]

    @property
    def exit_code(self):
        return int(bool(self.errors))


def validate(profile, entitlements, signature, *, bundle, team, container, environment, now):
    errors = []

    def check(condition, message):
        if not condition:
            errors.append(message)

    check(environment in ("Production", "Development"), "Unsupported CloudKit environment")
    check(signature.get("verified") is True and not signature.get("adhoc", True), "Signature must verify and must not be ad-hoc")
    check(signature.get("identifier") == bundle, "Signature identifier differs from bundle ID")
    check(signature.get("team") == team, "Signature team mismatch")
    check(signature.get("runtime") is True, "Hardened runtime is required")
    authority = "Developer ID Application:" if environment == "Production" else "Apple Development:"
    check(any(x.startswith(authority) for x in signature.get("authorities", [])), "Wrong signing certificate class")
    if environment == "Production":
        check(signature.get("timestamp") is True, "Secure signing timestamp is required")
    identifier = f"{team}.{bundle}"
    expected = {
        "com.apple.application-identifier": identifier,
        "com.apple.developer.team-identifier": team,
        "com.apple.developer.icloud-container-identifiers": [container],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-environment": environment,
        "com.apple.developer.aps-environment": environment.lower(),
        "keychain-access-groups": [identifier],
    }
    for key, value in expected.items():
        check(entitlements.get(key) == value, f"Signed entitlement mismatch: {key}")
    for key in ("get-task-allow", "com.apple.security.get-task-allow", "com.apple.security.app-sandbox"):
        check(not entitlements.get(key), f"Unexpected entitlement: {key}")
    if not isinstance(profile, dict):
        return Result(errors + ["Embedded provisioning profile is missing"])
    check(profile.get("TeamIdentifier") == [team], "Profile team mismatch")
    check("OSX" in profile.get("Platform", []), "Profile must authorize macOS")

    def utc(value):
        return value.replace(tzinfo=dt.timezone.utc) if isinstance(value, dt.datetime) and value.tzinfo is None else value

    expiry, creation = utc(profile.get("ExpirationDate")), utc(profile.get("CreationDate"))
    check(isinstance(expiry, dt.datetime) and expiry > now, "Profile is expired or has no expiry")
    check(isinstance(creation, dt.datetime) and creation <= now, "Profile creation date is invalid")
    if environment == "Production":
        check(profile.get("ProvisionsAllDevices") is True, "Production requires a Developer ID all-device profile")
    else:
        check(bool(profile.get("ProvisionedDevices")), "Development requires a device-provisioned profile")
    certificates = [hashlib.sha256(x).hexdigest() for x in profile.get("DeveloperCertificates", []) if isinstance(x, bytes)]
    check(signature.get("certificate_sha256") in certificates, "Signing certificate is not authorized by the profile")
    allowed = profile.get("Entitlements", {})

    def permits(pattern, value):
        return isinstance(pattern, str) and (pattern == value or (pattern.endswith("*") and value.startswith(pattern[:-1])))

    for key, value in expected.items():
        values = value if isinstance(value, list) else [value]
        authorization = allowed.get(key, [])
        authorization = authorization if isinstance(authorization, list) else [authorization]
        check(all(any(permits(pattern, item) for pattern in authorization) for item in values), f"Profile does not authorize: {key}")
    return Result(errors)


def run(*arguments):
    return subprocess.run(arguments, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def inspect(app):
    """Read actual Apple CMS/signatures; no certificate/profile bytes are logged."""
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    profile_path = app / "Contents/embedded.provisionprofile"
    profile = plistlib.loads(run("security", "cms", "-D", "-i", str(profile_path)).stdout) if profile_path.is_file() else None
    run("codesign", "--verify", "--deep", "--strict", str(app))
    details = run("codesign", "-d", "--verbose=4", str(app)).stderr.decode()
    entitlement_bytes = run("codesign", "-d", "--entitlements", "-", "--xml", str(app)).stdout
    entitlements = plistlib.loads(entitlement_bytes) if entitlement_bytes.strip() else {}
    scratch = pathlib.Path(tempfile.gettempdir()) / "opencode"
    with tempfile.TemporaryDirectory(prefix="cloud-signature-", dir=scratch if scratch.is_dir() else None) as directory:
        prefix = pathlib.Path(directory) / "cert"
        run("codesign", "-d", f"--extract-certificates={prefix}", str(app))
        leaf = pathlib.Path(str(prefix) + "0")
        fingerprint = hashlib.sha256(leaf.read_bytes()).hexdigest() if leaf.exists() else ""

    def field(name):
        match = re.search(rf"^{re.escape(name)}=(.*)$", details, re.MULTILINE)
        return match[1] if match else None

    signature = {"verified": True, "adhoc": field("Signature") == "adhoc", "team": field("TeamIdentifier"),
                 "identifier": field("Identifier"), "runtime": bool(re.search(r"flags=.*\bruntime\b", details)),
                 "timestamp": field("Timestamp") not in (None, "none"),
                 "authorities": re.findall(r"^Authority=(.*)$", details, re.MULTILINE), "certificate_sha256": fingerprint}
    return info, profile, entitlements, signature


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--environment", required=True, choices=["Production", "Development"])
    parser.add_argument("--team", required=True)
    parser.add_argument("--container", required=True)
    parser.add_argument("--bundle", default="com.linda.CodexPlusBar")
    arguments = parser.parse_args()
    try:
        info, profile, entitlements, signature = inspect(arguments.app.resolve())
        result = validate(profile, entitlements, signature, bundle=arguments.bundle, team=arguments.team,
                          container=arguments.container, environment=arguments.environment, now=dt.datetime.now(dt.timezone.utc))
        if info.get("CFBundleIdentifier") != arguments.bundle:
            result.errors.append("Info.plist bundle ID mismatch")
        for error in result.errors:
            print(f"FAIL: {error}")
        if not result.errors:
            print(f"PASS: {arguments.environment} profile, signature, CloudKit, APNs and Keychain authorization")
        return result.exit_code
    except (OSError, ValueError, TypeError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        # No raw CMS/certificate output or credentials in diagnostics.
        print(f"FAIL: artifact inspection failed ({type(error).__name__})")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
