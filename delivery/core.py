from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import time
from pathlib import Path
from typing import Any


class DeliveryError(ValueError):
    pass


def resolve_installer(manifest: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    routes = manifest.get("routes")
    if not isinstance(routes, list):
        raise DeliveryError("manifest_error")

    runtime = payload.get("runtime") or "automatic"
    memory_gb = _number_or_none(payload.get("memoryGb"))
    system_ram_gb = _number_or_none(payload.get("systemRamGb"))

    route = next(
        (
            row
            for row in routes
            if row.get("os") == payload.get("os")
            and row.get("graphics") == payload.get("graphics")
            and row.get("hardware_id") == payload.get("hardwareId")
            and row.get("runtime") == runtime
            and (
                row.get("memory_gb") is None
                or _number_or_none(row.get("memory_gb")) == memory_gb
            )
        ),
        None,
    )

    if route is None:
        return {"status": "no_released_installer"}

    if route.get("status") != "installer_available":
        return {
            "status": route.get("status") or "no_released_installer",
            "profileId": route.get("profile_id"),
            "finalCheck": route.get("final_check"),
        }

    required_ram = _number_or_none(route.get("required_ram_gb"))
    if required_ram is not None:
        if system_ram_gb is None:
            return {
                "status": "need_system_ram",
                "requiredRamGb": required_ram,
                "profileId": route.get("profile_id"),
            }
        if system_ram_gb < required_ram:
            return {
                "status": "not_enough_ram",
                "requiredRamGb": required_ram,
                "detectedRamGb": system_ram_gb,
                "profileId": route.get("profile_id"),
            }

    profile_id = route.get("profile_id")
    package = (manifest.get("packages") or {}).get(profile_id)
    if not package:
        raise DeliveryError("manifest_error")

    return {
        "status": "installer_available",
        "profileId": profile_id,
        "installerFile": package.get("installer_file"),
        "sha256": package.get("sha256"),
        "sizeBytes": package.get("size_bytes"),
        "platform": package.get("platform"),
        "model": package.get("model"),
        "modelLabel": package.get("model_label"),
    }


def make_download_token(secret: str, order_id: str, profile_id: str, expires_at: int) -> str:
    if not secret:
        raise DeliveryError("delivery_signing_secret_missing")
    message = f"{order_id}|{profile_id}|{int(expires_at)}".encode("utf-8")
    digest = hmac.new(secret.encode("utf-8"), message, hashlib.sha256).digest()
    return f"v1.{int(expires_at)}.{_b64url(digest)}"


def verify_download_token(
    secret: str,
    token: str,
    order_id: str,
    profile_id: str,
    now: int | None = None,
) -> bool:
    try:
        version, expiry_text, supplied = token.split(".", 2)
        if version != "v1":
            return False
        expiry = int(expiry_text)
    except (ValueError, AttributeError):
        return False
    if expiry < int(time.time() if now is None else now):
        return False
    expected = make_download_token(secret, order_id, profile_id, expiry).split(".", 2)[2]
    return hmac.compare_digest(expected, supplied)


def parse_waffo_signature_header(header: str) -> tuple[str, str]:
    parts: dict[str, str] = {}
    for pair in (header or "").split(","):
        if "=" not in pair:
            continue
        key, value = pair.split("=", 1)
        parts[key.strip()] = value.strip()
    timestamp = parts.get("t")
    signature = parts.get("v1")
    if not timestamp or not signature:
        raise DeliveryError("invalid_waffo_signature_header")
    return timestamp, signature


def verify_waffo_webhook(
    raw_body: bytes,
    signature_header: str,
    public_key_pem: str,
    *,
    now_ms: int | None = None,
    tolerance_ms: int = 45 * 60 * 1000,
) -> bool:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    try:
        timestamp, signature_b64 = parse_waffo_signature_header(signature_header)
        timestamp_ms = int(timestamp)
        current_ms = int(time.time() * 1000) if now_ms is None else int(now_ms)
        if abs(current_ms - timestamp_ms) > tolerance_ms:
            return False
        signed = timestamp.encode("utf-8") + b"." + raw_body
        signature = base64.b64decode(signature_b64, validate=True)
        key = serialization.load_pem_public_key(_normalize_pem(public_key_pem).encode("utf-8"))
        key.verify(signature, signed, padding.PKCS1v15(), hashes.SHA256())
        return True
    except Exception:
        return False


def build_waffo_request(
    *,
    method: str,
    path: str,
    body: dict[str, Any],
    merchant_id: str,
    private_key_pem: str,
    idempotency_key: str | None = None,
    timestamp: int | None = None,
) -> tuple[bytes, dict[str, str]]:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    raw_body = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    body_hash = base64.b64encode(hashlib.sha256(raw_body).digest()).decode("ascii")
    ts = str(int(time.time()) if timestamp is None else int(timestamp))
    canonical = f"{method.upper()}\n{path}\n{ts}\n{body_hash}".encode("utf-8")
    key = serialization.load_pem_private_key(
        _normalize_pem(private_key_pem).encode("utf-8"), password=None
    )
    signature = key.sign(canonical, padding.PKCS1v15(), hashes.SHA256())
    headers = {
        "Content-Type": "application/json",
        "X-Merchant-Id": merchant_id,
        "X-Timestamp": ts,
        "X-Signature": base64.b64encode(signature).decode("ascii"),
    }
    if idempotency_key:
        headers["X-Idempotency-Key"] = idempotency_key
    return raw_body, headers


def safe_installer_path(artifact_root: str | os.PathLike[str], installer_file: str) -> Path:
    root = Path(artifact_root).resolve()
    candidate = (root / installer_file).resolve()
    if root != candidate and root not in candidate.parents:
        raise DeliveryError("invalid_installer_path")
    return candidate


def _number_or_none(value: Any) -> float | None:
    if value is None or value == "":
        return None
    return float(value)


def _b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def _normalize_pem(value: str) -> str:
    return (value or "").replace("\\n", "\n").strip() + "\n"
