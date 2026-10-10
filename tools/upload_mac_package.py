#!/usr/bin/env python3
"""Upload the exported Mac installer using Apple's Transporter client."""
import argparse
import os
from pathlib import Path
import subprocess

from ci_workspace import validate_signing_directory


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('package', type=Path)
    args = parser.parse_args()
    private = validate_signing_directory(os.environ['SEAFILE_SIGNING_DIR'])
    key = private / ('AuthKey_' + os.environ['APP_STORE_CONNECT_KEY_ID'] + '.p8')
    if not key.is_file() or key.is_symlink() or key.stat().st_mode & 0o077:
        raise RuntimeError('The existing protected API key is required')
    # Transporter searches cwd/private_keys. Link the existing protected key;
    # never copy it into a checkout or the build temporary directory.
    keys = private / 'private_keys'; keys.mkdir(mode=0o700, exist_ok=True)
    (keys / key.name).symlink_to('../' + key.name)
    diagnostics = Path(os.environ['SIGNING_LOG_DIR'])
    binary = Path(os.environ['SEAFILE_TRANSPORTER'])
    if not binary.is_file() or not binary.resolve().is_relative_to(Path(os.environ['BUILD_TMP']).resolve()):
        raise RuntimeError('The verified temporary Apple uploader is required')
    command = [str(binary), '-m', 'upload', '-assetFile', str(args.package.resolve()),
               '-apiKey', os.environ['APP_STORE_CONNECT_KEY_ID'], '-apiIssuer', os.environ['APP_STORE_CONNECT_ISSUER_ID'],
               '-v', 'critical', '-o', str(diagnostics / 'transporter.log'), '-errorLogs', str(diagnostics / 'transporter-errors')]
    try:
        environment = os.environ.copy()
        # Transporter obtains its scratch and cache paths through Java. Keep
        # those logs and generated packages in the same owned build workspace.
        scratch = Path(os.environ['BUILD_TMP']) / 'temporary'
        java_home = Path(os.environ['BUILD_TMP']) / 'transporter-home'; java_home.mkdir(exist_ok=True)
        environment['JAVA_TOOL_OPTIONS'] = f'-Djava.io.tmpdir={scratch} -Duser.home={java_home}'
        result = subprocess.run(command, cwd=private, env=environment, timeout=1200)
    except subprocess.TimeoutExpired:
        print('Apple upload service timed out; private diagnostics withheld.')
        raise SystemExit(1) from None
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
