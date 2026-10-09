#!/usr/bin/env python3
"""Verify project signing without publishing a team-wide inventory or names."""
import argparse
import base64
import json
from pathlib import Path
import tempfile
import urllib.parse

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from apple_signing import api, load_cache, BUNDLE


def records(path, query=None):
    result = []
    page = api(path, query={'limit': '200', **(query or {})})
    while True:
        result.extend(page['data'])
        next_url = page.get('links', {}).get('next')
        if not next_url:
            return result
        parsed = urllib.parse.urlparse(next_url)
        if parsed.netloc != 'api.appstoreconnect.apple.com':
            raise RuntimeError('Unexpected Apple pagination host')
        page = api(parsed.path.removeprefix('/v1/'), query=dict(urllib.parse.parse_qsl(parsed.query)))


def project_inventory(cache):
    cached = []
    for kind in ('DISTRIBUTION', 'MAC_INSTALLER_DISTRIBUTION'):
        item = cache.get(kind)
        if not item:
            raise RuntimeError('Missing cached signing key: ' + kind)
        record = api('certificates/' + item['id'])['data']
        if record['id'] != item['id']:
            raise RuntimeError('Cached certificate is unavailable: ' + kind)
        cert = x509.load_der_x509_certificate(base64.b64decode(record['attributes']['certificateContent']))
        key = serialization.load_pem_private_key(item['privateKey'].encode(), password=None)
        if key.public_key().public_numbers() != cert.public_key().public_numbers():
            raise RuntimeError('Cached private key does not match ' + kind)
        cached.append({'type': kind, 'id': item['id'], 'keyMatches': True, 'expires': cert.not_valid_after_utc.isoformat()})
    bundles = []
    for identifier in (BUNDLE, BUNDLE + '.fileprovider'):
        matches = records('bundleIds', {'filter[identifier]': identifier})
        if len(matches) != 1 or matches[0]['attributes']['identifier'] != identifier:
            raise RuntimeError('Requested project identifier is unavailable')
        bundles.extend(matches)
    profiles = []
    for bundle in bundles:
        for r in records('bundleIds/' + bundle['id'] + '/profiles'):
            certs = api('profiles/' + r['id'] + '/certificates')['data']
            fields = ('name', 'profileType', 'profileState', 'createdDate', 'expirationDate')
            profiles.append({'id': r['id'], 'bundle': bundle['attributes']['identifier'],
                             **{k: r['attributes'].get(k) for k in fields},
                             'certificates': [c['id'] for c in certs]})
    return cached, bundles, profiles


def public_report(cached, bundles, profiles):
    # Use allowlists: Apple can add more attributes, including owner names.
    fields = ('id', 'bundle', 'profileType', 'profileState', 'createdDate', 'expirationDate', 'certificates')
    return {'cachedCertificates': cached,
            'identifiers': [{'id': r['id'], **{k: r['attributes'].get(k) for k in ('identifier', 'platform')}} for r in bundles],
            'profiles': [{k: p.get(k) for k in fields} for p in profiles]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', default='signing-audit.json')
    parser.add_argument('--cleanup-invalid-profiles', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temporary:
        cache = load_cache(Path(temporary))
    cached, bundles, profiles = project_inventory(cache)
    report = public_report(cached, bundles, profiles)
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
        report['profiles'] = [p for p in report['profiles'] if p['id'] not in removed]
    Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
