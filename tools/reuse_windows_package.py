#!/usr/bin/env python3
"""Validate a complete Windows artifact without recompiling an unchanged app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

from desktop_ci_workspace import validate
from publish_release import validate_package

REPOSITORY = 'felixbennettio/seafile-next'


def github(path):
    return json.loads(subprocess.check_output(['gh', 'api', 'repos/' + REPOSITORY + '/' + path], text=True))


def verify_build(record, jobs, current='HEAD'):
    if record['status'] != 'completed' or record['path'] != '.github/workflows/desktop.yml' or record['conclusion'] not in ('success', 'failure'):
        raise RuntimeError('Reuse a completed retained Windows application build')
    if any(job['conclusion'] in ('failure', 'cancelled', 'timed_out') and job['name'] != 'windows' for job in jobs):
        raise RuntimeError('An unrelated original validation failed')
    required = {
        'windows': ['Build libsearpc and sync core', 'Build GUI', 'Assemble unsigned portable package', 'Upload seafile-next Windows artifact'],
        'windows-shell': ['Build the retained Explorer extension', 'Remove temporary desktop build and download files'],
        'windows-integration-validation': ['Test DLL loading and isolated registration', 'Remove temporary desktop build and download files'],
    }
    for name, stages in required.items():
        found = [job for job in jobs if job['name'] == name]
        if len(found) != 1:
            raise RuntimeError('Missing original Windows application or integration validation')
        if found[0]['conclusion'] not in (('success', 'failure') if name == 'windows' else ('success',)):
            raise RuntimeError('The original Windows validation did not finish successfully')
        steps = {step['name']: step['conclusion'] for step in found[0]['steps']}
        if any(steps.get(stage) != 'success' for stage in stages):
            raise RuntimeError('The original Windows application and integration must be successful')
        failed = [step['name'] for step in found[0]['steps'] if step['conclusion'] == 'failure']
        if failed and (name != 'windows' or failed != ['Remove temporary desktop build and download files']):
            raise RuntimeError('Only the separately repaired temporary cleanup failure can be recovered')
        if name == 'windows' and (steps.get('Remove temporary desktop build and download files') not in ('success', 'failure') or
                (found[0]['conclusion'] == 'failure' and failed != ['Remove temporary desktop build and download files'])):
            raise RuntimeError('The original Windows failure must be confined to temporary cleanup')
    commit = record['head_sha']
    if not re.fullmatch(r'[a-f0-9]{40}', commit): raise RuntimeError('Unexpected original build revision')
    for directory in ('desktop', 'sync', 'tools/windows-integration'):
        original = subprocess.check_output(['git', 'rev-parse', commit + ':' + directory], text=True).strip()
        current_tree = subprocess.check_output(['git', 'rev-parse', current + ':' + directory], text=True).strip()
        if original != current_tree: raise RuntimeError('The retained Windows application sources have changed')
    return commit


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', required=True)
    parser.add_argument('--workspace', required=True, type=Path)
    args = parser.parse_args()
    if not args.run.isdecimal(): raise RuntimeError('Use a numeric original Windows run')
    root = validate(args.workspace)
    commit = verify_build(github('actions/runs/' + args.run), github('actions/runs/' + args.run + '/jobs?per_page=100')['jobs'])
    artifacts = github('actions/runs/' + args.run + '/artifacts?per_page=100')['artifacts']
    matching = [item for item in artifacts if item['name'] == 'seafile-next-windows-x64' and not item['expired']]
    if len(matching) != 1 or not re.fullmatch(r'sha256:[a-f0-9]{64}', matching[0].get('digest', '')):
        raise RuntimeError('Missing original portable artifact or its integrity digest')
    artifact = matching[0]; incoming = root / 'original-artifact.zip'
    with incoming.open('wb') as stream:
        result = subprocess.run(['gh', 'api', 'repos/' + REPOSITORY + '/actions/artifacts/' + str(artifact['id']) + '/zip'], stdout=stream, stderr=subprocess.PIPE)
    if result.returncode: raise RuntimeError('Original artifact download failed; diagnostics withheld')
    with incoming.open('rb') as stream:
        if artifact['digest'] != 'sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest():
            raise RuntimeError('Original artifact integrity check failed')
    with zipfile.ZipFile(incoming) as archive:
        packages = [item for item in archive.infolist() if re.fullmatch(r'(?:[^/]+/)*[^/]*windows[^/]*x64[^/]*unsigned\.zip', item.filename)]
        if len(packages) != 1: raise RuntimeError('Expected one original portable Windows ZIP')
        package = root / 'seafile-next-windows-x64-unsigned.zip'
        with archive.open(packages[0]) as source, package.open('wb') as output: shutil.copyfileobj(source, output)
    validate_package('windows', package)
    app = root / 'application'; app.mkdir()
    with zipfile.ZipFile(package) as archive:
        if sum(item.file_size for item in archive.infolist()) > 2 * 1024**3: raise RuntimeError('Unexpected expanded Windows package size')
        for item in archive.infolist():
            destination = app / item.filename
            if not destination.resolve().is_relative_to(app.resolve()) or ':' in item.filename or '\\' in item.filename:
                raise RuntimeError('Unsafe Windows package member')
            if item.is_dir(): destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as source, destination.open('wb') as output: shutil.copyfileobj(source, output)
    executables = list(app.rglob('seafile-applet.exe'))
    if len(executables) != 1: raise RuntimeError('Expected one original Windows application')
    binary = executables[0]
    # Ping exits after loading QApplication and the packaged runtime, without
    # starting a daemon, connecting an account or modifying server files.
    config = root / 'runtime-config'; config.mkdir()
    result = subprocess.run([str(binary), '--config-dir', str(config), '--ping'], cwd=binary.parent, capture_output=True, timeout=30)
    if result.returncode != 0 or b'failed to connect to applet rpc server' not in result.stdout:
        raise RuntimeError('Retained Windows runtime could not start; diagnostics withheld')
    integration = root / 'integration'; integration.mkdir()
    for name in ('seafile_shell_ext64.dll', 'WindowsIntegration.ps1', 'Install-WindowsIntegration.cmd', 'Uninstall-WindowsIntegration.cmd'):
        matching = list(app.rglob(name))
        if len(matching) != 1: raise RuntimeError('Retained Explorer integration is incomplete')
        shutil.copy2(matching[0], integration / name)
    subprocess.run(['pwsh', '-NoProfile', '-File', 'tools/tests/test_windows_integration.ps1', '-PackageDirectory', str(integration)], check=True)
    with package.open('rb') as stream: digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    (root / 'windows-reuse.json').write_text(json.dumps({'sourceRun': args.run, 'buildCommit': commit, 'packageSha256': digest, 'applicationContentsUnchanged': True}) + '\n')
    print('Original Windows build, portable runtime, Explorer integration and unchanged package contents verified.')


if __name__ == '__main__': main()
