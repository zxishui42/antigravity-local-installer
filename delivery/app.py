from __future__ import annotations

import json
import os
import sqlite3
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

import requests
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from .core import (
    DeliveryError,
    build_waffo_request,
    make_download_token,
    resolve_installer,
    safe_installer_path,
    verify_download_token,
    verify_waffo_webhook,
)

APP_VERSION = "0.1.0"
WAFFO_CREATE_SESSION_PATH = "/v1/actions/checkout/create-session"
WAFFO_CREATE_SESSION_URL = "https://api.waffo.ai" + WAFFO_CREATE_SESSION_PATH

app = FastAPI(title="Antigravity Local Delivery", version=APP_VERSION)


class CheckoutRequest(BaseModel):
    os: str
    graphics: str
    hardwareId: str
    runtime: str = "automatic"
    memoryGb: float | None = None
    systemRamGb: float | None = None
    email: str | None = Field(default=None, max_length=320)


class CheckoutResponse(BaseModel):
    orderId: str
    checkoutUrl: str
    profileId: str
    status: str = "pending"


def _env(name: str, default: str | None = None, required: bool = False) -> str:
    value = os.getenv(name, default)
    if required and not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value or ""


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def _db_path() -> Path:
    path = Path(_env("ORDER_DB_PATH", "delivery/data/orders.sqlite3"))
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(_db_path(), timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def _init_db() -> None:
    with _connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS orders (
                order_id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                status TEXT NOT NULL,
                email TEXT,
                os TEXT NOT NULL,
                graphics TEXT NOT NULL,
                hardware_id TEXT NOT NULL,
                memory_gb REAL,
                system_ram_gb REAL,
                runtime TEXT NOT NULL,
                profile_id TEXT NOT NULL,
                installer_file TEXT NOT NULL,
                installer_sha256 TEXT,
                installer_size_bytes INTEGER,
                waffo_session_id TEXT,
                waffo_checkout_url TEXT,
                waffo_order_id TEXT,
                waffo_payment_id TEXT,
                paid_at TEXT
            );

            CREATE TABLE IF NOT EXISTS webhook_events (
                event_id TEXT PRIMARY KEY,
                event_type TEXT NOT NULL,
                received_at TEXT NOT NULL,
                order_id TEXT
            );
            """
        )


@app.on_event("startup")
def startup() -> None:
    _init_db()


def _manifest() -> dict[str, Any]:
    path = Path(_env("INSTALLER_MANIFEST_PATH", "dist/site-download-manifest.json"))
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as exc:
        raise HTTPException(status_code=503, detail="installer_manifest_unavailable") from exc
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=503, detail="installer_manifest_invalid") from exc


def _new_order_id() -> str:
    return "AGL_" + uuid.uuid4().hex


def _public_base_url() -> str:
    return _env("PUBLIC_BASE_URL", "https://antigravitylocalmodels.com").rstrip("/")


def _success_url(order_id: str) -> str:
    return f"{_public_base_url()}/install/complete?{urlencode({'order': order_id})}"


def _waffo_checkout(order_id: str, profile_id: str, installer_file: str, email: str | None) -> dict[str, Any]:
    merchant_id = _env("WAFFO_MERCHANT_ID", required=True)
    private_key = _env("WAFFO_PRIVATE_KEY", required=True)
    product_id = _env("WAFFO_PRODUCT_ID", "PROD_47Yscc6M6VkB90yjfDREDW")
    currency = _env("WAFFO_CURRENCY", "USD")

    body: dict[str, Any] = {
        "productId": product_id,
        "currency": currency,
        "successUrl": _success_url(order_id),
        "expiresInSeconds": int(_env("WAFFO_CHECKOUT_TTL_SECONDS", "3600")),
        "orderMerchantExternalId": order_id,
        "metadata": {
            "profileId": profile_id,
            "installerFile": installer_file,
        },
        "language": "en",
    }
    if email:
        body["buyerEmail"] = email

    raw_body, headers = build_waffo_request(
        method="POST",
        path=WAFFO_CREATE_SESSION_PATH,
        body=body,
        merchant_id=merchant_id,
        private_key_pem=private_key,
        idempotency_key=f"antigravity_{order_id}",
    )
    response = requests.post(
        WAFFO_CREATE_SESSION_URL,
        headers=headers,
        data=raw_body,
        timeout=20,
    )
    try:
        data = response.json()
    except Exception as exc:
        raise HTTPException(status_code=502, detail="waffo_invalid_response") from exc
    if response.status_code >= 400:
        raise HTTPException(status_code=502, detail={"code": "waffo_checkout_failed", "waffo": data})
    session = data.get("data") or {}
    checkout_url = session.get("checkoutUrl")
    if not checkout_url:
        raise HTTPException(status_code=502, detail="waffo_checkout_url_missing")
    return session


@app.get("/api/payment/diagnostics")
def diagnostics() -> dict[str, Any]:
    manifest_path = Path(_env("INSTALLER_MANIFEST_PATH", "dist/site-download-manifest.json"))
    artifact_root = Path(_env("INSTALLER_ARTIFACT_ROOT", "dist"))
    return {
        "ok": True,
        "provider": "waffo_pancake",
        "product_id": _env("WAFFO_PRODUCT_ID", "PROD_47Yscc6M6VkB90yjfDREDW"),
        "currency": _env("WAFFO_CURRENCY", "USD"),
        "merchant_id_configured": bool(os.getenv("WAFFO_MERCHANT_ID")),
        "private_key_configured": bool(os.getenv("WAFFO_PRIVATE_KEY")),
        "webhook_public_key_configured": bool(os.getenv("WAFFO_WEBHOOK_PUBLIC_KEY")),
        "delivery_signing_secret_configured": bool(os.getenv("DELIVERY_SIGNING_SECRET")),
        "manifest_available": manifest_path.is_file(),
        "artifact_root_available": artifact_root.is_dir(),
        "webhook_url": f"{_public_base_url()}/api/payment/webhook/waffo",
        "public_base_url": _public_base_url(),
        "app_version": APP_VERSION,
    }


@app.post("/api/checkout/create", response_model=CheckoutResponse)
def create_checkout(payload: CheckoutRequest) -> CheckoutResponse:
    resolved = resolve_installer(_manifest(), payload.model_dump())
    if resolved.get("status") != "installer_available":
        raise HTTPException(status_code=409, detail=resolved)

    order_id = _new_order_id()
    now = _utcnow()
    with _connect() as conn:
        conn.execute(
            """
            INSERT INTO orders (
                order_id, created_at, updated_at, status, email,
                os, graphics, hardware_id, memory_gb, system_ram_gb, runtime,
                profile_id, installer_file, installer_sha256, installer_size_bytes
            ) VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                order_id,
                now,
                now,
                payload.email,
                payload.os,
                payload.graphics,
                payload.hardwareId,
                payload.memoryGb,
                payload.systemRamGb,
                payload.runtime,
                resolved["profileId"],
                resolved["installerFile"],
                resolved.get("sha256"),
                resolved.get("sizeBytes"),
            ),
        )

    try:
        session = _waffo_checkout(
            order_id,
            resolved["profileId"],
            resolved["installerFile"],
            payload.email,
        )
    except Exception:
        with _connect() as conn:
            conn.execute(
                "UPDATE orders SET status='checkout_failed', updated_at=? WHERE order_id=?",
                (_utcnow(), order_id),
            )
        raise

    with _connect() as conn:
        conn.execute(
            """
            UPDATE orders
            SET waffo_session_id=?, waffo_checkout_url=?, updated_at=?
            WHERE order_id=?
            """,
            (session.get("sessionId"), session.get("checkoutUrl"), _utcnow(), order_id),
        )

    return CheckoutResponse(
        orderId=order_id,
        checkoutUrl=session["checkoutUrl"],
        profileId=resolved["profileId"],
    )


@app.get("/api/orders/{order_id}")
def order_status(order_id: str) -> dict[str, Any]:
    with _connect() as conn:
        row = conn.execute("SELECT * FROM orders WHERE order_id=?", (order_id,)).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="order_not_found")

    result: dict[str, Any] = {
        "orderId": row["order_id"],
        "status": row["status"],
        "profileId": row["profile_id"],
        "platform": "macos" if row["installer_file"].endswith(".pkg") else "windows",
    }
    if row["status"] == "paid":
        ttl = int(_env("DOWNLOAD_TOKEN_TTL_SECONDS", "86400"))
        expiry = int(time.time()) + ttl
        secret = _env("DELIVERY_SIGNING_SECRET", required=True)
        token = make_download_token(secret, row["order_id"], row["profile_id"], expiry)
        result["downloadUrl"] = (
            f"{_public_base_url()}/api/download/{row['order_id']}?"
            + urlencode({"token": token})
        )
        result["downloadExpiresAt"] = expiry
    return result


@app.post("/api/payment/webhook/waffo")
async def waffo_webhook(request: Request) -> dict[str, Any]:
    raw_body = await request.body()
    signature_header = request.headers.get("X-Waffo-Signature", "")
    public_key = _env("WAFFO_WEBHOOK_PUBLIC_KEY", required=True)
    if not verify_waffo_webhook(raw_body, signature_header, public_key):
        raise HTTPException(status_code=401, detail="invalid_waffo_signature")

    try:
        event = json.loads(raw_body)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=400, detail="invalid_json") from exc

    event_id = str(event.get("eventId") or event.get("id") or "")
    event_type = str(event.get("eventType") or "")
    mode = str(event.get("mode") or "")
    data = event.get("data") or {}
    order_id = str(data.get("orderMerchantExternalId") or "")

    if not event_id:
        raise HTTPException(status_code=400, detail="missing_event_id")

    expected_mode = _env("WAFFO_MODE", "prod")
    if expected_mode and mode and mode != expected_mode:
        return {"ok": True, "ignored": "environment_mismatch"}

    with _connect() as conn:
        if conn.execute("SELECT 1 FROM webhook_events WHERE event_id=?", (event_id,)).fetchone():
            return {"ok": True, "duplicate": True}

        order = conn.execute("SELECT * FROM orders WHERE order_id=?", (order_id,)).fetchone() if order_id else None
        conn.execute(
            "INSERT INTO webhook_events (event_id,event_type,received_at,order_id) VALUES (?,?,?,?)",
            (event_id, event_type, _utcnow(), order_id or None),
        )

        if event_type != "order.completed":
            return {"ok": True, "ignored": "event_type"}
        if order is None:
            return {"ok": True, "ignored": "unknown_order"}
        if data.get("orderStatus") != "completed" or data.get("paymentStatus") != "succeeded":
            return {"ok": True, "ignored": "payment_not_succeeded"}

        expected_currency = _env("WAFFO_CURRENCY", "USD")
        if expected_currency and data.get("currency") != expected_currency:
            return {"ok": True, "ignored": "currency_mismatch"}

        expected_name = _env("WAFFO_PRODUCT_NAME", "Antigravity Local Setup Pack")
        if expected_name and data.get("productName") and data.get("productName") != expected_name:
            return {"ok": True, "ignored": "product_mismatch"}

        now = _utcnow()
        conn.execute(
            """
            UPDATE orders
            SET status='paid', updated_at=?, paid_at=?, email=COALESCE(?,email),
                waffo_order_id=?, waffo_payment_id=?
            WHERE order_id=?
            """,
            (
                now,
                now,
                data.get("buyerEmail"),
                data.get("orderId"),
                data.get("paymentId"),
                order_id,
            ),
        )

    return {"ok": True, "paid": True, "orderId": order_id}


@app.get("/api/download/{order_id}")
def download_installer(order_id: str, token: str) -> FileResponse:
    with _connect() as conn:
        row = conn.execute("SELECT * FROM orders WHERE order_id=?", (order_id,)).fetchone()
    if row is None or row["status"] != "paid":
        raise HTTPException(status_code=403, detail="paid_order_required")

    secret = _env("DELIVERY_SIGNING_SECRET", required=True)
    if not verify_download_token(secret, token, row["order_id"], row["profile_id"]):
        raise HTTPException(status_code=403, detail="invalid_or_expired_download_token")

    artifact_root = _env("INSTALLER_ARTIFACT_ROOT", "dist")
    try:
        path = safe_installer_path(artifact_root, row["installer_file"])
    except DeliveryError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    if not path.is_file():
        raise HTTPException(status_code=503, detail="installer_file_unavailable")

    return FileResponse(
        path,
        media_type="application/octet-stream",
        filename=path.name,
        headers={
            "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
        },
    )
