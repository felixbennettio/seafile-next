#!/usr/bin/env python3
"""Restore and verify the fixed CI debug signer without generating a new key."""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import re
import subprocess
from ci_workspace import validate_signing_directory


def restore(destination: Path) -> str:
    encoded = os.environ.get("ANDROID_DEBUG_KEYSTORE", "").strip()
    expected = os.environ.get("ANDROID_DEBUG_CERT_SHA256", "").lower()
    if not encoded or not re.fullmatch(r"[a-f0-9]{64}", expected):
        raise ValueError("Fixed Android signing key or certificate pin is missing; refusing to generate a new signer.")
    payload = base64.b64decode(encoded, validate=True)
    validate_signing_directory(destination.parent)
    if destination.is_symlink():
        raise ValueError('Refusing a symlink signing store')
    temporary = destination.with_name(destination.name + '.candidate')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, 'wb') as file:
            file.write(payload)
        command = ["keytool", "-J-Duser.language=en", "-keystore", str(temporary), "-storepass", "android", "-alias", "AndroidDebugKey"]
        entry = subprocess.run(command + ["-list", "-v"], check=True, capture_output=True, text=True)
        if "PrivateKeyEntry" not in entry.stdout:
            raise ValueError("The Android signing store does not contain its private key.")
        certificate = subprocess.run(command + ["-exportcert"], check=True, capture_output=True).stdout
        actual = hashlib.sha256(certificate).hexdigest()
        if actual != expected:
            raise ValueError("Android signing certificate differs from the pinned signer; refusing to replace the signing store.")
        temporary.chmod(0o600)
        temporary.replace(destination)
        return actual
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", type=Path, required=True)
    args = parser.parse_args()
    try:
        fingerprint = restore(args.path)
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError):
        raise SystemExit("Cannot restore the fixed Android signing identity. Check the signing secret and certificate pin; no new key was generated.")
    print("Fixed Android signing identity verified; the existing signer was preserved.")
