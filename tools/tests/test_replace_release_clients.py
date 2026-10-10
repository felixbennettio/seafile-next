import copy
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import replace_release_clients as release


class ClientReplacementTests(unittest.TestCase):
    def existing(self):
        packages = [{'platform': platform, 'file': 'seafile-next-v1.0.0-' + suffix,
                     'sha256': 'a' * 64, 'bytes': 42, 'build': {'source': platform + ' fixture'}}
                    for platform, (_, suffix) in release.PRODUCTS.items()]
        manifest = {'version': '1.0.0', 'packages': packages, 'missingPackages': [],
                    'serverImage': 'ghcr.io/felixbennettio/seafile-next-server@sha256:' + 'd' * 64,
                    'serverBuild': {'source': 'server fixture'}}
        assets = [{'name': p['file'], 'size': p['bytes'], 'digest': 'sha256:' + p['sha256']} for p in packages]
        assets += [{'name': name, 'size': 42, 'digest': 'sha256:' + 'b' * 64}
                   for name in ('image-digest.txt', 'release-manifest.json', 'SHA256SUMS')]
        checksums = {a['name']: a['digest'][7:] for a in assets if a['name'] != 'SHA256SUMS'}
        return manifest, {'draft': False, 'assets': assets}, checksums

    def test_complete_release_is_accepted_without_rebuilding_other_platforms(self):
        manifest, record, checksums = self.existing()
        self.assertEqual(len(release.validate_existing('1.0.0', manifest, record, checksums)), 8)

    def test_stale_asset_manifest_or_checksum_stops_replacement(self):
        for kind in ('asset', 'checksum', 'manifest'):
            manifest, record, checksums = self.existing()
            if kind == 'asset': record['assets'][0]['digest'] = 'sha256:' + 'c' * 64
            if kind == 'checksum': checksums['image-digest.txt'] = 'c' * 64
            if kind == 'manifest': manifest['packages'][0]['bytes'] += 1
            with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                release.validate_existing('1.0.0', manifest, record, checksums)

    def test_missing_platform_or_draft_release_is_rejected(self):
        for kind in ('draft', 'missing', 'wrong platform'):
            manifest, record, checksums = self.existing()
            if kind == 'draft': record['draft'] = True
            if kind == 'missing': manifest['packages'].pop()
            if kind == 'wrong platform':
                manifest['packages'][0]['file'], manifest['packages'][1]['file'] = manifest['packages'][1]['file'], manifest['packages'][0]['file']
            with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                release.validate_existing('1.0.0', manifest, record, checksums)

    def test_android_update_preserves_other_package_receipts_and_server_image(self):
        manifest, _, _ = self.existing(); original = copy.deepcopy(manifest)
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary) / 'fixture.apk'; package.write_bytes(b'inert package fixture')
            updated = release.updated_manifest(manifest, {'android': (package, {'source': 'new fixture'})})
        self.assertEqual(manifest, original)
        self.assertEqual(updated['packages'][1:], manifest['packages'][1:])
        self.assertEqual(updated['serverImage'], manifest['serverImage'])
        self.assertEqual(updated['serverBuild'], manifest['serverBuild'])
        self.assertEqual(updated['packages'][0]['build'], {'source': 'new fixture'})
        self.assertNotEqual(updated['packages'][0]['sha256'], manifest['packages'][0]['sha256'])

    def test_incomplete_or_wrong_workflow_cannot_prove_delivery(self):
        for status, conclusion, workflow in (('in_progress', None, '.github/workflows/apple.yml'),
                                           ('completed', 'failure', '.github/workflows/apple.yml'),
                                           ('completed', 'success', '.github/workflows/apple-validation.yml')):
            record = {'status': status, 'conclusion': conclusion, 'path': workflow}
            with patch.object(release, 'github', return_value=record), self.assertRaises(RuntimeError):
                release.receipt('ios', '123')

    def test_changed_native_sources_are_rejected_but_matching_trees_use_actual_build_sha(self):
        record = {'status': 'completed', 'conclusion': 'success', 'path': '.github/workflows/apple.yml', 'head_sha': 'a' * 40}
        with patch.object(release, 'github', return_value=record), \
                patch.object(release.subprocess, 'check_output', side_effect=['old\n', 'changed\n']), self.assertRaises(RuntimeError):
            release.receipt('ios', '123')
        with patch.object(release, 'github', return_value=record), \
                patch.object(release.subprocess, 'check_output', side_effect=['apple-tree\n', 'apple-tree\n', 'sync-tree\n', 'sync-tree\n']):
            proof = release.receipt('ios', '123')
        self.assertEqual(proof['buildCommit'], 'a' * 40)
        self.assertEqual(proof['matchingSourceTrees'], {'apple': 'apple-tree', 'sync': 'sync-tree'})

    def test_apple_version_cannot_be_changed_by_renaming_an_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            for platform, name in (('ios', 'Payload/app.app/Info.plist'), ('macos', 'app.app/Contents/Info.plist')):
                file = Path(temporary) / (platform + '.zip')
                with zipfile.ZipFile(file, 'w') as archive:
                    archive.writestr(name, plistlib.dumps({'CFBundleShortVersionString': '1.0.1'}))
                with self.subTest(platform=platform), self.assertRaises(RuntimeError):
                    release.validate_apple_version(platform, file, '1.0.0')
                release.validate_apple_version(platform, file, '1.0.1')

    def test_delivery_reuse_requires_native_validation_and_platform_processing(self):
        record = {'status': 'completed', 'conclusion': 'success', 'path': '.github/workflows/apple-delivery.yml', 'head_sha': 'a' * 40}
        steps = [{'name': 'Verify successful native regression and unchanged client sources', 'conclusion': 'success'},
                 {'name': 'Archive and upload iOS to TestFlight', 'conclusion': 'success'},
                 {'name': 'Verify iOS TestFlight processing', 'conclusion': 'success'},
                 {'name': 'Remove generated files and restored signing material', 'conclusion': 'success'}]
        jobs = {'jobs': [{'name': 'deliver', 'steps': steps}]}
        with patch.object(release, 'github', side_effect=[record, jobs]), \
                patch.object(release.subprocess, 'check_output', return_value='matching tree\n'):
            self.assertEqual(release.receipt('ios', '123')['buildCommit'], 'a' * 40)
        with patch.object(release, 'github', side_effect=[record, jobs]), self.assertRaises(RuntimeError):
            release.receipt('macos', '123')
        # A later macOS upload failure must not invalidate the already accepted
        # iOS archive. Skipped uploads and failed cleanup still cannot prove it.
        record['conclusion'] = 'failure'
        with patch.object(release, 'github', side_effect=[record, jobs]), \
                patch.object(release.subprocess, 'check_output', return_value='matching tree\n'):
            release.receipt('ios', '123')
        for index in (1, 2, 3):
            broken = copy.deepcopy(jobs)
            broken['jobs'][0]['steps'][index]['conclusion'] = 'skipped'
            with patch.object(release, 'github', side_effect=[record, broken]), self.assertRaises(RuntimeError):
                release.receipt('ios', '123')
