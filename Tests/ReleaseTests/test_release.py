import importlib.util
import hashlib
import json
import tempfile
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import version
spec = importlib.util.spec_from_file_location('github_release', Path(version.__file__).with_name('github-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.clean = patch.dict(os.environ, {}, clear=True)
        self.clean.start()
        self.addCleanup(self.clean.stop)

    def test_channels_never_share_display_versions(self):
        dev = version.metadata('development')
        test = version.metadata('test', '999')
        stable = version.metadata('release', tag=dev['tag'])
        self.assertEqual(len({dev['displayVersion'], test['displayVersion'], stable['displayVersion']}), 3)
        self.assertEqual(stable['displayVersion'], stable['version'])

    def test_release_is_explicit_and_bound_to_source_version_and_build(self):
        data = version.metadata('development')
        for tag in (None, 'v0.0.0', data['tag'] + '-rc.1', data['version']):
            with self.assertRaises(ValueError):
                version.metadata('release', tag=tag)
        with self.assertRaises(ValueError):
            version.metadata('release', build='999', tag=data['tag'])

    def test_noncanonical_versions_and_builds(self):
        for value in ('1.2', '01.2.3', '1.2.3-test.1', '1.2.3\n', '１.2.3', '-1.2.3'):
            self.assertIsNone(version.SEMVER.fullmatch(value))
        for value in ('0', '-1', '01', 'foo', '9999999999'):
            with self.assertRaises(ValueError):
                version.metadata('test', value)
        with self.assertRaises(ValueError):
            version.metadata('test')

    def test_repository_must_be_owner_repo(self):
        for repo in ('../foo', 'owner/..', 'https://example.com', 'owner/repo?token=secret'):
            with patch.dict(os.environ, {'RELEASE_REPOSITORY': repo}), self.assertRaises(ValueError):
                version.metadata('development')

    def test_publication_order_and_draft_retry(self):
        data = {'version': '1.2.0', 'tag': 'v1.2.0'}
        def item(tag, draft=False, prerelease=False):
            return dict(tag_name=tag, draft=draft, prerelease=prerelease)
        for previous in ('v1.2.0', 'v1.10.0', 'v2.0.0'):
            with patch.object(release, 'releases', return_value=[item(previous)]), self.assertRaises(ValueError):
                release.validate('owner/repo', data)
        draft = item('v1.2.0', draft=True)
        with patch.object(release, 'releases', return_value=[item('v1.1.9'), draft, item('v2.0.0-rc.1', prerelease=True)]):
            self.assertEqual(release.validate('owner/repo', data), draft)

    def test_publish_is_last_and_requires_matching_remote_digests(self):
        data = version.metadata('development')
        names = release.asset_names(data['version'])
        self.assertEqual(names[-1], f'XD-VPN-{data["version"]}-Android.apk')
        with tempfile.TemporaryDirectory() as folder:
            old = os.getcwd()
            os.chdir(folder)
            try:
                root = Path('build')
                root.mkdir()
                for name in names:
                    (root / name).write_bytes(b'fake-disk-image')
                    digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
                    (root / (name + '.sha256')).write_text(f'{digest}  {name}\n')
                (root / 'third-party-sources.tar.gz').write_bytes(b'source')
                (root / 'release-notes.md').write_text('Release notes')
                assets = [dict(name=file.name, size=file.stat().st_size,
                               digest='sha256:' + hashlib.sha256(file.read_bytes()).hexdigest())
                          for file in root.iterdir() if file.suffix in ('.dmg', '.apk')]
                draft = dict(tag_name=data['tag'], draft=True, prerelease=False, assets=assets)
                for valid in (True, False):
                    if not valid:
                        assets[0]['digest'] = None
                    with patch.dict(os.environ, {'RELEASE_TAG': data['tag']}), \
                         patch.object(sys, 'argv', ['github-release.py', 'publish']), \
                         patch.object(release, 'validate', return_value=None), \
                         patch.object(release, 'releases', return_value=[draft]), \
                         patch.object(release.time, 'sleep'), \
                         patch.object(release, 'verify_delivery') as verify, \
                         patch.object(release, 'gh', return_value='https://github.com/release') as gh:
                        if valid:
                            release.main()
                            operations = [call.args[1] for call in gh.call_args_list]
                            self.assertEqual(operations, ['create', 'upload', 'edit', 'view'])
                            self.assertEqual(gh.call_args_list[1].args,
                                             ('release', 'upload', data['tag'], '--repo', data['repository'],
                                              '--clobber', *[str(root / name) for name in names]))
                            self.assertIn('--draft=false', gh.call_args_list[2].args)
                            verify.assert_called_once()
                        else:
                            with self.assertRaises(ValueError):
                                release.main()
                            self.assertNotIn('edit', [call.args[1] for call in gh.call_args_list])
            finally:
                os.chdir(old)

    def test_android_apk_metadata_must_match_the_release(self):
        spec = importlib.util.spec_from_file_location('verify_release_apk', Path(version.__file__).with_name('verify-release-apk.py'))
        verify = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verify)
        data = version.metadata('development')
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {'RELEASE_TAG': data['tag']}):
            def apk(name, info, signed=True):
                path = Path(folder) / name
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr('assets/xdvpn-version.json', json.dumps(info))
                    archive.writestr('classes.dex', b'dex')
                if signed:
                    path.write_bytes(path.read_bytes() + b'APK Sig Block 42')
                return path
            good = dict(version=data['version'], build=int(data['build']), channel='release', displayVersion=data['version'], signing='development')
            self.assertEqual(verify.check(apk(f'XD-VPN-{data["version"]}-Android.apk', good))['signing'], 'development')
            for bad in (dict(good, channel='test'), dict(good, version='0.0.1'), dict(good, build=1), dict(good, signing='unsigned'),
                        dict(good, displayVersion=data['version'] + '-dev.1')):
                with self.assertRaises(ValueError):
                    verify.check(apk(f'XD-VPN-{data["version"]}-Android.apk', bad))
            with self.assertRaises(ValueError):
                verify.check(apk(f'XD-VPN-{data["version"]}-Android.apk', good, signed=False))
            with self.assertRaises(ValueError):
                verify.check(apk('app-release.apk', good))

    def test_missing_payload_cannot_create_a_release(self):
        with patch.dict(os.environ, {'RELEASE_TAG': version.metadata('development')['tag']}), \
             patch.object(sys, 'argv', ['github-release.py', 'publish']), \
             patch.object(release, 'validate', return_value=None), \
             patch.object(release.Path, 'is_file', return_value=False), \
             patch.object(release, 'gh') as gh, \
             self.assertRaises(ValueError):
            release.main()
        gh.assert_not_called()


if __name__ == '__main__':
    unittest.main()
