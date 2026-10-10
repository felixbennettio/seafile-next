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

REPOSITORY = 'felixbennettio/seafile-next'


def github(path):
    return json.loads(subprocess.check_output(['gh', 'api', 'repos/' + REPOSITORY + '/' + path], text=True))


def receipt(platform, run, current='HEAD'):
    if platform not in ('android', 'ios', 'macos') or not str(run).isdecimal():
        raise RuntimeError('Use a supported client and a numeric validation run')
    record = github('actions/runs/' + str(run))
    workflows = {'.github/workflows/android.yml'} if platform == 'android' else {
        '.github/workflows/apple.yml', '.github/workflows/apple-delivery.yml'}
    if record['status'] != 'completed' or record['path'] not in workflows or \
            (record['conclusion'] != 'success' and record['path'] != '.github/workflows/apple-delivery.yml'):
        raise RuntimeError('Client delivery must complete successfully before replacing its package')
    if record['path'] == '.github/workflows/apple-delivery.yml':
        jobs = github('actions/runs/' + str(run) + '/jobs?per_page=100')['jobs']
        steps = [step for job in jobs if job['name'] == 'deliver' for step in job['steps']]
        required = ('Verify successful native regression and unchanged client sources',
                    'Archive and upload iOS to TestFlight' if platform == 'ios' else 'Archive and upload macOS to TestFlight',
                    'Verify iOS TestFlight processing' if platform == 'ios' else 'Verify macOS TestFlight processing',
                    'Remove generated files and restored signing material')
        if any(not any(step['name'] == name and step['conclusion'] == 'success' for step in steps) for name in required):
            raise RuntimeError('Reused native validation and the requested TestFlight delivery must both pass')
    commit = record['head_sha']
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise RuntimeError('Unexpected build commit')
    directories = ['android'] if platform == 'android' else ['apple', 'sync']
    trees = {}
    for directory in directories:
        built = subprocess.check_output(['git', 'rev-parse', commit + ':' + directory], text=True).strip()
        now = subprocess.check_output(['git', 'rev-parse', current + ':' + directory], text=True).strip()
        if built != now:
            raise RuntimeError('The delivered client does not match the current source tree')
        trees[directory] = built
    return {'actionsRun': 'https://github.com/' + REPOSITORY + '/actions/runs/' + str(run),
            'buildCommit': commit, 'matchingSourceTrees': trees}


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
            package.update({'sha256': sha256(file), 'bytes': file.stat().st_size, 'build': provenance})
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
    parser.add_argument('--client', action='append', nargs=3, metavar=('PLATFORM', 'PACKAGE', 'RUN'), required=True)
    parser.add_argument('--notes', type=Path, help='Complete functional release notes; otherwise preserve the existing body')
    args = parser.parse_args()
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
        provenance = receipt(platform, run)
        file = Path(filename)
        validate_package(platform, file)
        validate_apple_version(platform, file, args.version)
        target = output / f'seafile-next-{tag}-{PRODUCTS[platform][1]}'
        shutil.copy2(file, target)
        replacements[platform] = (target, provenance)
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
