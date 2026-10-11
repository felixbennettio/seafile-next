#!/usr/bin/env python3
"""Package an existing device archive for re-signing, without rebuilding it."""
import argparse
import copy
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile

RESIGNING = ('Unsigned iPhone/iPad device application. Re-sign the app, embedded frameworks and extensions with compatible App Group and Keychain entitlements before installation. In every app/extension Info.plist, replace $(AppIdentifierPrefix) in SeafileKeychainGroup with the prefix authorized by your own provisioning profile, including its trailing dot. This public copy contains no building-team prefix. TestFlight is available without manual signing.\n')


def sanitize_existing_ipa(source, destination):
    """Remove public unsigned-package metadata without changing executable bytes."""
    if source.resolve() == destination.resolve():
        raise RuntimeError('Preserve the original package while sanitizing its copy')
    changes = set()
    with zipfile.ZipFile(source) as original:
        names = original.namelist()
        if len(names) != len(set(names)) or any(name.startswith('/') or '..' in Path(name).parts for name in names):
            raise RuntimeError('Unexpected unsigned package paths')
        if any('_CodeSignature' in Path(name).parts or name.endswith(('.mobileprovision', '.provisionprofile')) for name in names):
            raise RuntimeError('Sanitize only an unsigned package without signing material')
        with zipfile.ZipFile(destination, 'w') as output:
            for item in original.infolist():
                data = original.read(item)
                if re.fullmatch(r'Payload/[^/]+\.app/(?:PlugIns/[^/]+\.appex/)?Info\.plist', item.filename):
                    values = plistlib.loads(data)
                    group = values.get('SeafileKeychainGroup')
                    if group and group != '$(AppIdentifierPrefix)io.felixbennett.seafile.accounts':
                        if not re.fullmatch(r'[A-Z0-9]{10}\.io\.felixbennett\.seafile\.accounts', group):
                            raise RuntimeError('Unexpected keychain metadata; nothing was published')
                        values['SeafileKeychainGroup'] = '$(AppIdentifierPrefix)io.felixbennett.seafile.accounts'
                        data = plistlib.dumps(values)
                        changes.add(item.filename)
                elif item.filename == 'RESIGNING.txt':
                    data = RESIGNING.encode()
                output.writestr(copy.copy(item), data)
            if 'RESIGNING.txt' not in names:
                output.writestr('RESIGNING.txt', RESIGNING)
        with zipfile.ZipFile(destination) as output:
            if set(output.namelist()) != set(names) | {'RESIGNING.txt'}:
                raise RuntimeError('Sanitization unexpectedly changed package membership')
            for name in names:
                before, after = original.read(name), output.read(name)
                if name in changes:
                    values = plistlib.loads(after)
                    values['SeafileKeychainGroup'] = plistlib.loads(before)['SeafileKeychainGroup']
                    if values != plistlib.loads(before):
                        raise RuntimeError('Sanitization changed other application metadata')
                elif name != 'RESIGNING.txt' and before != after:
                    raise RuntimeError('Sanitization changed application contents')
    return len(changes)


def remove_team_prefixes(app):
    """Keep the public re-signing copy independent of the building Apple team."""
    for item in app.rglob('Info.plist'):
        if item.is_symlink():
            continue
        values = plistlib.loads(item.read_bytes())
        if 'SeafileKeychainGroup' in values:
            values['SeafileKeychainGroup'] = '$(AppIdentifierPrefix)io.felixbennett.seafile.accounts'
            item.write_bytes(plistlib.dumps(values))


def macho_platforms(data, require_unsigned=False):
    """Return LC_BUILD_VERSION platforms; reject malformed or non-Mach-O input."""
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        is64 = data[:4] == b'\xca\xfe\xba\xbf'
        count = struct.unpack_from('>I', data, 4)[0]
        if count < 1 or count > 16:
            raise ValueError('Invalid universal binary architecture count')
        platforms = set()
        for i in range(count):
            pos = 8 + i * (32 if is64 else 20)
            offset, size = struct.unpack_from('>QQ' if is64 else '>II', data, pos + 8)
            if offset + size > len(data):
                raise ValueError('Truncated universal binary')
            platforms.update(macho_platforms(data[offset:offset + size], require_unsigned))
        return platforms
    if data[:4] not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf'):
        raise ValueError('Expected a 64-bit Mach-O device executable')
    endian = '<' if data[:4] == b'\xcf\xfa\xed\xfe' else '>'
    header = struct.unpack_from(endian + 'IiiIIIII', data)
    if header[1] != 0x0100000c:
        raise ValueError('Expected an arm64 device executable')
    pos = 32
    end = pos + header[5]
    if end > len(data):
        raise ValueError('Truncated Mach-O load commands')
    platforms = set()
    for _ in range(header[4]):
        command, size = struct.unpack_from(endian + 'II', data, pos)
        if size < 8 or pos + size > end:
            raise ValueError('Invalid Mach-O load command')
        if command == 0x1d and require_unsigned:
            if size < 16 or struct.unpack_from(endian + 'I', data, pos + 12)[0]:
                raise ValueError('Mach-O still contains an embedded code signature')
        if command == 0x32:
            if size < 24:
                raise ValueError('Invalid build version command')
            platforms.add(struct.unpack_from(endian + 'I', data, pos + 8)[0])
        pos += size
    if pos != end or not platforms:
        raise ValueError('Missing Mach-O platform metadata')
    return platforms


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('archive', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    apps = list((args.archive / 'Products/Applications').glob('*.app'))
    if len(apps) != 1:
        raise RuntimeError('Expected one archived iPhone application')
    info = plistlib.loads((apps[0] / 'Info.plist').read_bytes())
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise RuntimeError('A simulator application cannot produce a device IPA')
    if macho_platforms((apps[0] / info['CFBundleExecutable']).read_bytes()) != {2}:
        raise RuntimeError('The archive is not an iOS device build')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        staging = Path(temporary)
        payload = staging / 'Payload'
        payload.mkdir()
        app = payload / apps[0].name
        shutil.copytree(apps[0], app, symlinks=True)
        remove_team_prefixes(app)
        # Operate only on the copy, retaining the original signed archive for TestFlight.
        for item in sorted(app.rglob('*'), key=lambda p: len(p.parts), reverse=True):
            if item.is_symlink():
                continue
            if item.name == '_CodeSignature' and item.is_dir():
                shutil.rmtree(item)
            elif item.is_file() and item.suffix in ('.mobileprovision', '.provisionprofile'):
                item.unlink()
            elif item.is_file():
                with item.open('rb') as stream:
                    magic = stream.read(4)
                if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
                    if macho_platforms(item.read_bytes()) != {2}:
                        raise RuntimeError('Non-iOS executable inside device package: ' + item.name)
                    check = subprocess.run(['codesign', '-d', str(item)], capture_output=True)
                    if check.returncode == 0:
                        subprocess.run(['codesign', '--remove-signature', str(item)], check=True, capture_output=True)
                    macho_platforms(item.read_bytes(), require_unsigned=True)
        (staging / 'RESIGNING.txt').write_text(RESIGNING)
        subprocess.run(['ditto', '-c', '-k', str(staging), str(args.output.resolve())], check=True)
    print('Retained unsigned iOS device IPA:', args.output)


if __name__ == '__main__':
    main()
