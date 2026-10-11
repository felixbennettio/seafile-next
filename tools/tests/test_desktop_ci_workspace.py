import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import desktop_ci_workspace as desktop


class DesktopWorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.checkout = self.root / 'repository'; self.checkout.mkdir()
        self.runner = self.root / 'runner'; self.runner.mkdir()
        self.build = self.runner / 'desktop-build.fixture'; self.build.mkdir()
        self.environment = patch.dict(os.environ, {'RUNNER_TEMP': str(self.runner),
            'GITHUB_WORKSPACE': str(self.checkout), 'GITHUB_ENV': str(self.runner / 'environment')})
        self.environment.start(); self.addCleanup(self.environment.stop)

    def test_cleanup_root_cannot_be_checkout_unrelated_or_symlinked(self):
        link = self.runner / 'desktop-build.link'; link.symlink_to(self.build, target_is_directory=True)
        for candidate in (self.checkout, self.runner, self.runner / 'unrelated', link):
            with self.subTest(candidate=candidate), self.assertRaises(RuntimeError): desktop.validate(candidate)
        self.assertEqual(desktop.validate(self.build), self.build)

    def test_source_export_preserves_executables_without_copying_git_or_untracked_files(self):
        for name in ('desktop', 'sync', 'tools'):
            (self.checkout / name).mkdir()
            (self.checkout / name / 'tracked').write_text('fixture')
        script = self.checkout / 'tools/helper.sh'; script.write_text('fixture'); script.chmod(0o755)
        for command in (('init', '--quiet'), ('add', '.'),
            ('-c', 'user.name=Fixture', '-c', 'user.email=fixture@fixture.invalid', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Fixture')):
            subprocess.run(['git', '-C', str(self.checkout), *command], check=True, capture_output=True)
        (self.checkout / 'desktop/untracked').write_text('fixture')
        desktop.prepare(self.build, 'contracts')
        self.assertFalse((self.build / 'source/.git').exists())
        self.assertFalse((self.build / 'source/desktop/untracked').exists())
        self.assertTrue((self.build / 'source/tools/helper.sh').stat().st_mode & 0o111)
        self.assertIn('DESKTOP_BUILD_SOURCE=' + str(self.build / 'source'), (self.runner / 'environment').read_text())

    def test_invalid_temporary_parent_is_rejected_before_export(self):
        outside = self.root / 'desktop-build.outside'; outside.mkdir()
        with patch.object(desktop, 'export_tree') as export:
            with self.assertRaises(RuntimeError): desktop.prepare(outside, 'contracts')
            export.assert_not_called()

    def test_cleanup_removes_readonly_downloaded_manifests_and_preserves_the_checkout(self):
        manifest = self.build / 'depot_tools/.cipd_bin/.cipd/pkgs/fixture/.cipdpkg/manifest.json'
        manifest.parent.mkdir(parents=True); manifest.write_text('inert downloaded fixture'); manifest.chmod(0o400)
        preserved = self.checkout / 'keep'; preserved.write_text('keep source')
        desktop.cleanup(self.build)
        self.assertFalse(self.build.exists())
        self.assertEqual(preserved.read_text(), 'keep source')
