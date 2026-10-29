import base64
import hashlib
from pathlib import Path
import tempfile
import unittest

from restore_android_test_keystore import restore


class TestAndroidTestSigning(unittest.TestCase):
    def test_repeated_restores_keep_the_same_identity(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "test.keystore"
            certificate = b"test certificate"
            fingerprint = hashlib.sha256(certificate).hexdigest()
            for _ in range(2):
                actual = restore("a2V5", path, fingerprint, lambda _: certificate)
                self.assertEqual(actual, fingerprint)
                self.assertEqual(path.read_bytes(), b"key")

    def test_missing_or_malformed_secrets_never_create_a_key(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "test.keystore"
            for encoded in ("", "not-base64!!"):
                with self.assertRaises(ValueError):
                    restore(encoded, path, "unused", lambda _: b"")
                self.assertFalse(path.exists())

    def test_changed_certificate_removes_key_and_refuses_build(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "test.keystore"
            with self.assertRaisesRegex(ValueError, "certificate changed"):
                restore(base64.b64encode(b"key"), path, "unexpected", lambda _: b"cert")
            self.assertFalse(path.exists())

    def test_unreadable_keystore_is_removed(self):
        def unreadable(_):
            raise ValueError("bad key")

        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "test.keystore"
            with self.assertRaises(ValueError):
                restore("a2V5", path, "unused", unreadable)
            self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
