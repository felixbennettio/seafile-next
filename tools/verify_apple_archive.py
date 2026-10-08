#!/usr/bin/env python3
"""Check the signed host/extension and their embedded profiles before upload."""
import argparse
import plistlib
from pathlib import Path
import subprocess

GROUP = 'group.io.felixbennett.seafile'
BUNDLE = 'io.felixbennett.seafile'


def command_plist(*args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} could not read the signed archive configuration')
    return plistlib.loads(result.stdout)


def check_bundle(path, identifier):
    content = path / 'Contents' if (path / 'Contents').is_dir() else path
    info = plistlib.loads((content / 'Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != identifier:
        raise RuntimeError('The archive contains an unexpected Bundle ID')
    entitlements = command_plist('codesign', '-d', '--entitlements', ':-', str(path))
    profile_path = content / ('embedded.provisionprofile' if content != path else 'embedded.mobileprovision')
    profile = command_plist('security', 'cms', '-D', '-i', str(profile_path))
    for values in [entitlements, profile.get('Entitlements', {})]:
        if GROUP not in values.get('com.apple.security.application-groups', []):
            raise RuntimeError(f'{identifier} lacks its provisioned File Provider group')
    if identifier.endswith('.fileprovider'):
        if info.get('NSExtension', {}).get('NSExtensionFileProviderDocumentGroup') != GROUP:
            raise RuntimeError('File Provider document group does not match its signed entitlement')
    print(f'Validated {identifier}: signed App Group, embedded profile and extension configuration')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    applications = list((args.archive / 'Products/Applications').glob('*.app'))
    if len(applications) != 1:
        raise RuntimeError('Expected one application in the archive')
    app = applications[0]
    check_bundle(app, BUNDLE)
    content = app / 'Contents' if (app / 'Contents').is_dir() else app
    extensions = list((content / 'PlugIns').glob('*.appex'))
    if len(extensions) != 1:
        raise RuntimeError('Expected the embedded Seafile File Provider extension')
    check_bundle(extensions[0], BUNDLE + '.fileprovider')


if __name__ == '__main__':
    main()
