import contextlib
import io
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_apple_archive as verify


class EmbeddedExtensionValidationTests(unittest.TestCase):
    def check_archive(self, identifiers, mac=False):
        with tempfile.TemporaryDirectory(prefix='seafile-archive-fixture-') as temporary:
            archive = Path(temporary)
            host = archive / 'Products/Applications/seafile-next.app'
            content = host / 'Contents' if mac else host
            content.mkdir(parents=True)
            (content / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': verify.BUNDLE}))
            for index, identifier in enumerate(identifiers):
                extension = content / 'PlugIns' / (str(index) + '.appex')
                location = extension / 'Contents' if mac else extension
                location.mkdir(parents=True)
                info = {'CFBundleIdentifier': identifier, 'NSExtension': {}}
                if identifier.endswith('.fileprovider'):
                    info['NSExtension']['NSExtensionFileProviderDocumentGroup'] = verify.GROUP
                if identifier.endswith('.share'):
                    info['NSExtension'].update(NSExtensionPointIdentifier='com.apple.share-services',
                                             NSExtensionPrincipalClass='SeafileShare.ShareViewController')
                (location / 'Info.plist').write_bytes(plistlib.dumps(info))
            def configuration(executable, *args):
                values = {'com.apple.security.application-groups': [verify.GROUP]}
                return values if executable == 'codesign' else {'Entitlements': values}
            with patch.object(sys, 'argv', ['verify', str(archive)]), \
                 patch.object(verify, 'command_plist', side_effect=configuration), \
                 contextlib.redirect_stdout(io.StringIO()):
                verify.main()

    def test_ios_requires_both_embedded_extensions(self):
        files, share = verify.BUNDLE + '.fileprovider', verify.BUNDLE + '.share'
        self.check_archive([files, share])
        with self.assertRaisesRegex(RuntimeError, 'missing'):
            self.check_archive([files])

    def test_duplicate_or_unexpected_extension_is_rejected(self):
        files, share = verify.BUNDLE + '.fileprovider', verify.BUNDLE + '.share'
        for identifiers in ([files, share, share], [files, share, 'io.fixture.unexpected']):
            with self.assertRaisesRegex(RuntimeError, 'Unexpected or duplicated'):
                self.check_archive(identifiers)

    def test_mac_only_requires_its_file_provider(self):
        self.check_archive([verify.BUNDLE + '.fileprovider'], mac=True)


if __name__ == '__main__': unittest.main()
