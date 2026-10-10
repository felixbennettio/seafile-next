import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ci_workspace as workspace
import restore_android_signing as android


class ProtectedWorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / 'home'
        self.checkout = self.root / 'checkout'
        self.runner = self.root / 'runner-temp'
        for directory in (self.home, self.checkout, self.runner):
            directory.mkdir()
        self.environment = {'GITHUB_WORKSPACE': str(self.checkout), 'RUNNER_TEMP': str(self.runner),
                            'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '2', 'BUILD_TMP': '',
                            'GITHUB_REPOSITORY': 'fixture/project'}
        home = patch.object(workspace.Path, 'home', return_value=self.home)
        home.start(); self.addCleanup(home.stop)
        # This is an isolated fake runner home. No actual keys/certificates are
        # used; mock the OS temporary root to model the runner's real layout.
        temporary = patch.object(workspace.tempfile, 'gettempdir', return_value=str(self.runner))
        temporary.start(); self.addCleanup(temporary.stop)
        environment = patch.dict(os.environ, self.environment)
        environment.start(); self.addCleanup(environment.stop)

    def store(self):
        path = workspace.signing_directory('android')
        path.mkdir(parents=True, mode=0o700)
        return path

    def test_signing_home_is_private_and_outside_checkout_and_temporary_root(self):
        store = self.store()
        self.assertEqual(store, workspace.validate_signing_directory(store))
        for excluded in ('RUNNER_TEMP', 'GITHUB_WORKSPACE', 'BUILD_TMP'):
            with self.subTest(excluded=excluded), patch.dict(os.environ, {excluded: str(self.home)}):
                with self.assertRaises(RuntimeError):
                    workspace.validate_signing_directory(store)

    def test_world_readable_or_symlink_signing_directory_is_rejected(self):
        store = self.store()
        store.chmod(0o755)
        with self.assertRaises(RuntimeError): workspace.validate_signing_directory(store)
        store.chmod(0o700)
        link = store.with_name('123-2-apple')
        link.symlink_to(store, target_is_directory=True)
        with self.assertRaises(RuntimeError): workspace.validate_signing_directory(link)

    def test_cleanup_removes_only_its_build_and_signing_files(self):
        build = self.runner / 'client-build.fixture'; build.mkdir()
        (build / 'log').write_text('fixture')
        self.store()
        unrelated = self.home / 'existing.keystore'; unrelated.write_text('inert fixture')
        workspace.cleanup(str(build), 'android')
        self.assertFalse(build.exists())
        self.assertFalse(workspace.signing_directory('android').exists())
        self.assertTrue(unrelated.exists())

    def test_cleanup_refuses_repository_and_unowned_temporary_paths(self):
        for path in (self.checkout, self.runner, self.runner / 'unrelated', self.home):
            with self.subTest(path=path), self.assertRaises(RuntimeError):
                workspace.validate_build_directory(path)

    def test_missing_run_identity_cannot_select_a_shared_signing_store(self):
        with patch.dict(os.environ, {'GITHUB_RUN_ID': ''}), self.assertRaises(RuntimeError):
            workspace.signing_directory('android')

    def test_prepare_exports_only_tracked_sources_without_a_git_directory(self):
        for directory in ('android', 'tools'):
            (self.checkout / directory).mkdir()
        (self.checkout / 'android/gradlew').write_text('inert executable fixture')
        (self.checkout / 'android/gradlew').chmod(0o755)
        (self.checkout / 'tools/helper.py').write_text('# inert tracked fixture')
        commands = (('init', '--quiet'), ('add', 'android', 'tools'),
                    ('-c', 'user.name=Fixture', '-c', 'user.email=fixture@fixture.invalid',
                     '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Fixture'))
        for command in commands:
            subprocess.run(['git', '-C', str(self.checkout), *command], check=True, capture_output=True)
        (self.checkout / 'android/untracked.txt').write_text('inert untracked fixture')
        build = self.runner / 'client-build.fixture'; build.mkdir()
        environment = self.runner / 'environment'
        with patch.dict(os.environ, {'GITHUB_ENV': str(environment)}):
            workspace.prepare(build, 'android')
        self.assertTrue((build / 'source/android/gradlew').stat().st_mode & 0o111)
        self.assertFalse((build / 'source/.git').exists())
        self.assertFalse((build / 'source/android/untracked.txt').exists())
        self.assertIn('SEAFILE_ANDROID_DEBUG_KEYSTORE=' + str(workspace.signing_directory('android')), environment.read_text())
        workspace.cleanup(build, 'android')

    def test_failed_keychain_cleanup_still_removes_private_files_and_build_logs(self):
        store = workspace.signing_directory('apple'); store.mkdir(parents=True, mode=0o700)
        (store / 'signing.keychain-db').write_text('inert fixture')
        build = self.runner / 'client-build.fixture'; build.mkdir()
        with patch.object(workspace.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['security'])), self.assertRaises(RuntimeError):
            workspace.cleanup(build, 'apple')
        self.assertFalse(store.exists())
        self.assertFalse(build.exists())

    def test_android_restore_keeps_the_same_signer_and_hides_diagnostics(self):
        store = self.store(); destination = store / 'android.keystore'
        certificate = b'inert certificate fixture'
        pin = hashlib.sha256(certificate).hexdigest()
        results = [subprocess.CompletedProcess([], 0, 'PrivateKeyEntry', ''),
                   subprocess.CompletedProcess([], 0, certificate, b'')]
        with patch.dict(os.environ, {'ANDROID_DEBUG_KEYSTORE': 'aW5lcnQgZml4dHVyZQ==', 'ANDROID_DEBUG_CERT_SHA256': pin}):
            for _ in range(2):
                with patch.object(android.subprocess, 'run', side_effect=results):
                    self.assertEqual(android.restore(destination), pin)
        self.assertEqual(destination.read_bytes(), b'inert fixture')
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        self.assertFalse(destination.with_name('android.keystore.candidate').exists())

    def test_android_wrong_pin_preserves_the_existing_store_and_removes_candidate(self):
        store = self.store(); destination = store / 'android.keystore'
        destination.write_bytes(b'existing inert fixture')
        results = [subprocess.CompletedProcess([], 0, 'PrivateKeyEntry', ''),
                   subprocess.CompletedProcess([], 0, b'wrong inert certificate', b'')]
        with patch.dict(os.environ, {'ANDROID_DEBUG_KEYSTORE': 'aW5lcnQgZml4dHVyZQ==', 'ANDROID_DEBUG_CERT_SHA256': 'a' * 64}), \
                patch.object(android.subprocess, 'run', side_effect=results), self.assertRaises(ValueError):
            android.restore(destination)
        self.assertEqual(destination.read_bytes(), b'existing inert fixture')
        self.assertFalse(destination.with_name('android.keystore.candidate').exists())
