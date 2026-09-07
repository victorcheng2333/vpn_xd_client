import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CISigningTests(unittest.TestCase):
    def invoke(self, notarize, credentials=False):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            binary = work / 'bin'
            binary.mkdir()
            for name in ('security', 'xcrun', 'openssl'):
                path = binary / name
                path.write_text('#!/bin/bash\nprintf "%s\\n" "$(basename "$0"):$1" >> "$TEST_CALLS"\n'
                                'if [ "$(basename "$0")" = openssl ]; then echo fake-keychain-password; fi\n')
                path.chmod(0o755)
            environment = {
                'PATH': f'{binary}:/usr/bin:/bin', 'RUNNER_TEMP': str(work),
                'GITHUB_ENV': str(work / 'environment'), 'TEST_CALLS': str(work / 'calls'),
                'APPLE_CERTIFICATE_P12': base64.b64encode(b'fixture').decode(),
                'APPLE_CERTIFICATE_PASSWORD': 'fixture-password',
                'APPLE_SIGNING_IDENTITY': 'Developer ID Application: Fixture',
                'APPLE_TEAM_ID': 'FIXTURE', 'NOTARIZE': notarize,
            }
            if credentials:
                environment.update(APPLE_ID='fixture@example.com', APPLE_APP_PASSWORD='fixture-notary-password')
            result = subprocess.run(['bash', str(ROOT / 'scripts/ci-signing.sh')],
                                    env=environment, capture_output=True, text=True)
            calls = (work / 'calls').read_text() if (work / 'calls').exists() else ''
            exported = (work / 'environment').read_text() if (work / 'environment').exists() else ''
            self.assertFalse((work / 'certificate.p12').exists())
            return result, calls, exported

    def test_release_cannot_disable_notarization(self):
        result, calls, exported = self.invoke('0', credentials=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Release requires Apple notarization', result.stderr)
        self.assertEqual(calls, '')
        self.assertEqual(exported, '')

    def test_explicit_notarization_fails_before_import_if_credentials_missing(self):
        result, calls, _ = self.invoke('1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Notarization requires', result.stderr)
        self.assertEqual(calls, '')

    def test_notarization_with_credentials_configures_profile(self):
        result, calls, exported = self.invoke('1', credentials=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('xcrun:notarytool', calls)
        self.assertIn('NOTARY_KEYCHAIN_PROFILE=xdvpn-notary', exported)

    def test_invalid_flag_cannot_silently_disable_notarization(self):
        result, calls, _ = self.invoke('yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('NOTARIZE must be', result.stderr)
        self.assertEqual(calls, '')
