#!/usr/bin/env python3
"""Release/resume an exact iOS build through the official App Store Connect API."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from asc import Client, LOCAL
import testflight

IOS = Path(__file__).resolve().parent.parent


def settings():
    data = testflight.configuration()
    data.update(json.loads(LOCAL.read_text()) if LOCAL.exists() else {})
    # CI and local launches use the same pipeline.
    if os.environ.get('ASC_BETA_GROUP_ID'):
        data['external_group_id'] = os.environ['ASC_BETA_GROUP_ID']
    if os.environ.get('ASC_INTERNAL_BETA_GROUP_ID'):
        data['internal_group_id'] = os.environ['ASC_INTERNAL_BETA_GROUP_ID']
    if os.environ.get('ASC_USES_NON_EXEMPT_ENCRYPTION'):
        value = os.environ['ASC_USES_NON_EXEMPT_ENCRYPTION']
        if value not in ('true', 'false'):
            raise ValueError('ASC_USES_NON_EXEMPT_ENCRYPTION must be true or false.')
        data['uses_non_exempt_encryption'] = value == 'true'
    if os.environ.get('ASC_ENCRYPTION_DECLARATION_ID'):
        data['encryption_declaration_id'] = os.environ['ASC_ENCRYPTION_DECLARATION_ID']
    return data


def next_build(client, config, version):
    numbers = []
    for row in client.builds(config['app_id'], version):
        value = row['attributes']['version']
        if not value.isdecimal():
            raise ValueError('Remote build uses a noninteger format; choose --build explicitly.')
        numbers.append(int(value))
    # Reserve even failed or not-yet-visible local uploads.
    for path in (IOS / '.build/testflight').glob(version + '-*'):
        suffix = path.name[len(version) + 1:]
        if suffix.isdecimal():
            numbers.append(int(suffix))
    result = str(max(numbers, default=0) + 1)
    testflight.release_values(version, result)
    return result


def preflight(client, config, audience='external'):
    if audience not in ('internal', 'external'):
        raise ValueError('Unknown TestFlight audience.')
    app = client.request('GET', '/v1/apps/' + config['app_id'])['data']
    if app['attributes']['bundleId'] != config['bundle_id']:
        raise ValueError('API app bundle ID does not match release configuration.')
    groups = client.groups(config['app_id'])
    wanted = config.get(audience + '_group_id')
    matches = [g for g in groups if g['id'] == wanted and g['attributes']['isInternalGroup'] == (audience == 'internal')]
    if len(matches) != 1:
        raise ValueError(f'Configure {audience}_group_id with an existing {audience} group for this app.')
    return matches[0]


def review_metadata(client, app):
    data = client.request('GET', f'/v1/apps/{app}/betaAppReviewDetail')['data']
    a = data['attributes'] if data else {}
    required = ['contactFirstName', 'contactLastName', 'contactEmail', 'contactPhone']
    if a.get('demoAccountRequired'):
        required += ['demoAccountName', 'demoAccountPassword']
    missing = [k for k in required if not a.get(k)]
    localizations = client.all('/v1/betaAppLocalizations', {'filter[app]': app, 'limit': 200})
    if not any(x['attributes'].get('description') and x['attributes'].get('feedbackEmail') for x in localizations):
        missing.append('beta description/feedback email')
    if missing:
        raise ValueError('Missing beta review metadata: ' + ', '.join(missing))
    # Do not return, print or persist reviewer credentials.


def compliance(client, config, row):
    current = row['attributes'].get('usesNonExemptEncryption')
    intended = config.get('uses_non_exempt_encryption')
    if intended is not None and type(intended) is not bool:
        raise ValueError('uses_non_exempt_encryption must be a JSON boolean.')
    if current is None:
        if intended is None:
            raise ValueError('Encryption declaration is not configured. Confirm the team declaration before continuing.')
        body = {'data': {'type': 'builds', 'id': row['id'],
                         'attributes': {'usesNonExemptEncryption': intended}}}
        declaration = config.get('encryption_declaration_id')
        if intended and declaration:
            body['data']['relationships'] = {'appEncryptionDeclaration': {
                'data': {'type': 'appEncryptionDeclarations', 'id': declaration}}}
        client.request('PATCH', '/v1/builds/' + row['id'], body=body)
    elif intended is not None and intended != current:
        raise ValueError('Remote encryption declaration conflicts with local configuration; inspect it before continuing.')
    # Existing remote declarations are preserved. Apple remains the authority on readiness.
    detail = client.detail(row['id'])['attributes']
    if any(detail.get(k) in ('MISSING_EXPORT_COMPLIANCE', 'IN_EXPORT_COMPLIANCE_REVIEW')
           for k in ('externalBuildState', 'internalBuildState')):
        raise RuntimeError('Apple export compliance is pending; resume after the declaration is accepted.')


def set_notes(client, build_id, locale, notes):
    rows = client.all('/v1/betaBuildLocalizations', {'filter[build]': build_id, 'limit': 200})
    existing = next((x for x in rows if x['attributes']['locale'] == locale), None)
    if existing:
        if existing['attributes'].get('whatsNew') != notes:
            client.request('PATCH', '/v1/betaBuildLocalizations/' + existing['id'], body={
                'data': {'type': 'betaBuildLocalizations', 'id': existing['id'], 'attributes': {'whatsNew': notes}}})
    else:
        client.request('POST', '/v1/betaBuildLocalizations', body={'data': {
            'type': 'betaBuildLocalizations', 'attributes': {'locale': locale, 'whatsNew': notes},
            'relationships': {'build': {'data': {'type': 'builds', 'id': build_id}}}}})


def associate_group(client, row, group):
    # Build.betaGroups does not support GET_RELATED. Page through the selected
    # group's builds and append only this build, preserving existing access.
    builds = client.all('/v1/betaGroups/' + group['id'] + '/builds', {'limit': 200})
    if row['id'] not in [x['id'] for x in builds]:
        client.request('POST', '/v1/betaGroups/' + group['id'] + '/relationships/builds', body={
            'data': [{'type': 'builds', 'id': row['id']}]})


def finish(client, config, row, group, notes, locale, submit_review, notify_testers=False, audience='external'):
    if audience == 'internal':
        if submit_review or notify_testers:
            raise ValueError('Internal testing does not accept external review or notification flags.')
        if not group['attributes']['isInternalGroup'] or row['attributes'].get('buildAudienceType') != 'INTERNAL_ONLY':
            raise ValueError('Internal release requires an internal group and an INTERNAL_ONLY build.')
        state = client.detail(row['id'])['attributes']['internalBuildState']
        if state in ('EXPIRED', 'PROCESSING_EXCEPTION', 'NOT_APPLICABLE'):
            raise RuntimeError('Internal build requires attention: ' + state)
        compliance(client, config, row)
        set_notes(client, row['id'], locale, notes)
        associate_group(client, row, group)
        return client.detail(row['id'])['attributes']['internalBuildState']
    if audience != 'external':
        raise ValueError('Unknown TestFlight audience.')
    if row['attributes'].get('buildAudienceType') == 'INTERNAL_ONLY':
        raise ValueError('This build is INTERNAL_ONLY and cannot be distributed externally.')
    state = client.detail(row['id'])['attributes']['externalBuildState']
    if state in ('BETA_REJECTED', 'EXPIRED', 'PROCESSING_EXCEPTION', 'NOT_APPLICABLE'):
        raise RuntimeError('Build requires attention: ' + state)
    if state not in ('WAITING_FOR_BETA_REVIEW', 'IN_BETA_REVIEW', 'IN_BETA_TESTING'):
        compliance(client, config, row)
        set_notes(client, row['id'], locale, notes)
        if submit_review:
            review_metadata(client, config['app_id'])
    if notify_testers:
        detail = client.detail(row['id'])
        if not detail['attributes'].get('autoNotifyEnabled'):
            client.request('PATCH', '/v1/buildBetaDetails/' + detail['id'], body={
                'data': {'type': 'buildBetaDetails', 'id': detail['id'],
                         'attributes': {'autoNotifyEnabled': True}}})
    associate_group(client, row, group)
    state = client.detail(row['id'])['attributes']['externalBuildState']
    if state == 'READY_FOR_BETA_SUBMISSION' and submit_review:
        client.request('POST', '/v1/betaAppReviewSubmissions', body={'data': {
            'type': 'betaAppReviewSubmissions', 'relationships': {'build': {
                'data': {'type': 'builds', 'id': row['id']}}}}})
        state = client.detail(row['id'])['attributes']['externalBuildState']
    return state


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['status', 'plan', 'release', 'resume'])
    p.add_argument('--version', default='0.1.0')
    p.add_argument('--build')
    p.add_argument('--audience', choices=['internal', 'external'], default='internal')
    p.add_argument('--notes-file', type=Path)
    p.add_argument('--locale', default='zh-Hans')
    p.add_argument('--submit-review', action='store_true', help='Submit this build for TestFlight Beta Review.')
    p.add_argument('--notify-testers', action='store_true', help='Enable Apple automatic tester notification after approval.')
    p.add_argument('--wait-review', type=int, default=0, help='Optionally poll external readiness for this many seconds.')
    p.add_argument('--timeout', type=int, default=1800, help='Apple processing wait in seconds.')
    args = p.parse_args()
    if args.audience == 'internal' and (args.submit_review or args.notify_testers or args.wait_review):
        p.error('Internal testing does not accept --submit-review, --notify-testers or --wait-review.')
    testflight.release_values(args.version, args.build or '1')
    if args.timeout < 0 or args.wait_review < 0:
        p.error('--timeout must be nonnegative')
    config = settings()
    client = Client()
    group = preflight(client, config, args.audience)
    if args.action == 'status':
        rows = client.builds(config['app_id'], args.version, args.build)
        print(json.dumps({'app_id': config['app_id'], 'group': group['attributes']['name'],
            'builds': [{'build': r['attributes']['version'], 'id': r['id'],
                'processing': r['attributes']['processingState'],
                **client.detail(r['id'])['attributes']} for r in rows]}, ensure_ascii=False, indent=2))
        return
    lock_path = IOS / '.build/testflight/release.lock'
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another local TestFlight release is running.') from None
        if args.action == 'resume' and not args.build:
            p.error('resume requires --build; never resume an implicit latest build')
        build = args.build or next_build(client, config, args.version)
        print(f'Target: iOS {args.version} ({build}), {args.audience} group {group["attributes"]["name"]}', flush=True)
        if args.action == 'plan':
            if args.audience == 'external':
                review_metadata(client, config['app_id'])
            print('API/app/group metadata verified. Encryption configured: ' +
                  str(type(config.get('uses_non_exempt_encryption')) is bool))
            return
        if not args.notes_file:
            p.error('--notes-file is required for release/resume')
        notes = args.notes_file.read_text().strip()
        if not notes or len(notes) > 4000:
            raise ValueError('Testing notes must contain 1–4000 characters.')
        output = IOS / '.build/testflight' / f'{args.version}-{build}'
        if args.action == 'release':
            if client.builds(config['app_id'], args.version, build):
                raise ValueError('Build already exists in Apple. Use resume with this exact build.')
            if output.exists():
                raise ValueError('Local release already exists. Inspect upload status and use resume; do not overwrite.')
            if type(config.get('uses_non_exempt_encryption')) is not bool:
                raise ValueError('Configure the confirmed encryption declaration before uploading a new build.')
            if args.submit_review:
                review_metadata(client, config['app_id'])
            env = {**os.environ, **client.settings}
            cmd = [sys.executable, str(IOS / 'scripts/testflight.py')]
            values = ['--version', args.version, '--build', build, '--audience', args.audience]
            subprocess.run(cmd + ['archive'] + values, env=env, check=True)
            # Persist intent before upload: interrupted uploads must never be blindly retried.
            (output / 'upload-attempt.json').write_text(json.dumps({'version': args.version, 'build': build, 'audience': args.audience}))
            subprocess.run(cmd + ['upload'] + values, env=env, check=True)
        row = client.wait_build(config['app_id'], args.version, build, args.timeout)
        state = finish(client, config, row, group, notes, args.locale, args.submit_review, args.notify_testers, args.audience)
        deadline = time.monotonic() + args.wait_review
        while state in ('WAITING_FOR_BETA_REVIEW', 'IN_BETA_REVIEW', 'BETA_APPROVED', 'READY_FOR_BETA_TESTING') and time.monotonic() < deadline:
            print('External testing: ' + state, flush=True)
            time.sleep(min(30, max(0, deadline - time.monotonic())))
            state = client.detail(row['id'])['attributes']['externalBuildState']
        result = {'version': args.version, 'build': build, 'build_id': row['id'],
                  'audience': args.audience, args.audience + '_state': state, 'testable': state == 'IN_BETA_TESTING',
                  'app_store_submission': False}
        output.mkdir(parents=True, exist_ok=True)
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
        if state in ('BETA_REJECTED', 'EXPIRED', 'PROCESSING_EXCEPTION', 'NOT_APPLICABLE', 'MISSING_EXPORT_COMPLIANCE'):
            raise RuntimeError(f'{args.audience} testing requires attention: ' + state)
        if state != 'IN_BETA_TESTING':
            print(f'Not yet testable for {args.audience} testing. Query status for readiness.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
