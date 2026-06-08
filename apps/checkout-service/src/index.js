import express from "express";

const app = express();
app.use(express.json());

const PORT = process.env.APP_PORT || 3000;
const DAPR_HTTP_PORT = process.env.DAPR_HTTP_PORT || 3500;

app.get("/healthz", (_req, res) => {
  res.status(200).json({ status: "ok", service: "checkout-service" });
});

app.post("/checkout", async (req, res) => {
  const order = {
    orderId: req.body?.orderId || `ord-${Date.now()}`,
    sku: req.body?.sku || "SKU-DEFAULT",
    qty: Number(req.body?.qty || 1),
    createdAtUtc: new Date().toISOString()
  };

  try {
    const publishUrl = `http://localhost:${DAPR_HTTP_PORT}/v1.0/publish/pubsub/orders`;
    const response = await fetch(publishUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(order)
    });

    if (!response.ok) {
      const text = await response.text();
      return res.status(502).json({
        message: "Failed to publish order event via Dapr",
        daprStatus: response.status,
        daprBody: text
      });
    }

    return res.status(202).json({
      message: "Order accepted and event published",
      order
    });
  } catch (err) {
    return res.status(500).json({
      message: "Checkout failed while publishing event",
      error: String(err)
    });
  }
});

app.listen(PORT, () => {
  console.log(`checkout-service listening on ${PORT}`);
});
