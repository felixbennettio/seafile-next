#!/usr/bin/env python3
"""Normalize only public application payload permissions before pkg export."""
import argparse
from pathlib import Path
import stat


def normalize(archive):
    applications = Path(archive) / 'Products/Applications'
    apps = list(applications.glob('*.app'))
    if len(apps) != 1:
        raise RuntimeError('Expected one application payload')
    app = apps[0]
    if app.is_symlink():
        raise RuntimeError('Application payload must not be a symbolic link')
    root = app.resolve()
    paths = [app, *app.rglob('*')]
    for path in paths:
        if path.is_symlink():
            if not path.resolve().is_relative_to(root):
                raise RuntimeError('Application payload has an external symbolic link')
            continue
        if path.suffix.lower() in ('.p8', '.p12', '.key', '.keystore'):
            raise RuntimeError('Private signing material must not enter an application payload')
        if not path.is_dir() and not path.is_file():
            raise RuntimeError('Unexpected application payload object')
    for path in paths:
        if not path.is_symlink():
            mode = stat.S_IMODE(path.stat().st_mode)
            path.chmod(0o755 if path.is_dir() or mode & 0o111 else 0o644)
    print('Application payload permissions verified for non-root installation.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('archive', type=Path)
    normalize(parser.parse_args().archive)


if __name__ == '__main__':
    main()
