#!/usr/bin/env python3
"""Keep retained desktop builds and downloads in one disposable workspace."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
from ci_workspace import export_tree


def validate(path):
    root = Path(path)
    temporary = Path(os.environ['RUNNER_TEMP']).resolve()
    checkout = Path(os.environ['GITHUB_WORKSPACE']).resolve()
    if root.is_symlink() or root.resolve().parent != temporary or not root.name.startswith('desktop-build.'):
        raise RuntimeError('Use a dedicated mktemp desktop workspace under RUNNER_TEMP')
    if root.resolve().is_relative_to(checkout):
        raise RuntimeError('Desktop build output must stay outside the checkout')
    return root.resolve()


def prepare(path, kind):
    root = validate(path)
    checkout = Path(os.environ['GITHUB_WORKSPACE'])
    source = root / 'source'
    export_tree(checkout, source, ('desktop', 'sync', 'tools'))
    if kind in ('windows', 'macos'):
        (source / 'desktop').rename(source / 'seafile-client')
        (source / 'sync').rename(source / 'seafile')
        export_tree(checkout / 'libsearpc', source / 'libsearpc')
    if kind == 'windows':
        repository = checkout / 'breakpad-gclient/src'
        # Only git creates and manages checkout metadata. Never copy .git.
        target = source / 'breakpad-gclient/src'
        target.parent.mkdir()
        revision = subprocess.check_output(['git', '-C', str(repository), 'rev-parse', 'HEAD'], text=True).strip()
        subprocess.run(['git', 'clone', '--no-hardlinks', '--no-checkout', str(repository), str(target)], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(target), 'checkout', '--detach', revision], check=True, capture_output=True)
    (root / 'temporary').mkdir()
    with open(os.environ['GITHUB_ENV'], 'a') as environment:
        values = {'DESKTOP_BUILD_TMP': root, 'DESKTOP_BUILD_SOURCE': source,
                  'TMPDIR': root / 'temporary', 'PYTHONDONTWRITEBYTECODE': '1'}
        if os.name == 'nt':
            values.update({'TEMP': root / 'temporary', 'TMP': root / 'temporary'})
        for key, value in values.items(): environment.write(f'{key}={value}\n')
    print('Desktop build and download workspace is ready.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('prepare', 'cleanup'))
    parser.add_argument('--workspace', type=Path)
    parser.add_argument('--kind', choices=('contracts', 'shell', 'registration', 'windows', 'macos'))
    args = parser.parse_args()
    workspace = args.workspace or os.environ.get('DESKTOP_BUILD_TMP')
    if args.action == 'prepare':
        if not workspace or not args.kind: raise RuntimeError('Workspace and build kind are required')
        prepare(workspace, args.kind)
    elif workspace:
        shutil.rmtree(validate(workspace))
        print('Temporary desktop build and download files were removed.')


if __name__ == '__main__': main()
