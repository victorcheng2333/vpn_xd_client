import base64
import importlib.util
import contextlib
import io
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
    def test_default_internal_cli_rejects_external_flags_before_network(self):
        for flag in ('--submit-review', '--notify-testers', '--wait-review=60'):
            with self.subTest(flag=flag), patch.object(sys, 'argv', ['release-testflight.py', 'release', flag]), \
                    patch.object(pipeline, 'Client') as client, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    pipeline.main()
                self.assertEqual(error.exception.code, 2)
                client.assert_not_called()

    def test_internal_preflight_rejects_external_group_even_with_matching_id(self):
        c = Mock(); c.request.return_value = {'data': {'attributes': {'bundleId': 'expected'}}}
        config = {'app_id': 'a', 'bundle_id': 'expected', 'internal_group_id': 'g'}
        c.groups.return_value = [{'id': 'g', 'attributes': {'isInternalGroup': False}}]
        with self.assertRaises(ValueError):
            pipeline.preflight(c, config, 'internal')
        c.groups.return_value[0]['attributes']['isInternalGroup'] = True
        self.assertEqual(pipeline.preflight(c, config, 'internal')['id'], 'g')

    def test_internal_distribution_cannot_submit_beta_review(self):
        c = asc.Client({'dummy': True})
        c.detail = Mock(return_value={'attributes': {'internalBuildState': 'IN_BETA_TESTING',
                                                     'externalBuildState': 'NOT_APPLICABLE'}})
        row = {'id': 'b', 'attributes': {'buildAudienceType': 'INTERNAL_ONLY', 'usesNonExemptEncryption': False}}
        group = {'id': 'g', 'attributes': {'isInternalGroup': True}}

        def request(method, path, params=None, body=None):
            if method == 'GET' and path == '/v1/betaBuildLocalizations':
                return {'data': [{'id': 'n', 'attributes': {'locale': 'zh-Hans', 'whatsNew': 'notes'}}]}
            if method == 'GET' and path == '/v1/betaGroups/g/builds':
                return {'data': []}
            if method == 'POST' and path == '/v1/betaGroups/g/relationships/builds':
                self.assertEqual(body, {'data': [{'type': 'builds', 'id': 'b'}]})
                return {}
            self.fail('Unexpected API operation: ' + method + ' ' + path)

        c.request = Mock(side_effect=request)
        state = pipeline.finish(c, {'uses_non_exempt_encryption': False}, row, group, 'notes', 'zh-Hans', False, audience='internal')
        self.assertEqual(state, 'IN_BETA_TESTING')
        self.assertEqual(c.request.call_count, 3)

    def test_internal_distribution_rejects_wrong_build_group_and_review(self):
        for audience_type, internal_group, review in [('APP_STORE_ELIGIBLE', True, False),
                                                     ('INTERNAL_ONLY', False, False),
                                                     ('INTERNAL_ONLY', True, True)]:
            c = Mock()
            with self.subTest(audience_type=audience_type, internal_group=internal_group, review=review), self.assertRaises(ValueError):
                pipeline.finish(c, {}, {'attributes': {'buildAudienceType': audience_type}},
                                {'attributes': {'isInternalGroup': internal_group}}, 'notes', 'zh-Hans', review, audience='internal')
            c.request.assert_not_called()
            c.detail.assert_not_called()

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
        c.all.return_value = [{'id': 'b'}]
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
        c.all.return_value = [{'id': 'b'}]
        with patch.object(pipeline, 'compliance'), patch.object(pipeline, 'set_notes'):
            pipeline.finish(c, {}, {'id': 'b', 'attributes': {}}, {'id': 'g'}, 'notes', 'zh-Hans', False)
        c.request.assert_not_called()

    def test_submit_exact_build_then_report_actual_state(self):
        c = Mock(); c.detail.side_effect = [
            {'attributes': {'externalBuildState': 'READY_FOR_BETA_SUBMISSION'}},
            {'attributes': {'externalBuildState': 'READY_FOR_BETA_SUBMISSION'}},
            {'attributes': {'externalBuildState': 'WAITING_FOR_BETA_REVIEW'}}]
        c.all.return_value = [{'id': 'exact-build'}]
        with patch.object(pipeline, 'compliance'), patch.object(pipeline, 'set_notes'), patch.object(pipeline, 'review_metadata'):
            state = pipeline.finish(c, {'app_id': 'a'}, {'id': 'exact-build', 'attributes': {}}, {'id': 'g'}, 'notes', 'zh-Hans', True)
        self.assertEqual(state, 'WAITING_FOR_BETA_REVIEW')
        self.assertEqual(c.request.call_args.kwargs['body']['data']['relationships']['build']['data']['id'], 'exact-build')

    def test_group_lookup_paginates_without_unsupported_build_relationship(self):
        c = asc.Client({'dummy': True})
        c.detail = Mock(return_value={'attributes': {'externalBuildState': 'WAITING_FOR_BETA_REVIEW'}})
        next_page = asc.BASE + '/v1/betaGroups/g/builds?cursor=next'

        def request(method, path, params=None, body=None):
            if method == 'GET' and path == '/v1/betaGroups/g/builds':
                return {'data': [{'id': 'older'}], 'links': {'next': next_page}}
            if method == 'GET' and path == next_page:
                return {'data': [{'id': 'b'}]}
            self.fail('Unexpected API operation: ' + method + ' ' + path)

        c.request = Mock(side_effect=request)
        state = pipeline.finish(c, {}, {'id': 'b', 'attributes': {}}, {'id': 'g'}, 'notes', 'zh-Hans', True)
        self.assertEqual(state, 'WAITING_FOR_BETA_REVIEW')
        self.assertEqual(c.request.call_count, 2)
        c.request.assert_any_call('GET', next_page, None)

    def test_missing_build_is_added_without_replacing_other_group_builds(self):
        c = asc.Client({'dummy': True})
        c.detail = Mock(return_value={'attributes': {'externalBuildState': 'WAITING_FOR_BETA_REVIEW'}})

        def request(method, path, params=None, body=None):
            if method == 'GET' and path == '/v1/betaGroups/g/builds':
                return {'data': [{'id': 'older'}]}
            if method == 'POST' and path == '/v1/betaGroups/g/relationships/builds':
                self.assertEqual(body, {'data': [{'type': 'builds', 'id': 'b'}]})
                return {}
            self.fail('Unexpected API operation: ' + method + ' ' + path)

        c.request = Mock(side_effect=request)
        pipeline.finish(c, {}, {'id': 'b', 'attributes': {}}, {'id': 'g'}, 'notes', 'zh-Hans', True)
        self.assertEqual(c.request.call_count, 2)


if __name__ == '__main__':
    unittest.main()
