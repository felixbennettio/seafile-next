from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import reuse_apple_validation as delivery


class NativeDeliveryReuseTests(unittest.TestCase):
    def validation(self):
        record = {'status': 'completed', 'path': '.github/workflows/apple.yml',
                  'head_branch': 'main', 'head_sha': 'a' * 40, 'conclusion': 'failure'}
        steps = [{'name': name, 'conclusion': 'success'} for name in (
            'Test APIs and build native Mac client', 'Test iPhone navigation and sign-in controls',
            'Package non-sandbox Mac client')]
        return record, [{'name': 'build', 'steps': steps}]

    def test_signing_failure_can_reuse_successful_tests_with_matching_sources(self):
        record, jobs = self.validation()
        with patch.object(delivery.subprocess, 'check_output', return_value='unchanged-tree\n'):
            self.assertEqual(delivery.verify_run(record, jobs), 'a' * 40)

    def test_unfinished_or_failed_test_stage_cannot_be_reused(self):
        for condition in ('in_progress', 'failed test', 'unpackaged'):
            record, jobs = self.validation()
            if condition == 'in_progress': record['status'] = 'in_progress'
            else: jobs[0]['steps'][0 if condition == 'failed test' else 2]['conclusion'] = 'failure'
            with self.subTest(condition=condition), self.assertRaises(RuntimeError):
                delivery.verify_run(record, jobs)

    def test_engine_build_changes_require_validation_again(self):
        record, jobs = self.validation()
        with patch.object(delivery.subprocess, 'check_output', side_effect=[
            'app\n', 'app\n', 'sync\n', 'sync\n', 'old engine build\n', 'changed engine build\n']), self.assertRaises(RuntimeError):
            delivery.verify_run(record, jobs)

    def package(self, directory, symlink=None):
        file = Path(directory) / 'app.zip'
        prefix = 'seafile-next.app/Contents/Resources/Engine/'
        with zipfile.ZipFile(file, 'w') as archive:
            executable = zipfile.ZipInfo(prefix + 'seaf-daemon'); executable.external_attr = (stat.S_IFREG | 0o755) << 16
            archive.writestr(executable, b'inert executable fixture')
            library = zipfile.ZipInfo(prefix + 'lib/libfixture.dylib'); library.external_attr = (stat.S_IFREG | 0o644) << 16
            archive.writestr(library, b'inert library fixture')
            if symlink:
                link = zipfile.ZipInfo(prefix + 'lib/current.dylib'); link.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(link, symlink)
        return file

    def test_reused_engine_keeps_executable_and_safe_library_links(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = Path(directory) / 'Engine'; engine.mkdir()
            delivery.extract_engine(self.package(directory, 'libfixture.dylib'), engine)
            self.assertTrue((engine / 'seaf-daemon').stat().st_mode & 0o111)
            self.assertEqual((engine / 'lib/current.dylib').read_bytes(), b'inert library fixture')

    def test_engine_symlink_cannot_escape_the_isolated_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = Path(directory) / 'Engine'; engine.mkdir()
            with self.assertRaises(RuntimeError):
                delivery.extract_engine(self.package(directory, '../../outside'), engine)
