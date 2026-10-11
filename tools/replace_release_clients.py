#!/usr/bin/env python3
"""Replace validated clients on an existing release, preserving other products."""
import argparse
import copy
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import zipfile

from publish_release import PRODUCTS, sha256, validate_package
from package_unsigned_ios import sanitize_existing_ipa

REPOSITORY = 'felixbennettio/seafile-next'


def github(path):
    return json.loads(subprocess.check_output(['gh', 'api', 'repos/' + REPOSITORY + '/' + path], text=True))


def receipt(platform, run, current='HEAD', windows_validation_run=None):
    if platform not in PRODUCTS or not str(run).isdecimal():
        raise RuntimeError('Use a supported client and a numeric validation run')
    record = github('actions/runs/' + str(run))
    workflows = {
        'android': {'.github/workflows/android.yml'},
        'windows': {'.github/workflows/desktop.yml'},
        'linux': {'.github/workflows/linux.yml'},
        'ios': {'.github/workflows/apple.yml', '.github/workflows/apple-delivery.yml'},
        'macos': {'.github/workflows/apple.yml', '.github/workflows/apple-delivery.yml'},
    }[platform]
    if record['status'] != 'completed' or record['path'] not in workflows or \
            record['conclusion'] not in ('success', 'failure') or \
            (platform in ('android', 'windows', 'linux') and record['conclusion'] != 'success' and not (platform == 'windows' and windows_validation_run)):
        raise RuntimeError('Client delivery must complete successfully before replacing its package')
    if platform in ('ios', 'macos'):
        jobs = github('actions/runs/' + str(run) + '/jobs?per_page=100')['jobs']
        reuse = record['path'] == '.github/workflows/apple-delivery.yml'
        job_name = 'deliver' if reuse else 'build'
        matching = [job for job in jobs if job['name'] == job_name]
        if len(matching) != 1:
            raise RuntimeError('Cannot identify the validated client delivery job')
        steps = matching[0]['steps']
        required = ['Remove generated files and restored signing material',
                    'Verify successful native regression and unchanged client sources' if reuse else 'Test APIs and build native Mac client']
        if platform == 'ios':
            required += ['Archive and upload iOS to TestFlight', 'Verify iOS TestFlight processing']
            if not reuse:
                required += ['Test iPhone navigation and sign-in controls', 'Retain unsigned iPhone device package']
        else:
            # The release distributes the tested non-sandbox direct app. Its
            # validity is independent of a subsequent sandbox TestFlight upload.
            required += ['Retain validated direct Mac package' if reuse else 'Package non-sandbox Mac client']
        if any(not any(step['name'] == name and step['conclusion'] == 'success' for step in steps) for name in required):
            raise RuntimeError('Native validation, cleanup and the requested client delivery must pass')
    if platform in ('windows', 'linux'):
        jobs = github('actions/runs/' + str(run) + '/jobs?per_page=100')['jobs']
        if platform == 'windows' and windows_validation_run:
            from reuse_windows_package import verify_build
            verify_build(record, jobs, current)
            validation = github('actions/runs/' + str(windows_validation_run))
            if validation['status'] != 'completed' or validation['conclusion'] != 'success' or validation['path'] != '.github/workflows/windows-package-validation.yml':
                raise RuntimeError('Completed Windows package and readonly cleanup validation are required')
            validation_jobs = github('actions/runs/' + str(windows_validation_run) + '/jobs?per_page=100')['jobs']
            matching = [job for job in validation_jobs if job['name'] == 'validate']
            required = ['Validate retained Windows package from ' + str(run), 'Reproduce readonly downloaded tool cleanup', 'Remove temporary desktop build and download files']
            if len(matching) != 1 or any(not any(step['name'] == stage and step['conclusion'] == 'success' for step in matching[0]['steps']) for stage in required):
                raise RuntimeError('The recovered Windows package, integration and cleanup must all pass')
            for directory in ('desktop', 'sync', 'tools/windows-integration'):
                tested = subprocess.check_output(['git', 'rev-parse', validation['head_sha'] + ':' + directory], text=True).strip()
                now = subprocess.check_output(['git', 'rev-parse', current + ':' + directory], text=True).strip()
                if tested != now: raise RuntimeError('Recovered Windows validation does not match current sources')
        required_jobs = {'build': ['Build sync engine and desktop client', 'Remove temporary Linux build files']} if platform == 'linux' else {
            'windows': ['Build GUI', 'Assemble unsigned portable package', 'Remove temporary desktop build and download files'],
            'windows-shell': ['Build the retained Explorer extension', 'Remove temporary desktop build and download files'],
            'windows-integration-validation': ['Test DLL loading and isolated registration', 'Remove temporary desktop build and download files'],
        }
        for name, required in ({} if platform == 'windows' and windows_validation_run else required_jobs).items():
            matching = [job for job in jobs if job['name'] == name]
            if len(matching) != 1 or matching[0]['conclusion'] != 'success' or any(
                    not any(step['name'] == stage and step['conclusion'] == 'success' for step in matching[0]['steps'])
                    for stage in required):
                raise RuntimeError('Desktop application, integration and temporary cleanup must pass before replacement')
    commit = record['head_sha']
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise RuntimeError('Unexpected build commit')
    directories = {
        'android': ['android'], 'ios': ['apple', 'sync'], 'macos': ['apple', 'sync'],
        'windows': ['desktop', 'sync', 'tools/windows-integration'],
        'linux': ['desktop', 'sync', 'tools/package_linux.sh', 'tools/install_linux_integration.sh'],
    }[platform]
    trees = {}
    for directory in directories:
        built = subprocess.check_output(['git', 'rev-parse', commit + ':' + directory], text=True).strip()
        now = subprocess.check_output(['git', 'rev-parse', current + ':' + directory], text=True).strip()
        if built != now:
            raise RuntimeError('The delivered client does not match the current source tree')
        trees[directory] = built
    proof = {'actionsRun': 'https://github.com/' + REPOSITORY + '/actions/runs/' + str(run),
             'buildCommit': commit, 'matchingSourceTrees': trees}
    if platform == 'windows' and windows_validation_run:
        proof['additionalValidationRun'] = 'https://github.com/' + REPOSITORY + '/actions/runs/' + str(windows_validation_run)
    return proof


def validate_existing(version, manifest, release, checksums):
    expected_files = {f'seafile-next-v{version}-{suffix}' for _, suffix in PRODUCTS.values()}
    expected_assets = expected_files | {'image-digest.txt', 'release-manifest.json', 'SHA256SUMS'}
    assets = {item['name']: item for item in release['assets']}
    if release['draft'] or set(assets) != expected_assets:
        raise RuntimeError('Use the existing complete public release')
    packages = manifest.get('packages', [])
    if manifest.get('version') != version or manifest.get('missingPackages') or \
            {p['platform'] for p in packages} != set(PRODUCTS) or len(packages) != len(PRODUCTS):
        raise RuntimeError('The existing manifest must describe all five clients')
    if {p['file'] for p in packages} != expected_files:
        raise RuntimeError('Unexpected package filenames in the existing manifest')
    for package in packages:
        expected_file = f'seafile-next-v{version}-{PRODUCTS[package["platform"]][1]}'
        if package['file'] != expected_file:
            raise RuntimeError('A manifest package is assigned to the wrong platform')
        asset = assets[package['file']]
        if asset.get('digest') != 'sha256:' + package['sha256'] or asset['size'] != package['bytes']:
            raise RuntimeError('The current release asset differs from its manifest')
    expected_checksums = {name: asset.get('digest', '').removeprefix('sha256:')
                          for name, asset in assets.items() if name != 'SHA256SUMS'}
    if checksums != expected_checksums or any(not re.fullmatch(r'[a-f0-9]{64}', v) for v in checksums.values()):
        raise RuntimeError('Existing release checksums do not match the published assets')
    if not re.fullmatch(r'ghcr\.io/felixbennettio/seafile-next-server@sha256:[a-f0-9]{64}', manifest['serverImage']):
        raise RuntimeError('Unexpected server image repository')
    return assets


def updated_manifest(manifest, replacements):
    result = copy.deepcopy(manifest)
    for package in result['packages']:
        platform = package['platform']
        if platform in replacements:
            file, provenance = replacements[platform]
            if platform == 'macos':
                provenance = mac_package_receipt(file, provenance)
            package.update({'sha256': sha256(file), 'bytes': file.stat().st_size, 'build': provenance})
    return result


def mac_package_receipt(file, provenance):
    # Reused direct packages retain their original compilation revision. The
    # updater compares that value with Info.plist, not the later delivery run.
    with zipfile.ZipFile(file) as archive:
        hosts = [name for name in archive.namelist() if re.fullmatch(r'[^/]+\.app/Contents/Info\.plist', name)]
        if len(hosts) != 1:
            raise RuntimeError('Expected one direct Mac application')
        revision = plistlib.loads(archive.read(hosts[0])).get('SeafileSourceRevision', '')
    if not re.fullmatch(r'[a-f0-9]{40}', revision):
        raise RuntimeError('The direct Mac package lacks its compilation revision')
    for directory, expected in provenance['matchingSourceTrees'].items():
        tree = subprocess.check_output(['git', 'rev-parse', revision + ':' + directory], text=True).strip()
        if tree != expected:
            raise RuntimeError('The direct Mac compilation revision differs from its validated source trees')
    result = copy.deepcopy(provenance)
    if revision != result['buildCommit']:
        result['workflowCommit'] = result['buildCommit']
        result['buildCommit'] = revision
    return result


def validate_apple_version(platform, file, version):
    if platform not in ('ios', 'macos'):
        return
    pattern = r'Payload/[^/]+\.app/Info\.plist' if platform == 'ios' else r'[^/]+\.app/Contents/Info\.plist'
    with zipfile.ZipFile(file) as archive:
        hosts = [name for name in archive.namelist() if re.fullmatch(pattern, name)]
        if len(hosts) != 1 or plistlib.loads(archive.read(hosts[0])).get('CFBundleShortVersionString') != version:
            raise RuntimeError('The Apple package version differs from the existing release version')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--client', action='append', nargs=3, metavar=('PLATFORM', 'PACKAGE', 'RUN'), default=[])
    parser.add_argument('--sanitize-existing-ios', action='store_true', help='Remove team metadata from the existing unsigned IPA, preserving its original build receipt')
    parser.add_argument('--windows-validation-run', help='Successful original-package and readonly cleanup validation when recovering a Windows build')
    parser.add_argument('--notes', type=Path, help='Complete functional release notes; otherwise preserve the existing body')
    args = parser.parse_args()
    if not args.client and not args.sanitize_existing_ios:
        raise RuntimeError('Select a validated client or unsigned iOS metadata sanitization')
    if args.windows_validation_run and (not args.windows_validation_run.isdecimal() or not any(client[0] == 'windows' for client in args.client)):
        raise RuntimeError('Use a numeric recovery validation with a Windows client replacement')
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        raise RuntimeError('Invalid release version')
    workspace = args.workspace.resolve()
    checkout = Path(__file__).resolve().parents[1]
    if args.workspace.is_symlink() or workspace.is_relative_to(checkout) or \
            not workspace.name.startswith('seafile-next-publish.') or workspace.stat().st_uid != os.getuid() or workspace.stat().st_mode & 0o077:
        raise RuntimeError('Use an owned mktemp publishing workspace outside the repository')
    tag = 'v' + args.version
    release = github('releases/tags/' + tag)
    metadata = workspace / 'metadata'
    if not metadata.exists():
        subprocess.run(['gh', 'release', 'download', tag, '--repo', REPOSITORY, '--pattern', 'release-manifest.json',
                        '--pattern', 'SHA256SUMS', '--dir', str(metadata)], check=True)
    manifest_file = metadata / 'release-manifest.json'
    manifest = json.loads(manifest_file.read_text())
    checksums = dict((line.split('  ', 1)[1], line.split('  ', 1)[0])
                     for line in (metadata / 'SHA256SUMS').read_text().splitlines())
    assets = validate_existing(args.version, manifest, release, checksums)
    for file in (manifest_file, metadata / 'SHA256SUMS'):
        if assets[file.name]['digest'] != 'sha256:' + sha256(file):
            raise RuntimeError('Downloaded release metadata failed its integrity check')
    output = workspace / 'output'; output.mkdir()
    replacements = {}
    for platform, filename, run in args.client:
        if platform in replacements:
            raise RuntimeError('Do not supply a platform twice')
        provenance = receipt(platform, run, windows_validation_run=args.windows_validation_run if platform == 'windows' else None)
        file = Path(filename)
        validate_package(platform, file)
        validate_apple_version(platform, file, args.version)
        target = output / f'seafile-next-{tag}-{PRODUCTS[platform][1]}'
        shutil.copy2(file, target)
        replacements[platform] = (target, provenance)
    if args.sanitize_existing_ios:
        if 'ios' in replacements:
            raise RuntimeError('Do not sanitize the old IPA when replacing it with a newly validated build')
        package = next(item for item in manifest['packages'] if item['platform'] == 'ios')
        original = workspace / 'original-ios'; original.mkdir()
        subprocess.run(['gh', 'release', 'download', tag, '--repo', REPOSITORY, '--pattern', package['file'], '--dir', str(original)], check=True)
        source = original / package['file']
        if sha256(source) != package['sha256']:
            raise RuntimeError('Original unsigned package integrity check failed')
        target = output / package['file']
        count = sanitize_existing_ipa(source, target)
        validate_package('ios', target)
        validate_apple_version('ios', target, args.version)
        provenance = copy.deepcopy(package['build'])
        provenance['metadataRepack'] = {'sourcePackageSha256': package['sha256'], 'toolCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(), 'changedInfoPlists': count, 'applicationContentsUnchanged': True}
        replacements['ios'] = (target, provenance)
    revised = updated_manifest(manifest, replacements)
    (output / 'release-manifest.json').write_text(json.dumps(revised, indent=2) + '\n')
    hashes = {name: item['digest'].removeprefix('sha256:') for name, item in assets.items() if name != 'SHA256SUMS'}
    files = [file for file, _ in replacements.values()] + [output / 'release-manifest.json']
    for file in files: hashes[file.name] = sha256(file)
    checksum_file = output / 'SHA256SUMS'
    checksum_file.write_text(''.join(f'{digest}  {name}\n' for name, digest in sorted(hashes.items())))
    files.append(checksum_file)
    notes = output / 'notes.md'
    body = args.notes.read_text() if args.notes else release['body']
    if not body.strip() or re.search(r'\b[\w.+%-]+@[\w.-]+\.[A-Za-z]{2,}\b|-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----', body):
        raise RuntimeError('Release notes must be functional text without email addresses or private keys')
    notes.write_text(body)
    # Back up only the assets being replaced. Other platform binaries, tags and
    # the server image remain byte-for-byte unchanged and are not reuploaded.
    backup = workspace / 'backup'
    command = ['gh', 'release', 'download', tag, '--repo', REPOSITORY, '--dir', str(backup)]
    for file in files: command += ['--pattern', file.name]
    subprocess.run(command, check=True)
    for file in files:
        if sha256(backup / file.name) != assets[file.name]['digest'].removeprefix('sha256:'):
            raise RuntimeError('Backup integrity check failed')
    subprocess.run(['gh', 'release', 'upload', tag, '--repo', REPOSITORY, *map(str, files), '--clobber'], check=True)
    after = github('releases/tags/' + tag)
    actual = {item['name']: item for item in after['assets']}
    if after['id'] != release['id'] or set(actual) != set(assets):
        raise RuntimeError('The release identity or asset set changed unexpectedly')
    changed = {file.name for file in files}
    for name, item in actual.items():
        expected = sha256(output / name) if name in changed else assets[name]['digest'].removeprefix('sha256:')
        if item['digest'] != 'sha256:' + expected:
            raise RuntimeError('Published package integrity verification failed')
        if name not in changed and item['id'] != assets[name]['id']:
            raise RuntimeError('An unrelated release asset was replaced')
    subprocess.run(['gh', 'release', 'edit', tag, '--repo', REPOSITORY, '--notes-file', str(notes)], check=True)
    print('Updated ' + ', '.join(sorted(replacements)) + ' on the existing ' + tag + ' release; all asset hashes verified.')


if __name__ == '__main__':
    main()
