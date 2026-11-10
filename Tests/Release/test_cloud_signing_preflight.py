import copy
import datetime as dt
import hashlib
import importlib.util
import pathlib
import sys
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "scripts/cloud_signing_preflight.py"
spec = importlib.util.spec_from_file_location("cloud_signing_preflight", SCRIPT)
preflight = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = preflight
spec.loader.exec_module(preflight)


class CloudSigningPreflightTests(unittest.TestCase):
    def setUp(self):
        self.now = dt.datetime(2026, 11, 10, tzinfo=dt.timezone.utc)
        self.team = "SYNTHETIC1"
        self.bundle = "com.example.Sync"
        self.container = "iCloud.com.example.Sync"
        self.cert = b"synthetic certificate bytes, never a real identity"
        self.entitlements = {
            "com.apple.application-identifier": f"{self.team}.{self.bundle}",
            "com.apple.developer.team-identifier": self.team,
            "com.apple.developer.icloud-container-identifiers": [self.container],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-environment": "Production",
            "com.apple.developer.aps-environment": "production",
            "keychain-access-groups": [f"{self.team}.{self.bundle}"],
        }
        allowed = copy.deepcopy(self.entitlements)
        allowed["keychain-access-groups"] = [f"{self.team}.*"]
        allowed["com.apple.developer.icloud-services"] = ["*"]
        self.profile = {
            "ExpirationDate": self.now + dt.timedelta(days=365),
            "CreationDate": self.now - dt.timedelta(days=1),
            "TeamIdentifier": [self.team], "Platform": ["OSX"],
            "ProvisionsAllDevices": True, "DeveloperCertificates": [self.cert],
            "Entitlements": allowed,
        }
        self.signature = {
            "verified": True, "adhoc": False, "team": self.team,
            "identifier": self.bundle, "runtime": True, "timestamp": True,
            "authorities": ["Developer ID Application: Synthetic"],
            "certificate_sha256": hashlib.sha256(self.cert).hexdigest(),
        }

    def validate(self, environment="Production"):
        return preflight.validate(self.profile, self.entitlements, self.signature,
                                  bundle=self.bundle, team=self.team, container=self.container,
                                  environment=environment, now=self.now)

    def test_matching_developer_id_and_development(self):
        self.assertEqual(self.validate().exit_code, 0)
        self.entitlements["com.apple.developer.icloud-container-environment"] = "Development"
        self.entitlements["com.apple.developer.aps-environment"] = "development"
        self.profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = ["Development", "Production"]
        self.profile["Entitlements"]["com.apple.developer.aps-environment"] = "development"
        self.profile.pop("ProvisionsAllDevices")
        self.profile["ProvisionedDevices"] = ["synthetic-device"]
        self.signature["authorities"] = ["Apple Development: Synthetic"]
        self.assertEqual(self.validate("Development").exit_code, 0)

    def test_missing_expired_future_wrong_team_or_wrong_platform_profile(self):
        original = copy.deepcopy(self.profile)
        mutations = [None, {"ExpirationDate": self.now}, {"CreationDate": self.now + dt.timedelta(days=1)},
                     {"TeamIdentifier": ["OTHER"]}, {"Platform": ["iOS"]}, {"ProvisionsAllDevices": False},
                     {"DeveloperCertificates": [b"different certificate"]}, {"Entitlements": {}}]
        for update in mutations:
            with self.subTest(update=update):
                self.profile = None if update is None else {**original, **update}
                self.assertNotEqual(self.validate().exit_code, 0)

    def test_rejects_bad_signature(self):
        original = copy.deepcopy(self.signature)
        for key, value in [("verified", False), ("adhoc", True), ("team", "OTHER"), ("identifier", "wrong"),
                           ("runtime", False), ("timestamp", False), ("certificate_sha256", "wrong"),
                           ("authorities", ["Apple Development: Synthetic"])]:
            with self.subTest(key=key):
                self.signature = {**original, key: value}
                self.assertNotEqual(self.validate().exit_code, 0)

    def test_rejects_missing_or_unauthorized_cloud_entitlement(self):
        original = copy.deepcopy(self.entitlements)
        for key in original:
            with self.subTest(key=key):
                self.entitlements = {k: v for k, v in original.items() if k != key}
                self.assertNotEqual(self.validate().exit_code, 0)
        for key, value in [("com.apple.developer.icloud-container-environment", "Development"),
                           ("com.apple.developer.aps-environment", "development"),
                           ("com.apple.developer.icloud-container-identifiers", ["iCloud.wrong"]),
                           ("keychain-access-groups", [f"{self.team}.foreign"]),
                           ("com.apple.application-identifier", f"{self.team}.wrong")]:
            with self.subTest(key=key, value=value):
                self.entitlements = {**original, key: value}
                self.assertNotEqual(self.validate().exit_code, 0)
        self.entitlements = original
        self.profile["Entitlements"]["keychain-access-groups"] = ["OTHER.*"]
        self.assertNotEqual(self.validate().exit_code, 0)

    def test_rejects_debugger_or_sandbox(self):
        for key in ["get-task-allow", "com.apple.security.get-task-allow", "com.apple.security.app-sandbox"]:
            with self.subTest(key=key):
                self.entitlements[key] = True
                self.assertNotEqual(self.validate().exit_code, 0)
                del self.entitlements[key]


if __name__ == "__main__":
    unittest.main()
