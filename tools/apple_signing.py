#!/usr/bin/env python3
"""Provision reusable App Store signing material using the existing ASC API key.

Private signing keys are stored only in an AES-GCM encrypted draft-release asset.
The encryption key derives from the ASC private key, which remains in Actions
secrets. Existing team certificates are never revoked.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

BASE = 'https://api.appstoreconnect.apple.com/v1/'
CACHE_TAG = 'internal/apple-signing-v1'
BUNDLE = 'io.felixbennett.seafile'
APP_GROUP = 'group.io.felixbennett.seafile'


def api(path, method='GET', body=None, query=None):
    token = jwt.encode({'iss': os.environ['APP_STORE_CONNECT_ISSUER_ID'], 'iat': int(time.time()), 'exp': int(time.time()) + 600, 'aud': 'appstoreconnect-v1'}, os.environ['APP_STORE_CONNECT_PRIVATE_KEY'], algorithm='ES256', headers={'kid': os.environ['APP_STORE_CONNECT_KEY_ID']})
    url = BASE + path + ('?' + urllib.parse.urlencode(query) if query else '')
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body else None, method=method,
                                 headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            data = response.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as error:
        # API error details can echo names or supplied signing material.
        raise RuntimeError(f'Apple API request returned HTTP {error.code}') from None


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        # Arguments can contain passwords. Report the executable and diagnostic
        # without including the command line in a traceback.
        raise RuntimeError(f'{args[0]} failed (private command output withheld)')
    return result.stdout.strip()


def mask_signing_metadata(record, cert):
    """Register names and certificate identifiers before other steps can log them."""
    values = {record['id'], cert.fingerprint(hashes.SHA1()).hex().upper(),
              cert.fingerprint(hashes.SHA1()).hex().lower()}
    values.update(record.get('attributes', {}).get(field) for field in ('name', 'displayName'))
    for oid in (NameOID.COMMON_NAME, NameOID.ORGANIZATION_NAME, NameOID.EMAIL_ADDRESS):
        values.update(attribute.value for attribute in cert.subject.get_attributes_for_oid(oid))
    for value in sorted(value for value in values if value):
        # Escape workflow command syntax. The runner redacts these values in
        # both downloaded logs and the UI, including later environment dumps.
        escaped = value.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print('::add-mask::' + escaped)


def cache_key():
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=b'seafile-next-signing-cache-v1', info=os.environ['GITHUB_REPOSITORY'].encode()).derive(os.environ['APP_STORE_CONNECT_PRIVATE_KEY'].strip().encode())


def load_cache(directory):
    listing = subprocess.run(['gh', 'release', 'view', CACHE_TAG, '--json', 'isDraft,assets'], capture_output=True, text=True)
    if listing.returncode:
        # Only an explicit 404 means a new cache. Network/authentication failures
        # must not create redundant certificates.
        if 'not found' not in listing.stderr.lower():
            raise RuntimeError('Cannot read the signing cache: ' + listing.stderr.strip())
        return {}
    release = json.loads(listing.stdout)
    if not release['isDraft']:
        raise RuntimeError('The signing cache release must stay a draft')
    if not any(asset['name'] == 'signing.enc' for asset in release['assets']):
        return {}
    run('gh', 'release', 'download', CACHE_TAG, '--pattern', 'signing.enc', '--dir', str(directory), '--clobber')
    data = (directory / 'signing.enc').read_bytes()
    try:
        clear = AESGCM(cache_key()).decrypt(data[:12], data[12:], os.environ['GITHUB_REPOSITORY'].encode())
    except Exception:
        raise RuntimeError('Cannot decrypt the signing cache. Restore its original ASC private key or migrate the encrypted cache before rotating the key.') from None
    return json.loads(clear)


def save_cache(cache, directory):
    nonce = secrets.token_bytes(12)
    file = directory / 'signing.enc'
    file.write_bytes(nonce + AESGCM(cache_key()).encrypt(nonce, json.dumps(cache).encode(), os.environ['GITHUB_REPOSITORY'].encode()))
    listing = subprocess.run(['gh', 'release', 'view', CACHE_TAG], capture_output=True)
    if listing.returncode:
        run('gh', 'release', 'create', CACHE_TAG, '--target', os.environ['GITHUB_SHA'], '--draft', '--title', 'Internal encrypted Apple signing cache', '--notes', 'Encrypted reusable CI signing keys. Keep this release as a draft. It contains no installable application.')
    run('gh', 'release', 'upload', CACHE_TAG, str(file), '--clobber')


def certificate(kind, cache, directory):
    item = cache.get(kind)
    if not item:
        raise RuntimeError('Missing cached signing key for ' + kind + '; restore the signing cache instead of creating another certificate')
    record = api('certificates/' + item['id'])['data']
    cert = x509.load_der_x509_certificate(base64.b64decode(record['attributes']['certificateContent']))
    mask_signing_metadata(record, cert)
    key = serialization.load_pem_private_key(item['privateKey'].encode(), password=None)
    if key.public_key().public_numbers() != cert.public_key().public_numbers():
        raise RuntimeError('Cached signing key does not match ' + kind)
    if cert.not_valid_after_utc > datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=7):
        print('Reusing the existing signing certificate.')
        return record, key, cert
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = x509.CertificateSigningRequestBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Seafile Next CI')])).sign(key, hashes.SHA256())
    record = api('certificates', 'POST', {'data': {'type': 'certificates', 'attributes': {'certificateType': kind, 'csrContent': csr.public_bytes(serialization.Encoding.PEM).decode()}}})['data']
    cache[kind] = {'id': record['id'], 'privateKey': key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()}
    # Persist immediately, so a failed build never loses the newly created key.
    save_cache(cache, directory)
    cert = x509.load_der_x509_certificate(base64.b64decode(record['attributes']['certificateContent']))
    mask_signing_metadata(record, cert)
    return record, key, cert


def profile(bundle_id, kind, certificate_id, directory, prefix='seafile-next App Groups v1 CI'):
    name = f'{prefix} {kind} {certificate_id}'
    records = api('profiles', query={'filter[name]': name, 'limit': '200'})['data']
    valid = None
    for record in records:
        if record['attributes']['profileState'] != 'ACTIVE':
            continue
        expiration = datetime.datetime.fromisoformat(record['attributes']['expirationDate'].replace('Z', '+00:00'))
        if expiration <= datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=7):
            continue
        certificate_ids = {item['id'] for item in api('profiles/' + record['id'] + '/certificates')['data']}
        bundle = api('profiles/' + record['id'] + '/bundleId')['data']
        if certificate_id in certificate_ids and bundle['id'] == bundle_id and record['attributes']['profileType'] == kind:
            valid = record
            break
    if valid is None:
        # The name is stable across application versions; only invalid/expired
        # material requires a new profile, never each build or push.
        valid = api('profiles', 'POST', {'data': {'type': 'profiles', 'attributes': {'name': name, 'profileType': kind}, 'relationships': {'bundleId': {'data': {'type': 'bundleIds', 'id': bundle_id}}, 'certificates': {'data': [{'type': 'certificates', 'id': certificate_id}]}}}})['data']
        print('Updated the project signing profile.')
    else:
        print('Reusing the existing project signing profile.')
    content = base64.b64decode(valid['attributes']['profileContent'])
    for value in (valid['id'], valid['attributes']['uuid'], valid['attributes'].get('name')):
        if value:
            print('::add-mask::' + value.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A'))
    decoded = subprocess.run(['security', 'cms', '-D'], input=content, capture_output=True)
    if decoded.returncode:
        raise RuntimeError('Cannot decode the provisioning profile to verify its App Group')
    groups = plistlib.loads(decoded.stdout).get('Entitlements', {}).get('com.apple.security.application-groups', [])
    if APP_GROUP not in groups:
        raise RuntimeError(f'{kind} profile does not authorize {APP_GROUP}; bind the registered group to this App ID before publishing')
    extension = '.mobileprovision' if kind.startswith('IOS') else '.provisionprofile'
    for location in ['Library/MobileDevice/Provisioning Profiles', 'Library/Developer/Xcode/UserData/Provisioning Profiles']:
        path = Path.home() / location
        path.mkdir(parents=True, exist_ok=True)
        (path / (valid['attributes']['uuid'] + extension)).write_bytes(content)
    return valid['attributes']['uuid']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', required=True)
    args = parser.parse_args()
    directory = Path(args.directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    cache = load_cache(directory)
    if not cache:
        raise RuntimeError('The persistent Apple signing cache is missing. Restore it before publishing; no new certificate was created.')
    distribution, key, cert = certificate('DISTRIBUTION', cache, directory)
    installer, installer_key, installer_cert = certificate('MAC_INSTALLER_DISTRIBUTION', cache, directory)
    password = secrets.token_urlsafe(32)
    print('::add-mask::' + password)
    keychain = directory / 'signing.keychain-db'
    run('security', 'create-keychain', '-p', password, str(keychain))
    run('security', 'set-keychain-settings', '-lut', '21600', str(keychain))
    run('security', 'unlock-keychain', '-p', password, str(keychain))
    existing_keychains = json.loads(run('/usr/bin/python3', '-c', 'import subprocess,shlex,json; print(json.dumps(shlex.split(subprocess.check_output(["security","list-keychains","-d","user"],text=True))))'))
    run('security', 'list-keychains', '-d', 'user', '-s', str(keychain), *existing_keychains)
    for name, private_key, certificate_data in [('distribution', key, cert), ('installer', installer_key, installer_cert)]:
        file = directory / (name + '.p12')
        # Apple's Security import uses the legacy PKCS#12 algorithms; the
        # persistent cache still uses modern authenticated AES-GCM encryption.
        encryption = (serialization.PrivateFormat.PKCS12.encryption_builder()
                      .kdf_rounds(50000)
                      .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
                      .hmac_hash(hashes.SHA1()).build(password.encode()))
        file.write_bytes(pkcs12.serialize_key_and_certificates(name.encode(), private_key, certificate_data, None, encryption))
        file.chmod(0o600)
        run('security', 'import', str(file), '-k', str(keychain), '-P', password, '-T', '/usr/bin/codesign', '-T', '/usr/bin/productbuild')
    run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, str(keychain))
    bundles = [item for item in api('bundleIds', query={'filter[identifier]': BUNDLE})['data']
               if item['attributes']['identifier'] == BUNDLE]
    if len(bundles) != 1:
        raise RuntimeError('Cannot uniquely find the registered universal Bundle ID')
    ios = profile(bundles[0]['id'], 'IOS_APP_STORE', distribution['id'], directory)
    mac = profile(bundles[0]['id'], 'MAC_APP_STORE', distribution['id'], directory)
    files_bundle = BUNDLE + '.fileprovider'
    files_bundles = [item for item in api('bundleIds', query={'filter[identifier]': files_bundle})['data']
                     if item['attributes']['identifier'] == files_bundle]
    if len(files_bundles) != 1:
        raise RuntimeError('Cannot uniquely find the registered Seafile File Provider App ID; identifier registration requires explicit configuration')
    ios_files = profile(files_bundles[0]['id'], 'IOS_APP_STORE', distribution['id'], directory, 'seafile-next Files App Groups v1 CI')
    mac_files = profile(files_bundles[0]['id'], 'MAC_APP_STORE', distribution['id'], directory, 'seafile-next Files App Groups v1 CI')
    sha1 = cert.fingerprint(hashes.SHA1()).hex().upper()
    installer_sha1 = installer_cert.fingerprint(hashes.SHA1()).hex().upper()
    values = {'APPLE_IOS_PROFILE': ios, 'APPLE_MAC_PROFILE': mac, 'APPLE_IOS_FILES_PROFILE': ios_files, 'APPLE_MAC_FILES_PROFILE': mac_files, 'APPLE_DISTRIBUTION_IDENTITY': sha1, 'APPLE_DISTRIBUTION_SHA1': sha1, 'APPLE_INSTALLER_SHA1': installer_sha1, 'APPLE_SIGNING_KEYCHAIN': str(keychain)}
    with open(os.environ['GITHUB_ENV'], 'a') as output:
        for key, value in values.items():
            output.write(key + '=' + value + '\n')
    for platform, provision in [('ios', ios), ('mac', mac)]:
        options = {'method': 'app-store-connect', 'teamID': os.environ['APPLE_TEAM_ID'], 'signingStyle': 'manual', 'signingCertificate': sha1, 'provisioningProfiles': {BUNDLE: provision, files_bundle: ios_files if platform == 'ios' else mac_files}, 'manageAppVersionAndBuildNumber': False, 'uploadSymbols': True, 'destination': 'export'}
        if platform == 'mac':
            options['installerSigningCertificate'] = installer_sha1
        (directory / (platform + '-export.plist')).write_bytes(plistlib.dumps(options))
    api_key = directory / ('AuthKey_' + os.environ['APP_STORE_CONNECT_KEY_ID'] + '.p8')
    api_key.write_text(os.environ['APP_STORE_CONNECT_PRIVATE_KEY'])
    api_key.chmod(0o600)
    print('Reusable App Store signing certificates and iOS/macOS profiles are installed.')


if __name__ == '__main__':
    main()
