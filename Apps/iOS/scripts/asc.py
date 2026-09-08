"""Small App Store Connect client. Tokens and private keys never enter logs."""
import base64
import json
import os
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

BASE = 'https://api.appstoreconnect.apple.com'
LOCAL = Path(__file__).resolve().parent.parent / 'Configuration/TestFlight.local.json'


def credentials():
    saved = json.loads(LOCAL.read_text()) if LOCAL.exists() else {}
    values = {k: os.environ.get(k, saved.get(k, '')) for k in
              ('ASC_KEY_PATH', 'ASC_KEY_ID', 'ASC_ISSUER_ID')}
    if not all(values.values()):
        raise ValueError('Configure ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID.')
    if not re.fullmatch(r'[A-Z0-9]{10}', values['ASC_KEY_ID']):
        raise ValueError('Invalid ASC_KEY_ID.')
    uuid.UUID(values['ASC_ISSUER_ID'])
    values['ASC_KEY_PATH'] = str(Path(values['ASC_KEY_PATH']).expanduser().resolve())
    if not Path(values['ASC_KEY_PATH']).is_file():
        raise ValueError('ASC_KEY_PATH does not exist.')
    return values


def token(settings):
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    except ImportError:
        raise RuntimeError('Install Apps/iOS/scripts/requirements-testflight.txt first.') from None
    def b64(data):
        return base64.urlsafe_b64encode(data).rstrip(b'=')
    key = serialization.load_pem_private_key(Path(settings['ASC_KEY_PATH']).read_bytes(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
        raise ValueError('ASC key must be an EC P-256 private key.')
    now = int(time.time())
    header = {'alg': 'ES256', 'kid': settings['ASC_KEY_ID'], 'typ': 'JWT'}
    payload = {'iss': settings['ASC_ISSUER_ID'], 'iat': now - 10,
               'exp': now + 600, 'aud': 'appstoreconnect-v1'}
    message = b'.'.join(b64(json.dumps(x, separators=(',', ':')).encode()) for x in (header, payload))
    r, s = decode_dss_signature(key.sign(message, ec.ECDSA(hashes.SHA256())))
    return (message + b'.' + b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))).decode()


class APIError(RuntimeError):
    def __init__(self, status, codes):
        self.status = status
        super().__init__(f'App Store Connect HTTP {status}: {codes}')


class Client:
    def __init__(self, settings=None):
        self.settings = settings or credentials()
        self.bearer = None
        self.expires = 0

    def request(self, method, path, params=None, body=None):
        url = path if path.startswith('https://') else BASE + path
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != 'https' or parsed.netloc != 'api.appstoreconnect.apple.com':
            raise ValueError('Refusing to send ASC credentials to another origin.')
        if params:
            url += '?' + urllib.parse.urlencode(params)
        # Do not follow redirects with an Authorization header.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        for attempt in range(4):
            if time.time() >= self.expires:
                self.bearer = token(self.settings)
                self.expires = time.time() + 480
            req = urllib.request.Request(url, method=method,
                data=json.dumps(body).encode() if body is not None else None,
                headers={'Authorization': 'Bearer ' + self.bearer, 'Content-Type': 'application/json'})
            try:
                with urllib.request.build_opener(NoRedirect).open(req, timeout=45) as response:
                    data = response.read()
                    return json.loads(data) if data else {}
            except urllib.error.HTTPError as error:
                if method == 'GET' and (error.code == 429 or error.code >= 500) and attempt < 3:
                    time.sleep(min(30, 2 ** (attempt + 1)))
                    continue
                try:
                    codes = ', '.join(x.get('code', 'UNKNOWN') for x in json.loads(error.read()).get('errors', []))
                except (ValueError, AttributeError):
                    codes = 'See App Store Connect status and permissions.'
                raise APIError(error.code, codes) from None
            except urllib.error.URLError:
                if method == 'GET' and attempt < 3:
                    time.sleep(2 ** (attempt + 1))
                    continue
                raise RuntimeError('ASC network failure; mutation outcome may be unknown. Query status before retrying.') from None

    def all(self, path, params=None):
        rows = []
        while path:
            response = self.request('GET', path, params)
            rows.extend(response['data'])
            path = response.get('links', {}).get('next')
            params = None
        return rows

    def builds(self, app, version=None, build=None):
        params = {'filter[app]': app, 'filter[preReleaseVersion.platform]': 'IOS', 'limit': 200}
        if version:
            params['filter[preReleaseVersion.version]'] = version
        if build:
            params['filter[version]'] = build
        return self.all('/v1/builds', params)

    def groups(self, app):
        return self.all('/v1/betaGroups', {'filter[app]': app, 'limit': 200})

    def detail(self, build_id):
        return self.request('GET', f'/v1/builds/{build_id}/buildBetaDetail')['data']

    def wait_build(self, app, version, build, timeout=1800):
        deadline = time.monotonic() + timeout
        while True:
            rows = self.builds(app, version, build)
            if len(rows) > 1:
                raise RuntimeError('Ambiguous build response.')
            if rows:
                row = rows[0]
                state = row['attributes']['processingState']
                if state == 'VALID':
                    if row['attributes'].get('expired'):
                        raise RuntimeError('Build is expired.')
                    return row
                if state in ('FAILED', 'INVALID'):
                    raise RuntimeError(f'Apple processing failed: {state}.')
            else:
                state = 'NOT_VISIBLE'
            print(f'Apple processing: {state}', flush=True)
            if time.monotonic() >= deadline:
                raise TimeoutError('Processing timeout. Resume this version/build; do not upload again.')
            time.sleep(min(30, max(0, deadline - time.monotonic())))
