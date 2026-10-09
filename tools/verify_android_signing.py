#!/usr/bin/env python3
"""Check the built APK's actual signature against the fixed CI certificate."""
import argparse
import os
from pathlib import Path
import re
import subprocess


def verify(apk: Path, apksigner: str, expected: str) -> str:
    expected = expected.lower().strip()
    if not re.fullmatch(r"[a-f0-9]{64}", expected) or not apk.is_file():
        raise ValueError("Missing APK or pinned Android certificate")
    result = subprocess.run([apksigner, "verify", "--verbose", "--print-certs", str(apk)],
                            capture_output=True, text=True, check=True)
    count = re.search(r"^Number of signers: (\d+)\s*$", result.stdout, re.MULTILINE)
    if count is None or count.group(1) != "1":
        raise ValueError("The APK must have exactly one signer")
    # SDK 36+ uses scheme labels, while earlier tools number each signer.
    signers = {value.lower() for value in re.findall(
        r"^(?:Signer #\d+|V\d+(?:\.\d+)? Signer:) certificate SHA-256 digest: ([a-fA-F0-9]{64})\s*$",
        result.stdout, re.MULTILINE)}
    if len(signers) != 1:
        raise ValueError("Expected one APK certificate; found " + str(len(signers)))
    actual = next(iter(signers))
    if actual != expected:
        raise ValueError("APK certificate " + actual + " differs from pinned " + expected)
    return actual


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--apksigner", required=True)
    args = parser.parse_args()
    try:
        fingerprint = verify(args.apk, args.apksigner, os.environ.get("ANDROID_DEBUG_CERT_SHA256", ""))
    except ValueError as error:
        raise SystemExit("APK signature verification failed: " + str(error) + "; the package must not be published")
    except (OSError, subprocess.CalledProcessError):
        raise SystemExit("Android SDK rejected the APK signature or the verifier was unavailable; the package must not be published")
    print("Packaged APK signature verified: " + fingerprint)
