#!/usr/bin/env python3
"""Package an existing device archive for re-signing, without rebuilding it."""
import argparse
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile


def macho_platforms(data):
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
            platforms.update(macho_platforms(data[offset:offset + size]))
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
        (staging / 'RESIGNING.txt').write_text('Unsigned iPhone/iPad device application. Re-sign the app, embedded frameworks and File Provider extension with compatible App Group and Keychain entitlements before installation. TestFlight is available without manual signing.\n')
        subprocess.run(['ditto', '-c', '-k', str(staging), str(args.output.resolve())], check=True)
    print('Retained unsigned iOS device IPA:', args.output)


if __name__ == '__main__':
    main()
