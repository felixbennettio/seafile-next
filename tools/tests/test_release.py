import base64
import datetime
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from package_unsigned_ios import macho_platforms
from publish_release import validate_package
import apple_signing
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


def executable(platform):
    return struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0) + struct.pack('<IIIIII', 0x32, 24, platform, 0, 0, 0)


class ReleasePackageTests(unittest.TestCase):
    def test_device_platform_is_distinct_from_simulator(self):
        self.assertEqual(macho_platforms(executable(2)), {2})
        self.assertEqual(macho_platforms(executable(7)), {7})

    def test_truncated_executable_rejected(self):
        with self.assertRaises((ValueError, struct.error)):
            macho_platforms(executable(2)[:-5])

    def ipa(self, directory, platform=2, extension=True, signature=False):
        file = Path(directory) / 'app.ipa'
        with zipfile.ZipFile(file, 'w') as z:
            info = {'CFBundleSupportedPlatforms': ['iPhoneOS'], 'CFBundleExecutable': 'app'}
            z.writestr('Payload/app.app/Info.plist', plistlib.dumps(info))
            z.writestr('Payload/app.app/app', executable(platform))
            if extension:
                z.writestr('Payload/app.app/PlugIns/Files.appex/Info.plist', plistlib.dumps(info))
                z.writestr('Payload/app.app/PlugIns/Files.appex/app', executable(platform))
            if signature:
                z.writestr('Payload/app.app/embedded.mobileprovision', b'not public')
        return file

    def test_complete_unsigned_device_ipa_accepted(self):
        with tempfile.TemporaryDirectory() as d:
            validate_package('ios', self.ipa(d))

    def test_simulator_cannot_be_renamed_to_ipa(self):
        with tempfile.TemporaryDirectory() as d, self.assertRaises(RuntimeError):
            validate_package('ios', self.ipa(d, platform=7))

    def test_profile_cannot_leak_into_unsigned_download(self):
        with tempfile.TemporaryDirectory() as d, self.assertRaises(RuntimeError):
            validate_package('ios', self.ipa(d, signature=True))

    def test_file_provider_cannot_be_omitted(self):
        with tempfile.TemporaryDirectory() as d, self.assertRaises(RuntimeError):
            validate_package('ios', self.ipa(d, extension=False))

    def test_incomplete_windows_runtime_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            file = Path(d) / 'windows.zip'
            with zipfile.ZipFile(file, 'w') as z:
                z.writestr('seafile-applet.exe', b'MZ')
            with self.assertRaises(RuntimeError):
                validate_package('windows', file)


class SigningReuseTests(unittest.TestCase):
    def setUp(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'CI unit fixture')])
        now = datetime.datetime.now(datetime.timezone.utc)
        self.cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                     .public_key(self.key.public_key()).serial_number(1)
                     .not_valid_before(now - datetime.timedelta(days=1))
                     .not_valid_after(now + datetime.timedelta(days=30)).sign(self.key, hashes.SHA256()))
        self.record = {'id': 'existing', 'attributes': {'certificateContent': base64.b64encode(self.cert.public_bytes(serialization.Encoding.DER)).decode()}}
        self.cache = {'DISTRIBUTION': {'id': 'existing', 'privateKey': self.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()}}

    def test_valid_certificate_reused_without_post(self):
        with patch.object(apple_signing, 'api', return_value={'data': self.record}) as api, patch.object(apple_signing, 'save_cache') as save:
            record, key, cert = apple_signing.certificate('DISTRIBUTION', self.cache, Path('/unused'))
            self.assertEqual(record['id'], 'existing')
            api.assert_called_once_with('certificates/existing')
            save.assert_not_called()

    def test_missing_cache_never_creates_certificate(self):
        with patch.object(apple_signing, 'api') as api, self.assertRaises(RuntimeError):
            apple_signing.certificate('DISTRIBUTION', {}, Path('/unused'))
        api.assert_not_called()

    def test_key_mismatch_never_creates_certificate(self):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.cache['DISTRIBUTION']['privateKey'] = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
        with patch.object(apple_signing, 'api', return_value={'data': self.record}) as api, self.assertRaises(RuntimeError):
            apple_signing.certificate('DISTRIBUTION', self.cache, Path('/unused'))
        api.assert_called_once_with('certificates/existing')


if __name__ == '__main__':
    unittest.main()
