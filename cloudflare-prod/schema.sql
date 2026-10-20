CREATE TABLE IF NOT EXISTS orders (
 order_id TEXT PRIMARY KEY, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, status TEXT NOT NULL, email TEXT,
 os TEXT NOT NULL, graphics TEXT NOT NULL, hardware_id TEXT NOT NULL, memory_gb REAL, system_ram_gb REAL, runtime TEXT NOT NULL,
 profile_id TEXT NOT NULL, installer_sha256 TEXT NOT NULL, price_usd TEXT NOT NULL, currency TEXT NOT NULL,
 waffo_session_id TEXT, waffo_checkout_url TEXT, waffo_order_id TEXT, waffo_payment_id TEXT, paid_at TEXT, refunded_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
CREATE TABLE IF NOT EXISTS webhook_events (event_type TEXT NOT NULL,event_id TEXT NOT NULL,received_at TEXT NOT NULL,PRIMARY KEY(event_type,event_id));
