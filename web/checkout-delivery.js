export async function createInstallerCheckout(config, options = {}) {
  const endpoint = options.endpoint || "/api/checkout/create";
  const payload = {
    os: config.os,
    graphics: config.graphics,
    hardwareId: config.hardwareId,
    runtime: config.runtime || "automatic",
    memoryGb: config.memoryGb == null ? null : Number(config.memoryGb),
    systemRamGb: config.systemRamGb == null ? null : Number(config.systemRamGb),
    email: options.email || null,
  };

  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const data = await readJson(response);

  if (!response.ok) {
    const detail = data && data.detail ? data.detail : data;
    const error = new Error("checkout_unavailable");
    error.status = response.status;
    error.detail = detail;
    throw error;
  }

  if (!data.checkoutUrl || !data.orderId) {
    throw new Error("checkout_response_invalid");
  }
  return data;
}

export async function getInstallerOrder(orderId, options = {}) {
  const base = options.endpointBase || "/api/orders";
  const response = await fetch(`${base}/${encodeURIComponent(orderId)}`, {
    method: "GET",
    headers: { Accept: "application/json" },
    cache: "no-store",
  });
  const data = await readJson(response);
  if (!response.ok) {
    const error = new Error("order_status_failed");
    error.status = response.status;
    error.detail = data && data.detail ? data.detail : data;
    throw error;
  }
  return data;
}

export function pollInstallerOrder(orderId, options = {}) {
  const intervalMs = options.intervalMs || 30000;
  const onUpdate = typeof options.onUpdate === "function" ? options.onUpdate : () => {};
  const signal = options.signal;

  return new Promise((resolve, reject) => {
    let timer = null;

    const stop = () => {
      if (timer) clearTimeout(timer);
      timer = null;
    };

    const run = async () => {
      if (signal && signal.aborted) {
        stop();
        reject(new DOMException("Polling aborted", "AbortError"));
        return;
      }
      try {
        const order = await getInstallerOrder(orderId, options);
        onUpdate(order);
        if (order.status === "paid" && order.downloadUrl) {
          stop();
          resolve(order);
          return;
        }
        if (["checkout_failed", "canceled", "refunded"].includes(order.status)) {
          stop();
          reject(Object.assign(new Error("order_terminal_state"), { order }));
          return;
        }
      } catch (error) {
        if (options.stopOnError) {
          stop();
          reject(error);
          return;
        }
        onUpdate({ status: "poll_error", error });
      }
      timer = setTimeout(run, intervalMs);
    };

    run();
  });
}

export async function beginPaidInstallerFlow(config, options = {}) {
  const checkout = await createInstallerCheckout(config, options);
  if (typeof options.onCheckoutCreated === "function") {
    options.onCheckoutCreated(checkout);
  }

  if (options.navigate !== false) {
    window.location.assign(checkout.checkoutUrl);
  }
  return checkout;
}

async function readJson(response) {
  const text = await response.text();
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    return { raw: text };
  }
}
