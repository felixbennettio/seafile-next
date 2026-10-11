import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from normalize_apple_bundle_permissions import normalize


class BundlePermissionsTests(unittest.TestCase):
    def test_private_mask_cannot_leave_payload_unreadable_after_installation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / 'archive/Products/Applications/Fixture.app'
            signatures = app / 'Contents/_CodeSignature'
            signatures.mkdir(parents=True, mode=0o700)
            resource = signatures / 'CodeResources'; resource.write_text('inert public signature fixture'); resource.chmod(0o600)
            binary = app / 'Contents/MacOS/Fixture'; binary.parent.mkdir(); binary.write_bytes(b'inert executable'); binary.chmod(0o700)
            private = root / 'private-diagnostics'; private.mkdir(mode=0o700)
            log = private / 'signing.log'; log.write_text('inert private fixture'); log.chmod(0o600)
            normalize(root / 'archive')
            self.assertEqual(stat.S_IMODE(signatures.stat().st_mode), 0o755)
            self.assertEqual(stat.S_IMODE(resource.stat().st_mode), 0o644)
            self.assertEqual(stat.S_IMODE(binary.stat().st_mode), 0o755)
            self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)

    def test_internal_framework_links_are_preserved_but_external_links_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / 'archive/Products/Applications/Fixture.app'; app.mkdir(parents=True)
            (app / 'Versions/A').mkdir(parents=True)
            (app / 'Versions/Current').symlink_to('A')
            normalize(root / 'archive')
            self.assertTrue((app / 'Versions/Current').is_symlink())
            target = root / 'outside'; target.write_text('inert private fixture'); target.chmod(0o600)
            (app / 'external').symlink_to(target)
            with self.assertRaises(RuntimeError): normalize(root / 'archive')
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)

    def test_private_key_cannot_be_made_public_as_a_payload_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / 'archive/Products/Applications/Fixture.app'; app.mkdir(parents=True)
            key = app / 'fixture.p8'; key.write_text('inert fixture, not a key'); key.chmod(0o600)
            with self.assertRaises(RuntimeError): normalize(root / 'archive')
            self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)


if __name__ == '__main__':
    unittest.main()
