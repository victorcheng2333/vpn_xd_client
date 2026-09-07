import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('verify_release_dmg', SCRIPTS / 'verify-release-dmg.py')
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


class NotarizationGateTests(unittest.TestCase):
    def test_missing_dmg_ticket_stops_before_mounting_or_reading_payload(self):
        data = dict(version='1.1.19', build='22', repository='owner/repo')
        failure = subprocess.CalledProcessError(65, ['xcrun', 'stapler', 'validate'])
        with patch.object(verification, 'output', side_effect=[b'', failure]) as output:
            with self.assertRaises(subprocess.CalledProcessError):
                verification.verify(Path('XD-VPN-1.1.19-macOS-arm64.dmg'), data, 'revision')
        self.assertEqual(output.call_count, 2)
        self.assertEqual(output.call_args.args[:3], ('xcrun', 'stapler', 'validate'))

    def test_untrusted_dmg_signature_stops_before_ticket_checks(self):
        failure = subprocess.CalledProcessError(1, ['codesign'])
        with patch.object(verification, 'output', side_effect=failure) as output:
            with self.assertRaises(subprocess.CalledProcessError):
                verification.verify(Path('XD-VPN-1.1.19-macOS-arm64.dmg'), {'version': '1.1.19'}, 'revision')
        self.assertEqual(output.call_count, 1)

    def test_test_package_cannot_be_used_as_a_stable_release(self):
        with patch.object(verification, 'output') as output:
            with self.assertRaises(ValueError):
                verification.verify(Path('XD-VPN-1.1.19-test.23-macOS-arm64.dmg'), {'version': '1.1.19'}, 'revision')
        output.assert_not_called()
