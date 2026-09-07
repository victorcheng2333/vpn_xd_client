#!/usr/bin/env python3
"""Verify notarization, company signing, architecture and embedded release identity."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
from version import metadata


def output(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT)


def verify(dmg, data, revision):
    arch = 'arm64' if dmg.name.endswith('-arm64.dmg') else 'x86_64'
    if dmg.name != f'XD-VPN-{data["version"]}-macOS-{arch}.dmg':
        raise ValueError('Unexpected release DMG name.')
    output('codesign', '--verify', '--strict', str(dmg))
    output('xcrun', 'stapler', 'validate', str(dmg))
    details = output('codesign', '-d', '--verbose=4', str(dmg)).decode()
    team = os.environ.get('APPLE_TEAM_ID', 'KQY8A3BNVG')
    if 'Authority=Developer ID Application:' not in details or f'TeamIdentifier={team}\n' not in details:
        raise ValueError('Release DMG must be signed by the company Developer ID.')
    with tempfile.TemporaryDirectory(prefix='xdvpn-release-verify-') as temporary:
        mount = Path(temporary) / 'volume'
        mount.mkdir()
        output('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(dmg.resolve()))
        try:
            app = mount / 'XD VPN.app'
            with (app / 'Contents/Info.plist').open('rb') as stream:
                info = plistlib.load(stream)
            expected = dict(CFBundleIdentifier='com.xd.vpn', CFBundleShortVersionString=data['version'],
                            CFBundleVersion=data['build'], XDVPNBuildChannel='release',
                            XDVPNSourceRevision=revision, XDVPNReleaseRepository=data['repository'])
            if any(info.get(key) != value for key, value in expected.items()):
                raise ValueError('DMG contains a different version, channel, source revision or repository.')
            output('xcrun', 'stapler', 'validate', str(app))
            output('codesign', '--verify', '--deep', '--strict', str(app))
            for executable in ('MacOS/XDVPN', 'Helpers/XDVPNHelper', 'Resources/OpenConnect/openconnect'):
                file = app / 'Contents' / executable
                if output('lipo', '-archs', str(file)).decode().strip() != arch:
                    raise ValueError('Release architecture mismatch.')
                details = output('codesign', '-d', '--verbose=4', str(file)).decode()
                if ('Authority=Developer ID Application:' not in details or f'TeamIdentifier={team}\n' not in details
                        or 'runtime' not in details or 'Timestamp=' not in details):
                    raise ValueError('Release executables require company signing, hardened runtime and timestamp.')
        finally:
            output('hdiutil', 'detach', str(mount))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dmg', type=Path)
    args = parser.parse_args()
    data = metadata('release', os.environ.get('BUILD_NUMBER'), os.environ.get('RELEASE_TAG'))
    revision = output('git', 'rev-parse', 'HEAD').decode().strip()
    verify(args.dmg, data, revision)
    print(f'Verified signed and notarized release: {args.dmg.name}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
