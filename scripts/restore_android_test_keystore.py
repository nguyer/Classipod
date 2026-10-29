"""Restore the dedicated CI test key without printing or committing its contents."""

import base64
import binascii
import hashlib
import os
from pathlib import Path
import subprocess
import sys


def restore(encoded, destination, expected_fingerprint, export_certificate):
    if not encoded:
        raise ValueError("Configure the CLASSIPOD_TEST_KEYSTORE_BASE64 Actions secret.")
    try:
        payload = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("The test signing secret is not valid base64.") from None
    if not payload:
        raise ValueError("The test signing key is empty.")
    try:
        with destination.open("wb") as key_file:
            os.chmod(destination, 0o600)
            key_file.write(payload)
        certificate = export_certificate(destination)
        actual = hashlib.sha256(certificate).hexdigest()
        if actual != expected_fingerprint.strip().lower():
            raise ValueError("Test signing certificate changed; refusing incompatible APK.")
        return actual
    except Exception:
        destination.unlink(missing_ok=True)
        raise


def export_certificate(destination):
    # These are Android's standard debug key alias/password, not release secrets.
    result = subprocess.run(
        ["keytool", "-exportcert", "-keystore", str(destination),
         "-alias", "androiddebugkey", "-storepass", "android"],
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise ValueError("Cannot open test signing key with the debug alias/password.")
    return result.stdout


def main():
    destination = Path(os.environ["RUNNER_TEMP"]) / "classipod-test.keystore"
    fingerprint_file = Path(__file__).resolve().parent.parent / ".github" / "test-signing.sha256"
    try:
        fingerprint = restore(
            os.environ.get("CLASSIPOD_TEST_KEYSTORE_BASE64", ""),
            destination,
            fingerprint_file.read_text(encoding="utf-8"),
            export_certificate,
        )
        with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as output:
            output.write(f"CLASSIPOD_TEST_KEYSTORE_PATH={destination}\n")
        print(f"Restored persistent test signing certificate SHA-256: {fingerprint}")
    except (ValueError, OSError) as error:
        destination.unlink(missing_ok=True)
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
