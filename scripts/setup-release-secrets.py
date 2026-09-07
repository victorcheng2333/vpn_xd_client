#!/usr/bin/env python3
"""Configure release secrets without printing credentials or writing private keys to disk."""
import argparse
import base64
import getpass
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = 'victorcheng2333/vpn_xd_client'
TEAM = 'KQY8A3BNVG'
IDENTITY = f'Developer ID Application: Tools UG ({TEAM})'


def run(args, **kwargs):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        # Arguments/output may contain secrets; do not include either in errors.
        raise RuntimeError(f'{Path(args[0]).name} failed (exit {result.returncode}).')
    return result.stdout


def set_secret(name, value):
    run(['gh', 'secret', 'set', name, '--repo', REPOSITORY], input=value)
    print(f'Configured {name}', flush=True)


def signing():
    identities = run(['security', 'find-identity', '-v', '-p', 'codesigning']).decode()
    matches = re.findall(r'([A-F0-9]{40}) "' + re.escape(IDENTITY) + r'"', identities)
    if len(matches) != 1:
        raise RuntimeError('Expected exactly one company Developer ID Application identity.')
    password = secrets.token_urlsafe(48).encode()
    cache = ROOT / '.build' / 'release-secret-setup'
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='xdvpn-export-') as work:
        executable = str(Path(work) / 'export-identity')
        run(['xcrun', 'swiftc', '-module-cache-path', str(cache),
             str(ROOT / 'scripts/export-signing-identity.swift'), '-o', executable])
        print('Exporting only the company Developer ID; approve the macOS keychain prompt if shown.', flush=True)
        p12 = run([executable, matches[0]], input=password + b'\n')
    # Verify the PKCS#12 MAC/password via separate pipes, without writing either to disk.
    read_fd, write_fd = os.pipe()
    try:
        os.write(write_fd, password + b'\n')
        os.close(write_fd)
        run(['/usr/bin/openssl', 'pkcs12', '-info', '-noout', '-passin', f'fd:{read_fd}'],
            input=p12, pass_fds=(read_fd,))
    finally:
        os.close(read_fd)
    set_secret('APPLE_CERTIFICATE_PASSWORD', password)
    set_secret('APPLE_CERTIFICATE_P12', base64.b64encode(p12))
    set_secret('APPLE_SIGNING_IDENTITY', IDENTITY.encode())
    set_secret('APPLE_TEAM_ID', TEAM.encode())
    print('Company signing secrets configured; no private-key files retained.', flush=True)


def notarization():
    if not sys.stdin.isatty():
        raise RuntimeError('Run --part notarization in a local terminal for hidden password input.')
    print(f'GitHub repository: {REPOSITORY}\nCompany team: {TEAM}')
    print('This will validate with Apple, save a local notarytool profile, and upload the App-specific password')
    print(f'to {REPOSITORY} Actions Secrets (APPLE_APP_PASSWORD) for release notarization.')
    print('Use an Apple App-specific password, not your main Apple account password.')
    account = input('Apple ID: ').strip()
    if not account:
        raise RuntimeError('Apple ID is required.')
    password = getpass.getpass('Apple App-specific password (hidden): ').strip()
    if not re.fullmatch(r'[A-Za-z0-9]{4}(?:-[A-Za-z0-9]{4}){3}', password):
        raise RuntimeError('Expected an Apple App-specific password in xxxx-xxxx-xxxx-xxxx format.')
    print('Validating with Apple and saving the xdvpn-notary keychain profile…', flush=True)
    # notarytool is Apple's supported credential validation interface. Its output
    # is captured and never echoed; only the app-specific password is supplied.
    run(['xcrun', 'notarytool', 'store-credentials', 'xdvpn-notary', '--apple-id', account,
         '--team-id', TEAM, '--password', password])
    set_secret('APPLE_ID', account.encode())
    set_secret('APPLE_APP_PASSWORD', password.encode())
    print('Apple validation succeeded; notarization secrets configured.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--part', choices=['metadata', 'signing', 'notarization', 'all'], default='all')
    args = parser.parse_args()
    if shutil.which('gh') is None:
        raise RuntimeError('GitHub CLI is required.')
    run(['gh', 'api', f'repos/{REPOSITORY}/actions/secrets/public-key'])
    if args.part == 'metadata':
        set_secret('APPLE_SIGNING_IDENTITY', IDENTITY.encode())
        set_secret('APPLE_TEAM_ID', TEAM.encode())
    if args.part in ('signing', 'all'):
        signing()
    if args.part in ('notarization', 'all'):
        notarization()
    print('Configured names:')
    print(run(['gh', 'secret', 'list', '--repo', REPOSITORY]).decode(), end='')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, KeyboardInterrupt, EOFError) as error:
        print(str(error) or 'Cancelled.', file=sys.stderr)
        sys.exit(1)
