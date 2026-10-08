#!/usr/bin/env python3
"""Read-only signing inventory. Never exports private keys or profile contents."""
import argparse
import base64
import json
from pathlib import Path
import tempfile
import urllib.parse

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from apple_signing import api, load_cache, BUNDLE


def records(path):
    result = []
    page = api(path, query={'limit': '200'})
    while True:
        result.extend(page['data'])
        next_url = page.get('links', {}).get('next')
        if not next_url:
            return result
        parsed = urllib.parse.urlparse(next_url)
        if parsed.netloc != 'api.appstoreconnect.apple.com':
            raise RuntimeError('Unexpected Apple pagination host')
        page = api(parsed.path.removeprefix('/v1/'), query=dict(urllib.parse.parse_qsl(parsed.query)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', default='signing-audit.json')
    parser.add_argument('--cleanup-invalid-profiles', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temporary:
        cache = load_cache(Path(temporary))
    certificates = records('certificates')
    cached = []
    for kind in ('DISTRIBUTION', 'MAC_INSTALLER_DISTRIBUTION'):
        item = cache.get(kind)
        if not item:
            raise RuntimeError('Missing cached signing key: ' + kind)
        matches = [r for r in certificates if r['id'] == item['id']]
        if len(matches) != 1:
            raise RuntimeError('Cached certificate is unavailable: ' + kind)
        cert = x509.load_der_x509_certificate(base64.b64decode(matches[0]['attributes']['certificateContent']))
        key = serialization.load_pem_private_key(item['privateKey'].encode(), password=None)
        if key.public_key().public_numbers() != cert.public_key().public_numbers():
            raise RuntimeError('Cached private key does not match ' + kind)
        cached.append({'type': kind, 'id': item['id'], 'keyMatches': True, 'expires': cert.not_valid_after_utc.isoformat()})
    bundles = [r for r in records('bundleIds') if r['attributes']['identifier'] in (BUNDLE, BUNDLE + '.fileprovider')]
    ids = {r['id'] for r in bundles}
    profiles = []
    for r in records('profiles'):
        bundle = api('profiles/' + r['id'] + '/bundleId')['data']
        if bundle['id'] not in ids:
            continue
        certs = api('profiles/' + r['id'] + '/certificates')['data']
        fields = ('name', 'profileType', 'profileState', 'createdDate', 'expirationDate')
        profiles.append({'id': r['id'], 'bundle': bundle['attributes']['identifier'],
                         **{k: r['attributes'].get(k) for k in fields},
                         'certificates': [c['id'] for c in certs]})
    safe_certificates = [{'id': r['id'], **{k: r['attributes'].get(k) for k in ('name', 'displayName', 'certificateType', 'expirationDate')}} for r in certificates]
    report = {'cachedCertificates': cached, 'teamCertificates': safe_certificates,
              'identifiers': [{'id': r['id'], **{k: r['attributes'].get(k) for k in ('identifier', 'name', 'platform')}} for r in bundles],
              'profiles': profiles}
    if args.cleanup_invalid_profiles:
        # These four pre-App-Group CI profiles are proven invalid. Do not revoke
        # any certificates or touch profiles belonging to another application.
        legacy = {
            'REDACTED_RETIRED_PROFILE_1': ('MAC_APP_STORE', BUNDLE, 'seafile-next CI '),
            'REDACTED_RETIRED_PROFILE_2': ('IOS_APP_STORE', BUNDLE, 'seafile-next CI '),
            'REDACTED_RETIRED_PROFILE_3': ('IOS_APP_STORE', BUNDLE + '.fileprovider', 'seafile-next Files CI '),
            'REDACTED_RETIRED_PROFILE_4': ('MAC_APP_STORE', BUNDLE + '.fileprovider', 'seafile-next Files CI '),
        }
        removed = []
        distribution_id = cache['DISTRIBUTION']['id']
        for p in profiles:
            if p['id'] not in legacy:
                continue
            kind, bundle, prefix = legacy[p['id']]
            if p['profileState'] != 'INVALID' or p['profileType'] != kind or p['bundle'] != bundle or p['name'] != prefix + kind + ' ' + distribution_id or p['certificates'] != [distribution_id]:
                raise RuntimeError('Refusing to delete changed profile metadata: ' + p['id'])
            api('profiles/' + p['id'], 'DELETE')
            removed.append(p['id'])
        report['removedInvalidProfiles'] = removed
        report['profiles'] = [p for p in profiles if p['id'] not in removed]
    Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
