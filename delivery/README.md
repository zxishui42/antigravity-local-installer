# Paid installer delivery

This service turns the released installer catalog into a paid download flow.

## Customer flow

1. The website submits the selected hardware configuration to `POST /api/checkout/create`.
2. The backend resolves it against `dist/site-download-manifest.json`.
3. Only `installer_available` configurations can create checkout.
4. A local order is created and permanently locked to one `profile_id` and installer file.
5. The backend creates a Waffo Pancake checkout session using the server-side API key and writes the local order ID into `orderMerchantExternalId`.
6. Waffo sends a signed `order.completed` event to `POST /api/payment/webhook/waffo`.
7. Only a valid, signed, successful payment marks the local order as `paid`.
8. The browser polls `GET /api/orders/{order_id}` every 30 seconds.
9. A paid order receives a short-lived download URL that is cryptographically bound to that order and profile.
10. `GET /api/download/{order_id}?token=...` serves only the installer locked to the paid order.

The browser redirect from Waffo is never used as proof of payment.

## Production files

The delivery host needs the release output from the cross-platform release workflow:

```
dist/site-download-manifest.json
dist/profiles/*.exe
dist/profiles/*.pkg
```

Keep `dist/profiles` private. Do not expose it as a public static directory.

## Required environment variables

Secrets:

```
WAFFO_MERCHANT_ID=...
WAFFO_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
WAFFO_WEBHOOK_PUBLIC_KEY="-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----"
DELIVERY_SIGNING_SECRET=<high-entropy-random-secret>
```

Public/non-secret configuration:

```
WAFFO_PRODUCT_ID=PROD_47Yscc6M6VkB90yjfDREDW
WAFFO_PRODUCT_NAME=Antigravity Local Setup Pack
WAFFO_CURRENCY=USD
WAFFO_MODE=prod
PUBLIC_BASE_URL=https://antigravitylocalmodels.com
INSTALLER_MANIFEST_PATH=dist/site-download-manifest.json
INSTALLER_ARTIFACT_ROOT=dist
ORDER_DB_PATH=delivery/data/orders.sqlite3
WAFFO_CHECKOUT_TTL_SECONDS=3600
DOWNLOAD_TOKEN_TTL_SECONDS=86400
```

## Run

```bash
python -m pip install -r delivery/requirements.txt
python -m uvicorn delivery.app:app --host 127.0.0.1 --port 8000
```

For production, put the service behind HTTPS and persist both the SQLite database and installer artifact directory.

## Waffo webhook

Configure the production HTTP webhook to:

```
https://antigravitylocalmodels.com/api/payment/webhook/waffo
```

Subscribe to at least:

```
order.completed
```

The service verifies `X-Waffo-Signature` using RSA-SHA256 before changing payment state and deduplicates webhook events by event ID.

## Browser integration

Use `web/checkout-delivery.js`.

The website should:

- keep the payment button disabled until hardware selection is complete;
- call `createInstallerCheckout`;
- show "temporarily unsupported" when the API returns 409;
- redirect only with the returned `checkoutUrl`;
- on `/install/complete?order=...`, call `pollInstallerOrder`;
- show the download button only when the returned status is `paid`.

Do not use the public static Waffo product URL as the authoritative order-binding flow. It can collect a payment, but it does not by itself prove which local installer order the payment belongs to.

## Security rules

- Never expose the Waffo private key or delivery signing secret to browser JavaScript.
- Never unlock an installer from a browser success redirect.
- Never accept a profile ID or installer filename supplied by the customer after checkout creation.
- Never serve an installer for a route that is not `installer_available`.
- Never serve `dist/profiles` as a public directory.
- Always keep the released manifest and installer files from the same release build.
