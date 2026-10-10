#!/usr/bin/env python3
"""Reuse a tested native run without repeating unchanged builds or UI tests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import zipfile

from ci_workspace import validate_build_directory
from replace_release_clients import validate_apple_version
from publish_release import validate_package


def github(path):
    return json.loads(subprocess.check_output(['gh', 'api', 'repos/' + os.environ['GITHUB_REPOSITORY'] + '/' + path], text=True))


def verify_run(record, jobs, current='HEAD'):
    if record['status'] != 'completed' or record['path'] != '.github/workflows/apple.yml' or record['head_branch'] != 'main':
        raise RuntimeError('Reuse a completed main native Apple run')
    build = [job for job in jobs if job['name'] == 'build']
    if len(build) != 1:
        raise RuntimeError('Cannot identify the tested native build')
    steps = {step['name']: step['conclusion'] for step in build[0]['steps']}
    for name in ('Test APIs and build native Mac client', 'Test iPhone navigation and sign-in controls',
                 'Package non-sandbox Mac client'):
        if steps.get(name) != 'success':
            raise RuntimeError('Reuse requires successful native tests and the direct Mac package')
    commit = record['head_sha']
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise RuntimeError('Unexpected validation commit')
    for path in ('apple', 'sync', 'tools/build_apple_engine.sh'):
        built = subprocess.check_output(['git', 'rev-parse', commit + ':' + path], text=True).strip()
        now = subprocess.check_output(['git', 'rev-parse', current + ':' + path], text=True).strip()
        if built != now:
            raise RuntimeError('Native sources or engine build changed; run native validation again')
    return commit


def extract_engine(package, engine):
    prefix = 'seafile-next.app/Contents/Resources/Engine/'
    root = engine.resolve()
    with zipfile.ZipFile(package) as archive:
        for info in archive.infolist():
            if not info.filename.startswith(prefix) or info.is_dir():
                continue
            relative = Path(info.filename.removeprefix(prefix))
            destination = engine / relative
            if relative.is_absolute() or '..' in relative.parts or not destination.resolve().is_relative_to(root):
                raise RuntimeError('Unsafe reused engine path')
            destination.parent.mkdir(parents=True, exist_ok=True)
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode):
                target = archive.read(info).decode('utf-8')
                if Path(target).is_absolute() or not (destination.parent / target).resolve().is_relative_to(root):
                    raise RuntimeError('Unsafe reused engine symlink')
                destination.symlink_to(target)
            else:
                with archive.open(info) as source, destination.open('wb') as output:
                    shutil.copyfileobj(source, output)
                destination.chmod(mode & 0o755 or 0o644)
    daemon = engine / 'seaf-daemon'
    if not daemon.is_file() or not os.access(daemon, os.X_OK):
        raise RuntimeError('Missing executable in the validated sync engine')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', required=True)
    parser.add_argument('--workspace', required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    if not args.run.isdecimal() or not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        raise RuntimeError('Invalid validation run or release version')
    workspace = validate_build_directory(args.workspace)
    base = 'actions/runs/' + args.run
    commit = verify_run(github(base), github(base + '/jobs?per_page=100')['jobs'])
    artifacts = github(base + '/artifacts?per_page=100')['artifacts']
    candidates = [a for a in artifacts if a['name'] == 'native-apple-validation' and not a['expired']]
    if len(candidates) != 1 or not re.fullmatch(r'sha256:[a-f0-9]{64}', candidates[0].get('digest', '')):
        raise RuntimeError('Missing validated package artifact or its integrity digest')
    artifact = candidates[0]
    temporary = workspace / 'validated-artifact.zip'
    try:
        with temporary.open('wb') as output:
            result = subprocess.run(['gh', 'api', 'repos/' + os.environ['GITHUB_REPOSITORY'] +
                                     '/actions/artifacts/' + str(artifact['id']) + '/zip'], stdout=output, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError('Cannot download the validated package artifact (diagnostics withheld)')
        with temporary.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if artifact['digest'] != 'sha256:' + digest:
            raise RuntimeError('Validated artifact integrity check failed')
        output = workspace / 'source/dist'
        output.mkdir(parents=True, exist_ok=True)
        package = output / 'seafile-next-macos-arm64-direct.zip'
        with zipfile.ZipFile(temporary) as archive:
            names = [n for n in archive.namelist() if n.endswith('/' + package.name) or n == package.name]
            if len(names) != 1:
                raise RuntimeError('Expected exactly one validated direct Mac package')
            # Extract only this package; do not expand the large test bundles.
            with archive.open(names[0]) as source, package.open('wb') as destination:
                shutil.copyfileobj(source, destination)
        validate_package('macos', package)
        validate_apple_version('macos', package, args.version)
        extract_engine(package, workspace / 'source/apple/Engine')
        proof = {'validatedRun': args.run, 'buildCommit': commit, 'nativeSourcesUnchanged': True}
        (workspace / 'validation-reuse.json').write_text(json.dumps(proof) + '\n')
    finally:
        temporary.unlink(missing_ok=True)
    print('Successful native tests, direct Mac package and unchanged engine sources verified for delivery.')


if __name__ == '__main__':
    main()
