#!/usr/bin/env python3
"""Isolate generated CI files and keep signing keys outside temporary storage."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def signing_directory(platform):
    run = os.environ.get('GITHUB_RUN_ID', '')
    attempt = os.environ.get('GITHUB_RUN_ATTEMPT', '')
    if platform not in ('apple', 'android') or not run.isdecimal() or not attempt.isdecimal():
        raise RuntimeError('Missing CI signing workspace identity')
    return Path.home() / '.local/share/seafile-next/signing' / f'{run}-{attempt}-{platform}'


def validate_signing_directory(path):
    path = Path(path)
    resolved = path.resolve()
    home_store = (Path.home() / '.local/share/seafile-next/signing').resolve()
    if path.is_symlink() or path.absolute() != resolved or resolved.parent != home_store:
        raise RuntimeError('Signing material requires a dedicated protected home directory')
    if not re.fullmatch(r'\d+-\d+-(apple|android)', resolved.name):
        raise RuntimeError('Unexpected signing directory identity')
    excluded = [Path(tempfile.gettempdir()), Path(__file__).resolve().parents[1]]
    excluded += [Path(os.environ[key]) for key in ('RUNNER_TEMP', 'GITHUB_WORKSPACE', 'BUILD_TMP') if os.environ.get(key)]
    if any(resolved.is_relative_to(root.resolve()) for root in excluded):
        raise RuntimeError('Signing material must stay outside checkout and temporary directories')
    if not resolved.is_dir() or resolved.stat().st_uid != os.getuid() or resolved.stat().st_mode & 0o077:
        raise RuntimeError('Signing directory must be owned by this user with private permissions')
    return resolved


def validate_build_directory(path):
    path = Path(path)
    resolved = path.resolve()
    runner_temp = Path(os.environ['RUNNER_TEMP']).resolve()
    checkout = Path(os.environ['GITHUB_WORKSPACE']).resolve()
    if path.is_symlink() or resolved.parent != runner_temp or not resolved.name.startswith('client-build.'):
        raise RuntimeError('Build files require a mktemp directory inside the runner temporary root')
    if resolved.is_relative_to(checkout):
        raise RuntimeError('Build files must stay outside the repository')
    return resolved


def export_tree(repository, destination, paths=()):
    destination.mkdir(parents=True, exist_ok=True)
    archive = subprocess.Popen(['git', '-C', str(repository), 'archive', 'HEAD', *paths], stdout=subprocess.PIPE)
    try:
        extract = subprocess.run(['tar', '-x', '-C', str(destination)], stdin=archive.stdout)
        archive.stdout.close()
        if archive.wait() or extract.returncode:
            raise RuntimeError('Cannot export tracked build sources')
    finally:
        if archive.poll() is None:
            archive.kill()
            archive.wait()


def prepare(workspace, platform):
    workspace = validate_build_directory(workspace)
    source = workspace / 'source'
    checkout = Path(os.environ['GITHUB_WORKSPACE'])
    paths = ('apple', 'sync', 'tools') if platform == 'apple' else ('android', 'tools')
    export_tree(checkout, source, paths)
    if platform == 'apple':
        export_tree(checkout / 'libsearpc', source / 'libsearpc')
    private = signing_directory(platform)
    # mkdir is exclusive: never overwrite or silently reuse leftovers from a
    # previous attempt. Every build restores the same persistent signing key.
    private.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    private.mkdir(mode=0o700)
    validate_signing_directory(private)
    logs = workspace / 'diagnostics'
    logs.mkdir(mode=0o700)
    (workspace / 'temporary').mkdir(mode=0o700)
    with open(os.environ['GITHUB_ENV'], 'a') as environment:
        values = {'BUILD_TMP': workspace, 'BUILD_SOURCE': source,
                  'SEAFILE_SIGNING_DIR': private, 'SIGNING_LOG_DIR': logs,
                  'GH_REPO': os.environ['GITHUB_REPOSITORY'], 'PYTHONDONTWRITEBYTECODE': '1',
                  'TMPDIR': workspace / 'temporary'}
        if platform == 'android':
            values.update({'SEAFILE_ANDROID_DEBUG_KEYSTORE': private / 'android.keystore',
                           'GRADLE_USER_HOME': workspace / 'gradle'})
        for key, value in values.items():
            environment.write(f'{key}={value}\n')
    print('Isolated build workspace and protected signing storage are ready.')


def cleanup(workspace, platform):
    failures = []
    def command(*args):
        try:
            subprocess.run(args, check=True, capture_output=True)
        except (OSError, subprocess.CalledProcessError):
            failures.append('Private signing cleanup command failed (diagnostics withheld)')
    private = signing_directory(platform)
    if private.exists():
        private = validate_signing_directory(private)
        if platform == 'apple':
            previous = private / 'keychains.json'
            if previous.exists():
                command('security', 'list-keychains', '-d', 'user', '-s', *json.loads(previous.read_text()))
            keychain = private / 'signing.keychain-db'
            if keychain.exists():
                command('security', 'delete-keychain', str(keychain))
            manifest = private / 'installed-profiles.json'
            if manifest.exists():
                roots = [Path.home() / location for location in
                         ('Library/MobileDevice/Provisioning Profiles', 'Library/Developer/Xcode/UserData/Provisioning Profiles')]
                for filename in json.loads(manifest.read_text()):
                    profile = Path(filename)
                    if profile.parent not in roots or profile.is_symlink() or not re.fullmatch(r'[A-Fa-f0-9-]+\.(mobileprovision|provisionprofile)', profile.name):
                        raise RuntimeError('Refusing to remove an unexpected installed profile')
                    profile.unlink(missing_ok=True)
        shutil.rmtree(private)
    if workspace:
        directory = validate_build_directory(workspace)
        if directory.exists():
            shutil.rmtree(directory)
    print('Build artifacts, private diagnostics and per-run signing files were removed.')
    if failures:
        raise RuntimeError(failures[0])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('prepare', 'cleanup'))
    parser.add_argument('--workspace', default=os.environ.get('BUILD_TMP', ''))
    parser.add_argument('--platform', choices=('apple', 'android'), required=True)
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.workspace, args.platform)
    else:
        cleanup(args.workspace, args.platform)


if __name__ == '__main__':
    main()
