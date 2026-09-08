import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "scripts/testflight.py"
spec = importlib.util.spec_from_file_location("testflight", MODULE)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class TestFlightTests(unittest.TestCase):
    def test_version_and_build_inputs_cannot_be_shell_or_paths(self):
        for version in ["1.0", "../1.0.0", "01.0.0", "1x0x0", "1.0.0;false", "$(id)", "1.0.0\n"]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                release.release_values(version, "1")
        for build in ["0", "01", "10000", "1.2", "-1", "$(id)", "../1", "1\n"]:
            with self.subTest(build=build), self.assertRaises(ValueError):
                release.release_values("0.1.0", build)
        self.assertEqual(release.release_values("0.1.0", "9999"), ("0.1.0", "9999"))

    def test_external_upload_does_not_restrict_build_to_internal(self):
        options = release.export_options(release.configuration(), "external")
        self.assertEqual(options["destination"], "upload")
        self.assertEqual(options["method"], "app-store-connect")
        self.assertFalse(options["testFlightInternalTestingOnly"])
        self.assertFalse(options["manageAppVersionAndBuildNumber"])
        self.assertTrue(options["uploadSymbols"])

    def test_internal_upload_cannot_be_used_for_app_store(self):
        self.assertTrue(release.export_options(release.configuration(), "internal")["testFlightInternalTestingOnly"])

    def test_unknown_audience_is_rejected(self):
        with self.assertRaises(ValueError):
            release.export_options(release.configuration(), "store")

    def test_ci_cannot_fall_back_to_personal_xcode_login(self):
        with patch.dict(os.environ, {"CI": "true"}, clear=True), self.assertRaises(ValueError):
            release.authentication()

    def test_incomplete_credentials_fail_closed(self):
        with patch.dict(os.environ, {"ASC_KEY_ID": "ABCDEFGHIJ"}, clear=True), self.assertRaises(ValueError):
            release.authentication()

    def test_local_xcode_account_is_supported(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(release.authentication(), [])

    def make_archive(self, root):
        config = release.configuration()
        def write(path, value):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(plistlib.dumps(value))
        write(root / "Info.plist", {"ApplicationProperties": {"Team": config["team_id"]}})
        app = root / "Products/Applications/XDVPN.app"
        for bundle, identifier in [(app, config["bundle_id"]),
                                   (app / "PlugIns/PacketTunnel.appex", config["bundle_id"] + ".PacketTunnel")]:
            write(bundle / "Info.plist", {"CFBundleIdentifier": identifier, "CFBundleExecutable": "executable",
                  "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
                  "SharedAppGroup": config["app_group"]})
            write(bundle / "PrivacyInfo.xcprivacy", {"NSPrivacyAccessedAPITypes": [
                {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime"}]})
            (bundle / "executable").write_bytes(b"test release binary")
        return app, config

    def test_app_and_extension_must_have_matching_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, config = self.make_archive(root)
            self.assertEqual(len(release.verify_archive(root, config, "0.1.0", "1")), 2)
            info_path = app / "PlugIns/PacketTunnel.appex/Info.plist"
            info = release.read_plist(info_path)
            info["CFBundleVersion"] = "2"
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError):
                release.verify_archive(root, config, "0.1.0", "1")

    def test_wrong_team_or_bundle_is_not_uploaded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, config = self.make_archive(root)
            with self.assertRaises(ValueError):
                release.verify_archive(root, {**config, "team_id": "WRONGTEAM1"}, "0.1.0", "1")
            with self.assertRaises(ValueError):
                release.verify_archive(root, {**config, "bundle_id": "com.other.app"}, "0.1.0", "1")

    def test_debug_entry_points_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, config = self.make_archive(root)
            (app / "executable").write_bytes(b"--debug-connect-saved-vpn")
            with self.assertRaises(ValueError):
                release.verify_archive(root, config, "0.1.0", "1")

    def test_cannot_silently_claim_no_nonexempt_encryption(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, config = self.make_archive(root)
            info_path = app / "Info.plist"
            info = release.read_plist(info_path)
            info["ITSAppUsesNonExemptEncryption"] = False
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError):
                release.verify_archive(root, config, "0.1.0", "1")

    def test_missing_privacy_declaration_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, config = self.make_archive(root)
            (app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({}))
            with self.assertRaises(ValueError):
                release.verify_archive(root, config, "0.1.0", "1")


if __name__ == "__main__":
    unittest.main()
