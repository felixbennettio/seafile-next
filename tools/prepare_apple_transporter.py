#!/usr/bin/env python3
"""Extract Apple's signed Transporter into the owned CI build workspace."""
import os
from pathlib import Path
import re
import subprocess
import urllib.request

from ci_workspace import validate_build_directory

URL = 'https://itunesconnect.apple.com/WebObjects/iTunesConnect.woa/ra/resources/download/public/Transporter__OSX/bin/'


def main():
    workspace = validate_build_directory(os.environ['BUILD_TMP'])
    installer = workspace / 'transporter.pkg'
    with urllib.request.urlopen(URL, timeout=60) as response, installer.open('wb') as output:
        total = 0
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > 500 * 1024 * 1024:
                raise RuntimeError('Apple uploader download exceeds its size limit')
            output.write(chunk)
    result = subprocess.run(['pkgutil', '--check-signature', str(installer)], capture_output=True, text=True)
    if result.returncode or not re.search(r'(Developer ID Installer: Apple Inc\.|Software Signing)', result.stdout):
        raise RuntimeError('Apple uploader installer signature could not be verified')
    extracted = workspace / 'transporter'
    result = subprocess.run(['pkgutil', '--expand-full', str(installer), str(extracted)], capture_output=True)
    if result.returncode:
        raise RuntimeError('Apple uploader could not be extracted')
    binaries = [path for path in extracted.rglob('iTMSTransporter') if path.is_file() and path.parent.name == 'bin']
    if len(binaries) != 1:
        raise RuntimeError('Cannot uniquely locate the Apple uploader')
    binary = binaries[0]
    binary.chmod(binary.stat().st_mode | 0o100)
    with open(os.environ['GITHUB_ENV'], 'a') as environment:
        environment.write('SEAFILE_TRANSPORTER=' + str(binary) + '\n')
        environment.write('TRANSPORTER_HOME=' + str(binary.parent.parent) + '\n')
    installer.unlink()
    print('Official signed Apple uploader is ready in the temporary build workspace.')


if __name__ == '__main__':
    main()
