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
        # Apple's search can also return a File Provider identifier sharing the
        # app's prefix. Keep only the exact requested application identifier.
        matches = [r for r in records('bundleIds', {'filter[identifier]': identifier})
                   if r['attributes']['identifier'] == identifier]
        if len(matches) != 1:
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
    # Signing metadata is operational input, not a public build artifact.
    # Do not publish IDs, owners, expiry dates, counts or profile inventories.
    return {'signingReuseVerified': True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', help='Optional status-only report; never contains signing metadata')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temporary:
        cache = load_cache(Path(temporary))
    cached, bundles, profiles = project_inventory(cache)
    report = public_report(cached, bundles, profiles)
    if args.output:
        Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print('Project signing reuse verification passed.')


if __name__ == '__main__':
    main()
