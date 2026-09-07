#!/usr/bin/env python3
"""Single version/channel contract shared by local builds and GitHub Actions."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", re.ASCII)
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", re.ASCII)


def metadata(channel, build=None, tag=None):
    with (ROOT / 'Resources/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    version = info['CFBundleShortVersionString']
    if not SEMVER.fullmatch(version):
        raise ValueError('Version must be canonical MAJOR.MINOR.PATCH (no leading zeros).')
    if channel not in ('development', 'test', 'release'):
        raise ValueError('Invalid build channel')
    if channel == 'test' and not build:
        raise ValueError('Test builds require an explicit BUILD_NUMBER.')
    build = build or info['CFBundleVersion']
    if not re.fullmatch(r'[1-9][0-9]{0,8}', build, re.ASCII):
        raise ValueError('BUILD_NUMBER must be a positive integer of at most 9 digits.')
    if channel == 'release':
        if tag != f'v{version}':
            raise ValueError(f'Release requires RELEASE_TAG=v{version}, matching Resources/Info.plist.')
        if build != info['CFBundleVersion']:
            raise ValueError('Release BUILD_NUMBER must match Resources/Info.plist.')
    suffix = '' if channel == 'release' else f'-{"dev" if channel == "development" else "test"}.{build}'
    repository = os.environ.get('RELEASE_REPOSITORY', 'victorcheng2333/vpn_xd_client')
    if not REPO.fullmatch(repository) or any(part in ('.', '..') for part in repository.split('/')):
        raise ValueError('RELEASE_REPOSITORY must be owner/repository.')
    return dict(version=version, build=build, channel=channel, displayVersion=version + suffix,
                tag=f'v{version}', repository=repository)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--channel', default=os.environ.get('BUILD_CHANNEL', 'development'))
    parser.add_argument('--build', default=os.environ.get('BUILD_NUMBER'))
    parser.add_argument('--tag', default=os.environ.get('RELEASE_TAG'))
    parser.add_argument('--field')
    parser.add_argument('--write-plist', type=Path)
    parser.add_argument('--check-git', action='store_true')
    args = parser.parse_args()
    try:
        data = metadata(args.channel, args.build, args.tag)
        if args.check_git:
            def git(*values):
                return subprocess.check_output(['git', *values], cwd=ROOT, text=True).strip()
            if git('status', '--porcelain', '--untracked-files=normal'):
                raise ValueError('Release requires a clean working tree.')
            if git('rev-parse', 'HEAD') != git('rev-parse', f'{data["tag"]}^{{commit}}'):
                raise ValueError('Release tag must point to HEAD.')
        if args.write_plist:
            with args.write_plist.open('rb') as file:
                info = plistlib.load(file)
            info.update(CFBundleVersion=data['build'], XDVPNBuildChannel=data['channel'],
                        XDVPNDisplayVersion=data['displayVersion'], XDVPNReleaseRepository=data['repository'])
            with args.write_plist.open('wb') as file:
                plistlib.dump(info, file)
        print(data[args.field] if args.field else json.dumps(data))
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
