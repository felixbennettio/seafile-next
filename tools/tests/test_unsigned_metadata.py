from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import struct
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from package_unsigned_ios import remove_team_prefixes
from publish_release import validate_package


class UnsignedMetadataPrivacyTests(unittest.TestCase):
    def test_release_rejects_building_team_metadata_in_host_or_extension(self):
        binary = struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0) + struct.pack('<IIIIII', 0x32, 24, 2, 0, 0, 0)
        with tempfile.TemporaryDirectory(prefix='seafile-unsigned-fixture-') as temporary:
            package = Path(temporary) / 'app.ipa'
            bundles = ['Payload/app.app', 'Payload/app.app/PlugIns/Files.appex', 'Payload/app.app/PlugIns/Share.appex']
            for leaking in [None, *bundles]:
                with zipfile.ZipFile(package, 'w') as archive:
                    for bundle in bundles:
                        group = 'FIXTURE123.io.felixbennett.seafile.accounts' if bundle == leaking else '$(AppIdentifierPrefix)io.felixbennett.seafile.accounts'
                        archive.writestr(bundle + '/Info.plist', plistlib.dumps({
                            'CFBundleSupportedPlatforms': ['iPhoneOS'], 'CFBundleExecutable': 'app', 'SeafileKeychainGroup': group,
                        }))
                        archive.writestr(bundle + '/app', binary)
                if leaking is None:
                    validate_package('ios', package)
                else:
                    with self.assertRaisesRegex(RuntimeError, 'building-team'):
                        validate_package('ios', package)

    def test_host_and_both_extensions_use_a_resigning_placeholder(self):
        with tempfile.TemporaryDirectory(prefix='seafile-unsigned-fixture-') as temporary:
            app = Path(temporary) / 'app.app'
            bundles = [app, app / 'PlugIns/Files.appex', app / 'PlugIns/Share.appex']
            for bundle in bundles:
                bundle.mkdir(parents=True)
                (bundle / 'Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleVersion': '1.2.3', 'SeafileSharedCredentials': True,
                    'SeafileKeychainGroup': 'FIXTURE123.io.felixbennett.seafile.accounts',
                }))
            remove_team_prefixes(app)
            for bundle in bundles:
                values = plistlib.loads((bundle / 'Info.plist').read_bytes())
                self.assertEqual(values['SeafileKeychainGroup'], '$(AppIdentifierPrefix)io.felixbennett.seafile.accounts')
                self.assertTrue(values['SeafileSharedCredentials'])
                self.assertEqual(values['CFBundleVersion'], '1.2.3')
                self.assertNotIn(b'FIXTURE123', (bundle / 'Info.plist').read_bytes())

    def test_framework_metadata_and_external_symlinks_are_untouched(self):
        with tempfile.TemporaryDirectory(prefix='seafile-unsigned-fixture-') as temporary:
            root = Path(temporary)
            app = root / 'app.app'
            framework = app / 'Frameworks/Core.framework'; framework.mkdir(parents=True)
            data = plistlib.dumps({'CFBundleExecutable': 'Core'}, fmt=plistlib.FMT_BINARY)
            (framework / 'Info.plist').write_bytes(data)
            external = root / 'external.plist'; external.write_bytes(data)
            alias = app / 'Alias'; alias.mkdir(); (alias / 'Info.plist').symlink_to(external)
            remove_team_prefixes(app)
            self.assertEqual((framework / 'Info.plist').read_bytes(), data)
            self.assertEqual(external.read_bytes(), data)


if __name__ == '__main__': unittest.main()
