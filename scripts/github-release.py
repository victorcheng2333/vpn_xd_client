#!/usr/bin/env python3
"""Validate and publish a complete GitHub release; never overwrite a published version."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import sys
from version import metadata, SEMVER


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True).strip()


def releases(repo):
    pages = json.loads(gh('api', '--paginate', '--slurp', f'repos/{repo}/releases?per_page=100'))
    return [item for page in pages for item in page]


def validate(repo, data):
    current = tuple(map(int, data['version'].split('.')))
    existing = None
    for release in releases(repo):
        if release['tag_name'] == data['tag']:
            if not release['draft']:
                raise ValueError('This version is already published. Use a new version; published assets cannot be replaced.')
            existing = release
        name = release['tag_name'].removeprefix('v')
        if not release['draft'] and not release['prerelease'] and SEMVER.fullmatch(name):
            if tuple(map(int, name.split('.'))) >= current:
                raise ValueError('Release version must be greater than every published stable version.')
    return existing


def asset_names(version):
    """macOS, Android and Windows installers; the macOS client matches its DMG by exact name."""
    return [f'XD-VPN-{version}-macOS-{arch}.dmg' for arch in ('arm64', 'x86_64')] + [f'XD-VPN-{version}-Android.apk', f'XD-VPN-{version}-Windows-x64.exe']


def verify_delivery(files):
    root = Path(__file__).resolve().parent
    subprocess.run([sys.executable, str(root / 'version.py'), '--channel', 'release', '--check-git'], check=True)
    for file in files:
        if file.suffix == '.dmg':
            subprocess.run([sys.executable, str(root / 'verify-release-dmg.py'), str(file)], check=True)
        elif file.suffix == '.exe':
            subprocess.run([sys.executable, str(root / 'verify-release-windows.py'), str(file)], check=True)
        elif file.suffix == '.apk':
            subprocess.run([sys.executable, str(root / 'verify-release-apk.py'), str(file)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['check', 'publish'])
    args = parser.parse_args()
    data = metadata('release', os.environ.get('BUILD_NUMBER'), os.environ.get('RELEASE_TAG'))
    repo = data['repository']
    existing = validate(repo, data)
    if args.command == 'check':
        print(json.dumps(data)); return
    root = Path('build')
    names = asset_names(data['version'])
    files = [root / name for name in names]
    # Checksums remain local build inputs; only installers appear in Releases.
    required = files + [root / (name + '.sha256') for name in names]
    if any(not file.is_file() or file.stat().st_size == 0 for file in required):
        raise ValueError('Both architecture DMGs, the Android APK, the Windows installer and their local checksums are required.')
    for name in names:
        expected = f'{hashlib.sha256((root / name).read_bytes()).hexdigest()}  {name}\n'
        if (root / (name + '.sha256')).read_text() != expected:
            raise ValueError(f'Checksum mismatch: {name}')
    verify_delivery(files)
    if not existing:
        # When a separate distribution repository is used, create its tag at its default branch.
        options = ['--verify-tag'] if repo == os.environ.get('GITHUB_REPOSITORY', repo) else []
        gh('release', 'create', data['tag'], '--repo', repo, '--draft', '--title', f'XD VPN {data["version"]}',
           '--notes-file', 'build/release-notes.md', *options)
    gh('release', 'upload', data['tag'], '--repo', repo, '--clobber', *map(str, files))
    # A draft from a failed attempt can be resumed, but cannot leak stale/extra assets.
    for attempt in range(12):
        release = next(item for item in releases(repo) if item['tag_name'] == data['tag'])
        if not release['draft']:
            raise ValueError('Release was published by another actor during upload.')
        assets = {item['name']: item for item in release['assets']}
        if set(assets) != set(names):
            raise ValueError('Draft contains unexpected assets; remove them before retrying.')
        if all(assets[file.name].get('digest') == 'sha256:' + hashlib.sha256(file.read_bytes()).hexdigest()
               and assets[file.name]['size'] == file.stat().st_size for file in files):
            break
        time.sleep(5)
    else:
        raise ValueError('GitHub asset SHA-256 verification failed; release remains a draft.')
    validate(repo, data)
    gh('release', 'edit', data['tag'], '--repo', repo, '--draft=false', '--prerelease=false', '--latest',
       '--notes-file', 'build/release-notes.md')
    print(gh('release', 'view', data['tag'], '--repo', repo, '--json', 'url', '--jq', '.url'))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
