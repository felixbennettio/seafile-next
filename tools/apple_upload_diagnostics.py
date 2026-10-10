#!/usr/bin/env python3
"""Describe upload failures using fixed labels and Apple error codes only."""
import argparse
import json
from pathlib import Path
import re


def summary(log):
    # Exclude tool paths and ordinary framework metadata from classification.
    # Only Apple's error fields are relevant when altool emits JSON.
    decoder = json.JSONDecoder()
    for position, character in enumerate(log):
        if character != '{':
            continue
        try:
            payload, _ = decoder.raw_decode(log[position:])
        except ValueError:
            continue
        if isinstance(payload, dict) and isinstance(payload.get('product-errors'), list):
            log = json.dumps(payload['product-errors'], ensure_ascii=False)
            break
    codes = sorted(set(re.findall(r'\bITMS-\d{4,6}\b', log)))
    # Match only numeric error values, never arbitrary JSON fields or messages.
    codes += sorted(set(re.findall(r'"code"\s*:\s*(-\d{3,6})\b', log)))
    lower = log.lower()
    categories = {
        'duplicate build': ('already uploaded', 'previously uploaded', 'redundant binary upload', 'already been used', 'previously uploaded version'),
        'version metadata': ('cfbundleversion', 'cfbundleshortversionstring'),
        'sandbox configuration': ('app-sandbox', 'sandbox entitlement'),
        'code signing': ('invalid signature', 'not signed', 'signing certificate', 'provisioning profile'),
        'binary architecture': ('unsupported architecture', 'missing required architecture', 'invalid binary'),
        'bundle layout': ('invalid bundle', 'bundle format', 'cfbundleexecutable'),
        'network connection': ('connection reset', 'connection was lost', 'timed out', 'tls handshake'),
        'authentication': ('authentication failed', 'not authorized', 'invalid credentials'),
        'bundle identifier': ('bundle identifier', 'bundle id'),
        'bundle location': ('bundle location', 'bundle structure', 'unsealed', 'symlink', 'symbolic link', 'invalid directory'),
        'app icon': ('app icon', 'icon file', 'iconset', 'appicon'),
        'SDK compatibility': ('sdk', 'minimum os', 'deployment target', 'xcode version'),
        'non-public API': ('non-public', 'private api'),
        'corrupted executable': ('corrupt', 'malformed', 'invalid executable'),
        'missing bundle metadata': ('info.plist', 'missing required', 'required key'),
        'embedded framework': ('framework', 'dynamic library', 'dylib'),
        'Apple upload service': ('server error', 'unexpected error', 'internal error', 'service unavailable'),
        'unsupported language': ('localization', 'localisation', 'language code'),
        'application record state': ('pre-release train', 'closed train', 'app is removed', 'app is deleted', 'app state'),
        'package identity': ('package identifier', 'package id', 'product identifier', 'installer'),
        'upload tool unavailable': ('unable to find utility', 'no such file or directory', 'verified temporary apple uploader is required'),
    }
    labels = [name for name, patterns in categories.items() if any(p in lower for p in patterns)]
    return 'Apple upload failure: ' + '; '.join(codes + labels or ['unclassified; private diagnostics withheld'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('log', type=Path)
    args = parser.parse_args()
    print(summary(args.log.read_text(errors='replace')))


if __name__ == '__main__':
    main()
