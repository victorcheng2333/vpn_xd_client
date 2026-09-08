import base64
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import asc
spec = importlib.util.spec_from_file_location('pipeline', Path(__file__).resolve().parents[1] / 'scripts/release-testflight.py')
pipeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipeline)


class APITests(unittest.TestCase):
    def test_jwt_can_be_verified_with_public_key(self):
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
        key = ec.generate_private_key(ec.SECP256R1())
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'key.p8'
            p.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            with patch.object(asc.time, 'time', return_value=1000):
                jwt = asc.token({'ASC_KEY_PATH': str(p), 'ASC_KEY_ID': 'ABCDEFGHIJ', 'ASC_ISSUER_ID': 'issuer'})
        a, b, c = jwt.split('.')
        dec = lambda x: base64.urlsafe_b64decode(x + '=' * (-len(x) % 4))
        self.assertEqual(json.loads(dec(b)), {'iss': 'issuer', 'iat': 990, 'exp': 1600, 'aud': 'appstoreconnect-v1'})
        raw = dec(c)
        self.assertEqual(len(raw), 64)
        sig = encode_dss_signature(int.from_bytes(raw[:32], 'big'), int.from_bytes(raw[32:], 'big'))
        key.public_key().verify(sig, (a + '.' + b).encode(), ec.ECDSA(hashes.SHA256()))

    def test_pagination_keeps_all_builds(self):
        c = asc.Client({'dummy': True})
        c.request = Mock(side_effect=[{'data': [1], 'links': {'next': asc.BASE + '/v1/builds?cursor=2'}}, {'data': [2]}])
        self.assertEqual(c.all('/v1/builds', {'limit': 1}), [1, 2])
        self.assertIsNone(c.request.call_args.args[2])

    def test_foreign_pagination_never_receives_token(self):
        c = asc.Client({'dummy': True})
        with patch.object(asc, 'token') as token, self.assertRaises(ValueError):
            c.request('GET', 'https://evil.example/v1/builds')
        token.assert_not_called()

    def test_write_network_failure_not_retried(self):
        c = asc.Client({'dummy': True})
        opener = Mock()
        opener.open.side_effect = urllib.error.URLError('connection lost')
        with patch.object(asc, 'token', return_value='secret'), patch.object(asc.urllib.request, 'build_opener', return_value=opener):
            with self.assertRaisesRegex(RuntimeError, 'outcome may be unknown'):
                c.request('POST', '/v1/betaAppReviewSubmissions', body={})
        self.assertEqual(opener.open.call_count, 1)

    def test_processing_timeout_does_not_upload(self):
        c = asc.Client({'dummy': True}); c.builds = Mock(return_value=[])
        with self.assertRaisesRegex(TimeoutError, 'do not upload again'):
            c.wait_build('app', '0.1.0', '6', timeout=0)

    def test_failed_and_expired_build_stop(self):
        for attrs in [{'processingState': 'INVALID'}, {'processingState': 'VALID', 'expired': True}]:
            c = asc.Client({'dummy': True}); c.builds = Mock(return_value=[{'attributes': attrs}])
            with self.assertRaises(RuntimeError):
                c.wait_build('app', '0.1.0', '6', timeout=0)


class PipelineTests(unittest.TestCase):
    def test_next_number_includes_all_remote_and_local_attempts(self):
        c = Mock(); c.builds.return_value = [{'attributes': {'version': '5'}}, {'attributes': {'version': '12'}}]
        with tempfile.TemporaryDirectory() as d, patch.object(pipeline, 'IOS', Path(d)):
            (Path(d) / '.build/testflight/0.1.0-14').mkdir(parents=True)
            self.assertEqual(pipeline.next_build(c, {'app_id': 'app'}, '0.1.0'), '15')

    def test_wrong_app_or_internal_group_stops(self):
        c = Mock(); c.request.return_value = {'data': {'attributes': {'bundleId': 'wrong'}}}
        with self.assertRaises(ValueError):
            pipeline.preflight(c, {'app_id': 'a', 'bundle_id': 'expected'})
        c.request.return_value = {'data': {'attributes': {'bundleId': 'expected'}}}
        c.groups.return_value = [{'id': 'g', 'attributes': {'isInternalGroup': True}}]
        with self.assertRaises(ValueError):
            pipeline.preflight(c, {'app_id': 'a', 'bundle_id': 'expected', 'external_group_id': 'g'})

    def test_encryption_requires_explicit_choice_and_preserves_remote(self):
        c = Mock(); c.detail.return_value = {'attributes': {'externalBuildState': 'READY_FOR_BETA_SUBMISSION'}}
        row = {'id': 'b', 'attributes': {'usesNonExemptEncryption': None}}
        with self.assertRaises(ValueError):
            pipeline.compliance(c, {}, row)
        c.request.assert_not_called()
        pipeline.compliance(c, {'uses_non_exempt_encryption': False}, row)
        self.assertIs(c.request.call_args.kwargs['body']['data']['attributes']['usesNonExemptEncryption'], False)
        c.request.reset_mock()
        row['attributes']['usesNonExemptEncryption'] = True
        with self.assertRaises(ValueError):
            pipeline.compliance(c, {'uses_non_exempt_encryption': False}, row)
        c.request.assert_not_called()

    def test_missing_review_metadata_never_leaks_password(self):
        c = Mock(); c.request.return_value = {'data': {'attributes': {'demoAccountRequired': True, 'demoAccountPassword': 'private-password'}}}
        c.all.return_value = []
        with self.assertRaises(ValueError) as e:
            pipeline.review_metadata(c, 'a')
        self.assertNotIn('private-password', str(e.exception))

    def test_existing_review_not_submitted_twice(self):
        c = Mock(); c.detail.return_value = {'attributes': {'externalBuildState': 'WAITING_FOR_BETA_REVIEW'}}
        c.all.return_value = [{'id': 'g'}]
        state = pipeline.finish(c, {}, {'id': 'b', 'attributes': {}}, {'id': 'g'}, 'notes', 'zh-Hans', True)
        self.assertEqual(state, 'WAITING_FOR_BETA_REVIEW')
        c.request.assert_not_called()

    def test_internal_only_rejected_before_mutation(self):
        c = Mock()
        with self.assertRaises(ValueError):
            pipeline.finish(c, {}, {'attributes': {'buildAudienceType': 'INTERNAL_ONLY'}}, {}, '', '', True)
        c.request.assert_not_called()

    def test_no_review_submission_without_flag(self):
        c = Mock(); c.detail.return_value = {'attributes': {'externalBuildState': 'READY_FOR_BETA_SUBMISSION'}}
        c.all.return_value = [{'id': 'g'}]
        with patch.object(pipeline, 'compliance'), patch.object(pipeline, 'set_notes'):
            pipeline.finish(c, {}, {'id': 'b', 'attributes': {}}, {'id': 'g'}, 'notes', 'zh-Hans', False)
        c.request.assert_not_called()

    def test_submit_exact_build_then_report_actual_state(self):
        c = Mock(); c.detail.side_effect = [
            {'attributes': {'externalBuildState': 'READY_FOR_BETA_SUBMISSION'}},
            {'attributes': {'externalBuildState': 'READY_FOR_BETA_SUBMISSION'}},
            {'attributes': {'externalBuildState': 'WAITING_FOR_BETA_REVIEW'}}]
        c.all.return_value = [{'id': 'g'}]
        with patch.object(pipeline, 'compliance'), patch.object(pipeline, 'set_notes'), patch.object(pipeline, 'review_metadata'):
            state = pipeline.finish(c, {'app_id': 'a'}, {'id': 'exact-build', 'attributes': {}}, {'id': 'g'}, 'notes', 'zh-Hans', True)
        self.assertEqual(state, 'WAITING_FOR_BETA_REVIEW')
        self.assertEqual(c.request.call_args.kwargs['body']['data']['relationships']['build']['data']['id'], 'exact-build')


if __name__ == '__main__':
    unittest.main()
