import base64
import datetime
import json
import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import apple_signing_audit as audit
from sanitize_container_index import sanitize_index, INDEX, MANIFEST


class SigningPrivacyTests(unittest.TestCase):
    def test_signed_command_diagnostics_never_go_to_public_output(self):
        source = (Path(__file__).resolve().parents[1] / 'publish_apple.sh').read_text()
        helper = source.split('private_run() {', 1)[1].split('\n}', 1)[0]
        script = 'private_run() {' + helper + '\n}\n'
        script += 'fake() { echo "Private owner fixture"; echo "Private token fixture" >&2; return 1; }\nprivate_run signing-test fake\n'
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(['bash', '-c', script], env={**os.environ, 'signing': temporary}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn('Private owner fixture', result.stdout + result.stderr)
            self.assertNotIn('Private token fixture', result.stdout + result.stderr)
            self.assertIn('Private owner fixture', (Path(temporary) / 'signing-test.log').read_text())

    def test_main_prints_only_verification_status_and_creates_no_default_report(self):
        with patch.object(audit, 'load_cache', return_value={}), \
                patch.object(audit, 'project_inventory', return_value=(['private-certificate'], ['private-bundle'], ['private-profile'])), \
                patch.object(sys, 'argv', ['apple_signing_audit.py']), \
                patch.object(audit.Path, 'write_text') as write, contextlib.redirect_stdout(io.StringIO()) as output:
            audit.main()
        self.assertEqual(output.getvalue(), 'Project signing reuse verification passed.\n')
        write.assert_not_called()

    def test_only_cached_certificates_and_project_identifiers_are_queried(self):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Private owner fixture')])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(1)
                .not_valid_before(now - datetime.timedelta(days=1))
                .not_valid_after(now + datetime.timedelta(days=30)).sign(key, hashes.SHA256()))
        private_key = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                        serialization.NoEncryption()).decode()
        cache = {kind: {'id': kind, 'privateKey': private_key}
                 for kind in ('DISTRIBUTION', 'MAC_INSTALLER_DISTRIBUTION')}
        def api(path, **kwargs):
            if path.startswith('certificates/'):
                return {'data': {'id': path.split('/')[1], 'attributes': {
                    'certificateContent': base64.b64encode(cert.public_bytes(serialization.Encoding.DER)).decode(),
                    'name': 'Private owner fixture'}}}
            if path == 'bundleIds':
                identifier = kwargs['query']['filter[identifier]']
                self.assertIn(identifier, (audit.BUNDLE, audit.BUNDLE + '.fileprovider'))
                return {'data': [{'id': identifier, 'attributes': {'identifier': identifier, 'name': 'Private owner fixture'}}]}
            if path.startswith('bundleIds/') and path.endswith('/profiles'):
                return {'data': [{'id': 'project-profile', 'attributes': {'name': 'Private owner fixture', 'profileState': 'ACTIVE'}}]}
            if path == 'profiles/project-profile/certificates':
                return {'data': [{'id': 'DISTRIBUTION'}]}
            self.fail('Unexpected team-wide query: ' + path)
        with patch.object(audit, 'api', side_effect=api) as calls:
            cached, bundles, profiles = audit.project_inventory(cache)
        summary = audit.public_report(cached, bundles, profiles)
        self.assertEqual(summary, {'signingReuseVerified': True})
        report = json.dumps(summary)
        self.assertEqual(len(cached), 2)
        self.assertNotIn('Private owner fixture', report)
        self.assertNotIn('PRIVATE KEY', report)
        self.assertNotIn('certificateContent', report)
        self.assertNotIn('teamCertificates', report)
        self.assertNotIn('otherSeafileIdentifiers', report)
        self.assertTrue(all(call.args[0] != 'certificates' for call in calls.call_args_list))


class ContainerPrivacyTests(unittest.TestCase):
    def index(self):
        image = {'mediaType': MANIFEST, 'digest': 'sha256:' + 'a' * 64, 'size': 123,
                 'platform': {'architecture': 'amd64', 'os': 'linux'}}
        attestation = {'mediaType': MANIFEST, 'digest': 'sha256:' + 'b' * 64, 'size': 456,
                       'platform': {'architecture': 'unknown', 'os': 'unknown'},
                       'annotations': {'vnd.docker.reference.type': 'attestation-manifest',
                                       'vnd.docker.reference.digest': image['digest']}}
        return {'schemaVersion': 2, 'mediaType': INDEX, 'manifests': [image, attestation]}

    def test_image_manifest_is_preserved_exactly_and_attestation_removed(self):
        original = self.index()
        original['annotations'] = {'private-event': 'Private owner fixture'}
        cleaned, removed = sanitize_index(original)
        self.assertEqual(json.loads(cleaned)['manifests'], original['manifests'][:1])
        self.assertEqual(removed, [original['manifests'][1]['digest']])
        self.assertNotIn(b'Private owner fixture', cleaned)

    def test_unexpected_platform_is_not_silently_deleted(self):
        original = self.index()
        original['manifests'][1]['platform'] = {'architecture': 'arm64', 'os': 'linux'}
        with self.assertRaises(ValueError):
            sanitize_index(original)

    def test_unrelated_attestation_is_rejected(self):
        original = self.index()
        original['manifests'][1]['annotations']['vnd.docker.reference.digest'] = 'sha256:' + 'c' * 64
        with self.assertRaises(ValueError):
            sanitize_index(original)

    def test_no_image_is_rejected(self):
        original = self.index()
        original['manifests'].pop(0)
        with self.assertRaises(ValueError):
            sanitize_index(original)


if __name__ == '__main__':
    unittest.main()
