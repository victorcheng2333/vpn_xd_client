#!/usr/bin/env python3
"""Verify a staged Android release APK without the Android SDK: name, embedded version, signature block, native libraries."""
import json
import os
from pathlib import Path
import subprocess
import sys
import zipfile
from version import metadata

ROOT = Path(__file__).resolve().parent.parent


def check(path):
    apk = Path(path)
    data = metadata('release', os.environ.get('BUILD_NUMBER'), os.environ.get('RELEASE_TAG'))
    expected = f'XD-VPN-{data["version"]}-Android.apk'
    if apk.name != expected:
        raise ValueError(f'Expected {expected}, got {apk.name}')
    with zipfile.ZipFile(apk) as archive:
        info = json.loads(archive.read('assets/xdvpn-version.json'))
    if (info.get('channel'), info.get('version'), str(info.get('build')), info.get('displayVersion')) != \
            ('release', data['version'], data['build'], data['version']):
        raise ValueError(f'APK version metadata does not match the release: {info}')
    if info.get('signing') not in ('configured', 'development'):
        raise ValueError('APK was built without a signing configuration.')
    # The APK Signature Scheme v2/v3 block precedes the central directory and ends with this magic.
    if b'APK Sig Block 42' not in apk.read_bytes():
        raise ValueError('APK has no v2/v3 signature block.')
    return info


def main():
    info = check(sys.argv[1])
    subprocess.run([sys.executable, str(ROOT / 'Apps/Android/scripts/verify-apk.py'), sys.argv[1]], check=True, stdout=subprocess.DEVNULL)
    if info['signing'] == 'development':
        print('NOTICE: signed with the development keystore; devices carrying earlier test builds upgrade in place.')
    print(f'Verified {Path(sys.argv[1]).name}: {info["version"]} (build {info["build"]}), signing={info["signing"]}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, FileNotFoundError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
