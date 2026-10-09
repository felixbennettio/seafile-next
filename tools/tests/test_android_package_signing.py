import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_android_signing import verify

class PackageSigningTests(unittest.TestCase):
    pin = "d" * 64
    def check_output(self, output):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "test.apk"; apk.touch()
            with patch("verify_android_signing.subprocess.run", return_value=subprocess.CompletedProcess([], 0, output, "")):
                return verify(apk, "apksigner", self.pin)
    def test_current_sdk_scheme_label(self):
        self.assertEqual(self.pin, self.check_output("Number of signers: 1\nV2 Signer: certificate SHA-256 digest: " + self.pin + "\n"))
    def test_earlier_sdk_numbered_label(self):
        self.assertEqual(self.pin, self.check_output("Number of signers: 1\nSigner #1 certificate SHA-256 digest: " + self.pin + "\n"))
    def test_multiple_signers_are_rejected_even_with_equal_certificates(self):
        with self.assertRaises(ValueError): self.check_output("Number of signers: 2\nV2 Signer: certificate SHA-256 digest: " + self.pin + "\n")
    def test_wrong_certificate_and_unrecognized_output_are_rejected(self):
        for output in ("Number of signers: 1\nV2 Signer: certificate SHA-256 digest: " + "e" * 64 + "\n", "Number of signers: 1\nUnknown certificate format\n"):
            with self.assertRaises(ValueError): self.check_output(output)
