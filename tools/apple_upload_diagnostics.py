#!/usr/bin/env python3
"""Describe upload failures using fixed labels and Apple error codes only."""
import argparse
from pathlib import Path
import re


def summary(log):
    codes = sorted(set(re.findall(r'\bITMS-\d{4,6}\b', log)))
    # Match only numeric error values, never arbitrary JSON fields or messages.
    codes += sorted(set(re.findall(r'"code"\s*:\s*(-\d{3,6})\b', log)))
    lower = log.lower()
    categories = {
        'duplicate build': ('already uploaded', 'previously uploaded', 'redundant binary upload'),
        'version metadata': ('cfbundleversion', 'cfbundleshortversionstring'),
        'sandbox configuration': ('app-sandbox', 'sandbox entitlement'),
        'code signing': ('invalid signature', 'not signed', 'signing certificate', 'provisioning profile'),
        'binary architecture': ('unsupported architecture', 'missing required architecture', 'invalid binary'),
        'bundle layout': ('invalid bundle', 'bundle format', 'cfbundleexecutable'),
        'network connection': ('connection reset', 'connection was lost', 'timed out', 'tls handshake'),
        'authentication': ('authentication failed', 'not authorized', 'invalid credentials'),
        'bundle identifier': ('bundle identifier', 'bundle id'),
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
