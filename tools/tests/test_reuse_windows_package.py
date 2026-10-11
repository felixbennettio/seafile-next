from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import reuse_windows_package as reuse


class WindowsPackageReuseTests(unittest.TestCase):
    def original(self):
        record = {'status': 'completed', 'path': '.github/workflows/desktop.yml', 'conclusion': 'failure', 'head_sha': 'a' * 40}
        stages = {
            'windows': ['Build libsearpc and sync core', 'Build GUI', 'Assemble unsigned portable package', 'Upload seafile-next Windows artifact'],
            'windows-shell': ['Build the retained Explorer extension', 'Remove temporary desktop build and download files'],
            'windows-integration-validation': ['Test DLL loading and isolated registration', 'Remove temporary desktop build and download files'],
        }
        jobs = [{'name': name, 'conclusion': 'failure' if name == 'windows' else 'success',
                 'steps': [{'name': stage, 'conclusion': 'success'} for stage in required]} for name, required in stages.items()]
        jobs[0]['steps'].append({'name': 'Remove temporary desktop build and download files', 'conclusion': 'failure'})
        return record, jobs

    def test_only_an_unchanged_complete_application_with_cleanup_failure_can_be_recovered(self):
        record, jobs = self.original()
        with patch.object(reuse.subprocess, 'check_output', return_value='matching tree\n'):
            self.assertEqual(reuse.verify_build(record, jobs), 'a' * 40)

    def test_failed_application_or_integration_cannot_be_recovered(self):
        for index in range(3):
            record, jobs = self.original(); jobs[index]['steps'][0]['conclusion'] = 'failure'
            with self.subTest(job=index), self.assertRaises(RuntimeError): reuse.verify_build(record, jobs)
        record, jobs = self.original(); jobs.append({'name': 'contracts', 'conclusion': 'failure', 'steps': []})
        with self.assertRaises(RuntimeError): reuse.verify_build(record, jobs)

    def test_changed_sources_incomplete_or_wrong_workflow_are_rejected(self):
        record, jobs = self.original()
        with patch.object(reuse.subprocess, 'check_output', side_effect=['before\n', 'after\n']), self.assertRaises(RuntimeError): reuse.verify_build(record, jobs)
        for field, value in [('status', 'in_progress'), ('path', '.github/workflows/linux.yml'), ('conclusion', 'cancelled')]:
            record, jobs = self.original(); record[field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError): reuse.verify_build(record, jobs)

    def test_cancelled_job_and_missing_cleanup_failure_cannot_be_recovered(self):
        for index in range(3):
            record, jobs = self.original(); jobs[index]['conclusion'] = 'cancelled'
            with self.subTest(job=index), self.assertRaises(RuntimeError): reuse.verify_build(record, jobs)
        for state in ('success', 'skipped'):
            record, jobs = self.original(); jobs[0]['steps'][-1]['conclusion'] = state
            with self.subTest(cleanup=state), self.assertRaises(RuntimeError): reuse.verify_build(record, jobs)


if __name__ == '__main__': unittest.main()
