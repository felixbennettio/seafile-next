#!/usr/bin/env python3
"""Permit delivery-only recovery when the native sources already passed CI."""
import argparse
import json
import re
import subprocess


def github(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repository', required=True)
    parser.add_argument('--run', required=True)
    parser.add_argument('--build', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', args.repository) or not args.run.isdecimal():
        raise RuntimeError('Invalid repository or validation run')
    if not re.fullmatch(r'\d{1,4}\.\d{1,2}\.\d{1,2}', args.build):
        raise RuntimeError('Invalid previously uploaded build number')
    base = 'repos/' + args.repository + '/actions/runs/' + args.run
    run = github(base)
    if run['status'] != 'completed' or run['path'] != '.github/workflows/apple.yml' or run['head_branch'] != 'main':
        raise RuntimeError('Use a completed main native Apple run')
    jobs = github(base + '/jobs?per_page=100')['jobs']
    tested = [job for job in jobs if job['name'] == 'build']
    if len(tested) != 1:
        raise RuntimeError('Cannot identify the native validation job')
    steps = {step['name']: step['conclusion'] for step in tested[0]['steps']}
    for name in ['Test APIs and build native Mac client', 'Test iPhone navigation and sign-in controls']:
        if steps.get(name) != 'success':
            raise RuntimeError('Required native validation did not pass: ' + name)
    sha = run['head_sha']
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise RuntimeError('Invalid validation commit')
    subprocess.run(['git', 'fetch', '--depth=1', 'origin', sha], check=True)
    # Compare the whole tree: the engine also consumes shared C sources outside
    # apple/ and sync/. Only documentation and delivery metadata may differ.
    changed = subprocess.check_output(['git', 'diff', '--name-only', sha, 'HEAD'], text=True).splitlines()
    allowed = {'tools/apple_testflight.py', 'tools/verify_apple_resume.py', '.github/workflows/apple-resume.yml'}
    if any(path not in allowed and not path.startswith('docs/') for path in changed):
        raise RuntimeError('Sources or build/signing configuration changed; run the full Apple validation workflow')
    print('Verified previously passed native tests and unchanged sources:', sha, flush=True)


if __name__ == '__main__':
    main()
