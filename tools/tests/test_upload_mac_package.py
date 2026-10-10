from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import upload_mac_package as upload


class MacUploadTests(unittest.TestCase):
    def test_transporter_uses_existing_private_key_and_temporary_diagnostics(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); private = root / 'private'; private.mkdir()
            key = private / 'AuthKey_FIXTURE.p8'
            key.write_text('inert credential fixture, not a key'); key.chmod(0o600)
            package = root / 'fixture.pkg'; package.write_bytes(b'inert package')
            logs = root / 'diagnostics'; logs.mkdir()
            env = {'SEAFILE_SIGNING_DIR': str(private), 'APP_STORE_CONNECT_KEY_ID': 'FIXTURE',
                   'APP_STORE_CONNECT_ISSUER_ID': 'fixture-issuer', 'SIGNING_LOG_DIR': str(logs)}
            with patch.dict(os.environ, env), patch.object(upload, 'validate_signing_directory', return_value=private), \
                    patch.object(upload.sys if hasattr(upload, 'sys') else sys, 'argv', ['upload', str(package)]), \
                    patch.object(upload.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run, \
                    self.assertRaises(SystemExit) as result:
                upload.main()
            self.assertEqual(result.exception.code, 0)
            self.assertEqual(run.call_args.kwargs['cwd'], private)
            self.assertEqual(run.call_args.kwargs['timeout'], 1200)
            link = private / 'private_keys' / key.name
            self.assertTrue(link.is_symlink())
            self.assertEqual(link.resolve(), key)
            self.assertFalse(any(logs.iterdir()))
            command = run.call_args.args[0]
            self.assertIn('iTMSTransporter', command)
            self.assertIn(str(package), command)


if __name__ == '__main__':
    unittest.main()
