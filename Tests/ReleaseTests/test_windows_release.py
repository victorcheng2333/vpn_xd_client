import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import version
spec = importlib.util.spec_from_file_location('verify_windows', Path(version.__file__).with_name('verify-release-windows.py'))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class WindowsDeliveryTests(unittest.TestCase):
    def test_accepts_only_matching_windows_build(self):
        info = version.metadata('development')
        with tempfile.TemporaryDirectory() as folder, \
                patch.dict(os.environ, {'RELEASE_TAG': info['tag'], 'BUILD_NUMBER': info['build']}), \
                patch.object(verify.subprocess, 'check_output', return_value='revision\n'):
            path = Path(folder) / f'XD-VPN-{info["version"]}-Windows-x64.exe'
            payload = b'MZverified-windows-fixture'
            path.write_bytes(payload)
            record = dict(tag=info['tag'], version=info['version'], build=info['build'], revision='revision',
                          assets=[dict(name=path.name, size=len(payload), sha256=hashlib.sha256(payload).hexdigest())])
            manifest = path.with_name('windows-release.json')
            manifest.write_text(json.dumps(record), encoding='utf-8-sig')
            self.assertEqual(verify.check(path), record)
            for field, value in [('tag', 'windows-' + info['tag']), ('version', '0.0.0'),
                                 ('build', '9999'), ('revision', 'another-commit'), ('assets', []),
                                 ('assets', record['assets'] * 2)]:
                with self.subTest(field=field, value=value):
                    manifest.write_text(json.dumps(dict(record, **{field: value})))
                    with self.assertRaises(ValueError):
                        verify.check(path)
            manifest.write_text(json.dumps(record))
            for invalid in (b'MZtampered-windows-fixture', b'MZ', b'not-an-executable'):
                path.write_bytes(invalid)
                with self.assertRaises(ValueError):
                    verify.check(path)
            manifest.unlink()
            with self.assertRaises(FileNotFoundError):
                verify.check(path)
            with self.assertRaises(ValueError):
                verify.check(path.with_name('preview.exe'))

    def test_publisher_runs_windows_verifier(self):
        from test_release import release
        path = Path('build/XD-VPN-1.2.3-Windows-x64.exe')
        with patch.object(release.subprocess, 'run') as run:
            release.verify_delivery([path])
        self.assertEqual(run.call_count, 2)
        self.assertTrue(run.call_args.args[0][1].endswith('verify-release-windows.py'))
        self.assertEqual(run.call_args.args[0][2], str(path))
