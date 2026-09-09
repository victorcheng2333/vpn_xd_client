#!/usr/bin/env python3
"""Verify the Windows runner's release record before unified publication."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from version import metadata


def check(path):
    path = Path(path)
    info = metadata('release', os.environ.get('BUILD_NUMBER'), os.environ.get('RELEASE_TAG'))
    name = f'XD-VPN-{info["version"]}-Windows-x64.exe'
    if path.name != name:
        raise ValueError('Unexpected Windows installer filename.')
    record = json.loads(path.with_name('windows-release.json').read_text(encoding='utf-8-sig'))
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    if (record.get('tag') != info['tag'] or record.get('version') != info['version']
            or str(record.get('build')) != info['build'] or record.get('revision') != revision):
        raise ValueError('Windows package version, build or source revision does not match this release.')
    assets = [asset for asset in record.get('assets', []) if asset.get('name') == name]
    if len(assets) != 1:
        raise ValueError('Expected exactly one Windows installer in the build record.')
    content = path.read_bytes()
    if not content.startswith(b'MZ') or len(content) != assets[0].get('size'):
        raise ValueError('Invalid or truncated Windows installer.')
    if hashlib.sha256(content).hexdigest() != assets[0].get('sha256'):
        raise ValueError('Windows installer differs from the verified Windows build.')
    return record


if __name__ == '__main__':
    try:
        check(sys.argv[1])
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
