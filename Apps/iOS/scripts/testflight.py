#!/usr/bin/env python3
"""Archive and upload XD VPN to TestFlight. Never submits an App Store version."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

IOS = Path(__file__).resolve().parent.parent
ROOT = IOS.parent.parent
CONFIG = IOS / "Configuration/TestFlight.json"


def release_values(version, build):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Version must contain three canonical integers, for example 0.1.0.")
    if not re.fullmatch(r"[1-9][0-9]{0,3}", build):
        raise ValueError("Build must be an integer from 1 to 9999; use a new number for each upload.")
    return version, build


def configuration():
    data = json.loads(CONFIG.read_text())
    patterns = {"app_id": r"[0-9]+", "team_id": r"[A-Z0-9]{10}",
                "bundle_id": r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+",
                "app_group": r"group\.[A-Za-z0-9.-]+"}
    for key, pattern in patterns.items():
        if not isinstance(data.get(key), str) or not re.fullmatch(pattern, data[key]):
            raise ValueError(f"Invalid TestFlight configuration: {key}")
    return data


def authentication():
    names = ("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID")
    values = [os.environ.get(name, "") for name in names]
    if not any(values):
        if os.environ.get("CI"):
            raise ValueError("CI requires ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID.")
        return []  # Existing Xcode account on the developer's Mac.
    if not all(values):
        raise ValueError("Provide all three ASC API key settings, or use the local Xcode account.")
    path, key_id, issuer = values
    if not Path(path).is_file():
        raise ValueError("ASC_KEY_PATH does not point to a private key file.")
    if not re.fullmatch(r"[A-Z0-9]{10}", key_id) or not re.fullmatch(r"[0-9a-fA-F-]{36}", issuer):
        raise ValueError("Invalid ASC key ID or issuer ID.")
    return ["-authenticationKeyPath", str(Path(path).resolve()),
            "-authenticationKeyID", key_id, "-authenticationKeyIssuerID", issuer]


def export_options(config, audience):
    if audience not in ("internal", "external"):
        raise ValueError("Unknown TestFlight audience.")
    return {"method": "app-store-connect", "destination": "upload",
            "teamID": config["team_id"], "signingStyle": "automatic",
            "manageAppVersionAndBuildNumber": False, "uploadSymbols": True,
            "testFlightInternalTestingOnly": audience == "internal"}


def read_plist(path):
    with Path(path).open("rb") as stream:
        return plistlib.load(stream)


def verify_archive(archive, config, version, build):
    metadata = read_plist(archive / "Info.plist").get("ApplicationProperties", {})
    if metadata.get("Team") != config["team_id"]:
        raise ValueError("Archive signing team does not match TestFlight configuration.")
    app = archive / "Products/Applications/XDVPN.app"
    bundles = [(app, config["bundle_id"]),
               (app / "PlugIns/PacketTunnel.appex", config["bundle_id"] + ".PacketTunnel")]
    summary = []
    for bundle, identifier in bundles:
        info = read_plist(bundle / "Info.plist")
        expected = {"CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                    "CFBundleVersion": build, "SharedAppGroup": config["app_group"]}
        for key, value in expected.items():
            if info.get(key) != value:
                raise ValueError(f"{bundle.name}: {key} does not match the requested release.")
        if "ITSAppUsesNonExemptEncryption" in info:
            raise ValueError(f"{bundle.name}: keep encryption keys out of the archive; the pipeline applies the confirmed declaration after upload.")
        privacy = read_plist(bundle / "PrivacyInfo.xcprivacy")
        categories = {entry["NSPrivacyAccessedAPIType"] for entry in privacy.get("NSPrivacyAccessedAPITypes", [])}
        if "NSPrivacyAccessedAPICategorySystemBootTime" not in categories:
            raise ValueError(f"{bundle.name}: missing timer API privacy declaration.")
        executable = bundle / info["CFBundleExecutable"]
        binary = executable.read_bytes()
        if b"--debug-connect-saved-vpn" in binary or b"--preview-quality" in binary:
            raise ValueError(f"{bundle.name}: debug-only entry points found in the release binary.")
        summary.append({"bundle_id": identifier, "sha256": hashlib.sha256(binary).hexdigest()})
    return summary


def verify_signatures(archive):
    app = archive / "Products/Applications/XDVPN.app"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def run_logged(command, log):
    print(f"Running {command[0]} {command[1]} (log: {log})", flush=True)
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        # Full Xcode distribution logs stay local; they may contain account metadata.
        raise RuntimeError(f"Xcode failed with exit {result.returncode}. Inspect {log}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "archive", "verify", "upload"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--audience", choices=("external", "internal"), default="external")
    args = parser.parse_args()
    version, build = release_values(args.version, args.build)
    config = configuration()
    output = IOS / ".build/testflight" / f"{version}-{build}"
    archive = output / "XDVPN.xcarchive"
    if args.action == "check":
        print(json.dumps({"version": version, "build": build, "audience": args.audience,
                          "app_id": config["app_id"], "bundle_id": config["bundle_id"]}, indent=2))
        return
    output.mkdir(parents=True, exist_ok=True)
    if args.action == "archive":
        dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True)
        if dirty.strip():
            raise ValueError("Commit the release changes before creating a distributable archive.")
        auth = authentication()
        if archive.exists():
            raise ValueError(f"Archive already exists: {archive}. Use a new build number or move this archive aside.")
        subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", str(IOS / "Tests"), "-p", "test_*.py"], cwd=ROOT, check=True)
        subprocess.run(["bash", str(IOS / "scripts/test.sh")], cwd=ROOT, check=True)
        command = ["xcodebuild", "-project", str(IOS / "XDVPN.xcodeproj"), "-scheme", "XDVPN-iOS",
                   "-configuration", "Release", "-sdk", "iphoneos", "-destination", "generic/platform=iOS",
                   "-archivePath", str(archive), "-derivedDataPath", str(IOS / ".build/xcode-testflight"),
                   "-allowProvisioningUpdates", *auth, "CODE_SIGN_STYLE=Automatic",
                   f"DEVELOPMENT_TEAM={config['team_id']}", f"XDVPN_BUNDLE_ID={config['bundle_id']}",
                   f"XDVPN_APP_GROUP={config['app_group']}", f"MARKETING_VERSION={version}",
                   f"CURRENT_PROJECT_VERSION={build}", "archive"]
        run_logged(command, output / "archive.log")
    bundles = verify_archive(archive, config, version, build)
    verify_signatures(archive)
    if args.action == "archive":
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        manifest = {"source_commit": sha, "version": version, "build": build,
                    "app_id": config["app_id"], "bundles": bundles}
        (output / "archive.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if args.action == "upload":
        manifest = json.loads((output / "archive.json").read_text())
        if manifest.get("bundles") != bundles or manifest.get("app_id") != config["app_id"]:
            raise ValueError("Archive changed after verification, or belongs to another app.")
        if (output / "uploaded.json").exists():
            raise ValueError("This archive was already uploaded. Check TestFlight before submitting another build.")
        options = output / "ExportOptions.plist"
        options.write_bytes(plistlib.dumps(export_options(config, args.audience)))
        run_logged(["xcodebuild", "-exportArchive", "-archivePath", str(archive),
                    "-exportOptionsPlist", str(options), "-exportPath", str(output / "upload"),
                    "-allowProvisioningUpdates", *authentication()], output / "upload.log")
        receipt = {**manifest, "audience": args.audience, "upload": "accepted",
                   "testflight_processing": "pending",
                   "app_store_submission": False}
        (output / "uploaded.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print("Upload accepted. Confirm processing, encryption compliance and Beta Review in TestFlight.")
    else:
        print(f"Verified Release {version} ({build}) for App Store Connect App {config['app_id']}.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
