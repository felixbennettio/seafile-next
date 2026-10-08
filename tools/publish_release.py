#!/usr/bin/env python3
"""Publish validated existing packages through one draft-to-public release path."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import zipfile

from package_unsigned_ios import macho_platforms


PRODUCTS = {
    'android': ('*.apk', 'android-debug.apk'),
    'windows': ('*windows*x64*unsigned.zip', 'windows-x64-unsigned.zip'),
    'linux': ('*.deb', 'linux-amd64.deb'),
    'macos': ('*macos-arm64-direct.zip', 'macos-arm64-direct.zip'),
    'ios': ('*.ipa', 'ios-unsigned.ipa'),
}


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate_package(platform, path):
    if platform == 'linux':
        data = path.read_bytes()
        if not data.startswith(b'!<arch>\n') or b'debian-binary' not in data[:68] or b'2.0\n' not in data[:76]:
            raise RuntimeError('Expected a Debian binary package')
        return
    with zipfile.ZipFile(path) as archive:
        bad = archive.testzip()
        if bad:
            raise RuntimeError('Corrupt ZIP member: ' + bad)
        names = archive.namelist()
        for name in names:
            if name.startswith('/') or '..' in Path(name).parts:
                raise RuntimeError('Unsafe archive member')
        basenames = {Path(n).name for n in names}
        if platform == 'android':
            if not {'AndroidManifest.xml', 'classes.dex'}.issubset(basenames):
                raise RuntimeError('Expected an Android application APK')
        elif platform == 'windows':
            if not {'seafile-applet.exe', 'seaf-daemon.exe', 'libsearpc.dll', 'Qt6SerialPort.dll', 'vcruntime140.dll', 'msvcp140.dll'}.issubset(basenames):
                raise RuntimeError('Windows portable runtime is incomplete')
        elif platform == 'macos':
            if not any(n.endswith('.app/Contents/Info.plist') for n in names) or not any(n.endswith('/seaf-daemon') for n in names):
                raise RuntimeError('Expected native Mac app with sync engine')
        elif platform == 'ios':
            hosts = [n for n in names if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)]
            if len(hosts) != 1:
                raise RuntimeError('Expected one device app in Payload')
            if any('_CodeSignature' in Path(n).parts or n.endswith(('.mobileprovision', '.provisionprofile')) for n in names):
                raise RuntimeError('The unsigned IPA still contains signing material')
            bundles = [n for n in names if n.endswith('/Info.plist') and n.startswith('Payload/') and n.rsplit('/', 1)[0].endswith(('.app', '.appex', '.framework'))]
            for name in bundles:
                info = plistlib.loads(archive.read(name))
                if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
                    raise RuntimeError('Simulator or non-iOS bundle inside IPA')
                executable = name.rsplit('/', 1)[0] + '/' + info['CFBundleExecutable']
                if macho_platforms(archive.read(executable), require_unsigned=True) != {2}:
                    raise RuntimeError('The IPA does not contain iOS device executables')
            if not any('/PlugIns/' in n and n.endswith('.appex/Info.plist') for n in names):
                raise RuntimeError('Missing File Provider extension in IPA')


def stage_packages(version, source, output, allow_missing_ios=False):
    output.mkdir(parents=True, exist_ok=True)
    receipt_file = Path('docs') / f'release-builds-v{version}.json'
    receipts = json.loads(receipt_file.read_text()) if receipt_file.is_file() else {}
    packages = []
    missing = []
    for platform, (pattern, suffix) in PRODUCTS.items():
        candidates = list(source.rglob(pattern))
        # Identical files may appear in two Actions artifacts; do not pick between different builds.
        unique = {sha256(p): p for p in candidates}
        if not unique and platform == 'ios' and allow_missing_ios:
            missing.append('ios-unsigned')
            continue
        if len(unique) != 1:
            raise RuntimeError(f'Expected exactly one {platform} package, found {len(unique)}')
        path = next(iter(unique.values()))
        validate_package(platform, path)
        target = output / f'seafile-next-v{version}-{suffix}'
        shutil.copy2(path, target)
        package = {'platform': platform, 'file': target.name, 'sha256': sha256(target), 'bytes': target.stat().st_size}
        if platform in receipts:
            package['build'] = receipts[platform]
        packages.append(package)
    references = list(source.rglob('image-digest.txt'))
    if len(references) != 1:
        raise RuntimeError('Expected one immutable server image reference')
    image = references[0].read_text().strip()
    if not re.fullmatch(r'ghcr\.io/felixbennettio/seafile-next-server@sha256:[0-9a-f]{64}', image):
        raise RuntimeError('Unexpected server image repository or digest')
    shutil.copy2(references[0], output / 'image-digest.txt')
    manifest = {'version': version, 'source': os.environ.get('GITHUB_SHA') or subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(), 'packages': packages, 'serverImage': image, 'missingPackages': missing}
    if 'docker' in receipts:
        manifest['serverBuild'] = receipts['docker']
    (output / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    files = [output / p['file'] for p in packages] + [output / 'image-digest.txt', output / 'release-manifest.json']
    (output / 'SHA256SUMS').write_text(''.join(f'{sha256(p)}  {p.name}\n' for p in files))
    return files + [output / 'SHA256SUMS']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', required=True)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=Path('release-output'))
    parser.add_argument('--allow-missing-ios', action='store_true', help='Explicit one-time compatibility for historical Actions runs without a device IPA')
    parser.add_argument('--stage-only', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', args.version):
        raise RuntimeError('Invalid release version')
    tag = 'v' + args.version
    notes = Path('docs/releases') / (tag + '.md')
    if not notes.is_file() or not notes.read_text().strip():
        raise RuntimeError('Missing functional release notes')
    files = stage_packages(args.version, args.input, args.output, args.allow_missing_ios)
    if args.stage_only:
        print('Validated and staged', len(files), 'release assets')
        return
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    listing = subprocess.run(['gh', 'release', 'view', tag, '--json', 'isDraft,targetCommitish'], capture_output=True, text=True)
    if listing.returncode:
        if 'not found' not in listing.stderr.lower():
            raise RuntimeError('Cannot read release state: ' + listing.stderr.strip())
        subprocess.run(['gh', 'release', 'create', tag, '--target', head, '--draft', '--title', 'Seafile Next ' + args.version, '--notes-file', str(notes)], check=True)
    else:
        record = json.loads(listing.stdout)
        if not record['isDraft']:
            raise RuntimeError('This version is already published; choose a new version')
        if record['targetCommitish'] not in (head, 'main'):
            raise RuntimeError('The draft belongs to another source revision')
    subprocess.run(['gh', 'release', 'upload', tag, *map(str, files), '--clobber'], check=True)
    release = json.loads(subprocess.check_output(['gh', 'release', 'view', tag, '--json', 'assets'], text=True))
    assets = {a['name']: a for a in release['assets']}
    expected = {p.name for p in files}
    if set(assets) != expected:
        raise RuntimeError('Draft asset set differs from the validated package set')
    for file in files:
        if assets[file.name]['size'] != file.stat().st_size:
            raise RuntimeError('Uploaded asset size mismatch: ' + file.name)
    subprocess.run(['gh', 'release', 'edit', tag, '--draft=false', '--latest', '--notes-file', str(notes)], check=True)
    print('Published', tag, 'with', len(files), 'validated assets')


if __name__ == '__main__':
    main()
