import base64
import json
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from delivery.core import (
    build_waffo_request,
    make_download_token,
    resolve_installer,
    safe_installer_path,
    verify_download_token,
    verify_waffo_webhook,
)


class DeliveryCoreTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {
            "packages": {
                "windows-ok": {
                    "installer_file": "profiles/windows-ok.exe",
                    "sha256": "abc",
                    "size_bytes": 123,
                    "platform": "windows",
                    "model": "demo",
                    "model_label": "Demo",
                }
            },
            "routes": [
                {
                    "os": "windows",
                    "graphics": "amd",
                    "hardware_id": "rx-demo-8",
                    "memory_gb": None,
                    "runtime": "automatic",
                    "status": "installer_available",
                    "profile_id": "windows-ok",
                    "required_ram_gb": 16,
                },
                {
                    "os": "windows",
                    "graphics": "cpu-only",
                    "hardware_id": "cpu-only",
                    "memory_gb": 8,
                    "runtime": "automatic",
                    "status": "pending_validation",
                    "profile_id": "windows-pending",
                    "final_check": "physical_windows_8gb",
                },
            ],
        }

    def test_released_route_resolves_only_when_ram_is_sufficient(self):
        result = resolve_installer(
            self.manifest,
            {
                "os": "windows",
                "graphics": "amd",
                "hardwareId": "rx-demo-8",
                "runtime": "automatic",
                "systemRamGb": 16,
            },
        )
        self.assertEqual(result["status"], "installer_available")
        self.assertEqual(result["profileId"], "windows-ok")
        self.assertEqual(result["installerFile"], "profiles/windows-ok.exe")

    def test_pending_route_never_becomes_payable(self):
        result = resolve_installer(
            self.manifest,
            {
                "os": "windows",
                "graphics": "cpu-only",
                "hardwareId": "cpu-only",
                "runtime": "automatic",
                "memoryGb": 8,
                "systemRamGb": 8,
            },
        )
        self.assertEqual(result["status"], "pending_validation")
        self.assertEqual(result["finalCheck"], "physical_windows_8gb")

    def test_download_token_is_bound_to_order_profile_and_expiry(self):
        expiry = 2_000_000_000
        token = make_download_token("secret", "AGL_1", "windows-ok", expiry)
        self.assertTrue(
            verify_download_token(
                "secret", token, "AGL_1", "windows-ok", now=1_900_000_000
            )
        )
        self.assertFalse(
            verify_download_token(
                "secret", token, "AGL_2", "windows-ok", now=1_900_000_000
            )
        )
        self.assertFalse(
            verify_download_token(
                "secret", token, "AGL_1", "wrong", now=1_900_000_000
            )
        )
        self.assertFalse(
            verify_download_token(
                "secret", token, "AGL_1", "windows-ok", now=2_100_000_000
            )
        )

    def test_safe_installer_path_blocks_traversal(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ok = safe_installer_path(root, "profiles/demo.exe")
            self.assertEqual(ok, (root / "profiles/demo.exe").resolve())
            with self.assertRaises(ValueError):
                safe_installer_path(root, "../secret.txt")

    def test_waffo_request_signature_matches_documented_canonical_request(self):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        private_pem = key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ).decode()
        body = {
            "productId": "PROD_demo",
            "currency": "USD",
            "orderMerchantExternalId": "AGL_1",
        }
        raw_body, headers = build_waffo_request(
            method="POST",
            path="/v1/actions/checkout/create-session",
            body=body,
            merchant_id="MER_demo",
            private_key_pem=private_pem,
            idempotency_key="test_key_1",
            timestamp=1_700_000_000,
        )
        import hashlib

        body_hash = base64.b64encode(hashlib.sha256(raw_body).digest()).decode()
        canonical = (
            "POST\n/v1/actions/checkout/create-session\n1700000000\n" + body_hash
        ).encode()
        signature = base64.b64decode(headers["X-Signature"])
        key.public_key().verify(
            signature, canonical, padding.PKCS1v15(), hashes.SHA256()
        )
        self.assertEqual(headers["X-Idempotency-Key"], "test_key_1")

    def test_waffo_webhook_signature_verification_and_timestamp_window(self):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        public_pem = key.public_key().public_bytes(
            serialization.Encoding.PEM,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        ).decode()
        raw_body = json.dumps(
            {"eventType": "order.completed", "eventId": "evt_1"},
            separators=(",", ":"),
        ).encode()
        timestamp_ms = 1_700_000_000_000
        signed = str(timestamp_ms).encode() + b"." + raw_body
        signature = key.sign(signed, padding.PKCS1v15(), hashes.SHA256())
        header = f"t={timestamp_ms},v1={base64.b64encode(signature).decode()}"
        self.assertTrue(
            verify_waffo_webhook(
                raw_body, header, public_pem, now_ms=timestamp_ms + 1000
            )
        )
        self.assertFalse(
            verify_waffo_webhook(
                raw_body,
                header,
                public_pem,
                now_ms=timestamp_ms + 46 * 60 * 1000,
            )
        )
        self.assertFalse(
            verify_waffo_webhook(
                raw_body + b"x", header, public_pem, now_ms=timestamp_ms + 1000
            )
        )


if __name__ == "__main__":
    unittest.main()
