import express from "express";

const app = express();
app.use(express.json());

const PORT = process.env.APP_PORT || 3001;
const DAPR_HTTP_PORT = process.env.DAPR_HTTP_PORT || 3501;

app.get("/healthz", (_req, res) => {
  res.status(200).json({ status: "ok", service: "inventory-service" });
});

app.get("/dapr/subscribe", (_req, res) => {
  res.json([
    {
      pubsubname: "pubsub",
      topic: "orders",
      route: "events/orders"
    }
  ]);
});

app.post("/events/orders", async (req, res) => {
  const order = req.body;
  const key = order?.orderId;

  if (!key) {
    return res.status(400).json({ message: "orderId is required" });
  }

  try {
    const saveUrl = `http://localhost:${DAPR_HTTP_PORT}/v1.0/state/statestore`;
    const payload = [
      {
        key,
        value: {
          status: "reserved",
          sku: order.sku,
          qty: order.qty,
          sourceEvent: order,
          updatedAtUtc: new Date().toISOString()
        }
      }
    ];

    const saveResp = await fetch(saveUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload)
    });

    if (!saveResp.ok) {
      const text = await saveResp.text();
      console.error("State save failed", saveResp.status, text);
      return res.status(500).json({ message: "state save failed" });
    }

    return res.status(200).json({ status: "SUCCESS" });
  } catch (err) {
    console.error("Order processing failed", err);
    return res.status(500).json({ message: "processing failed" });
  }
});

app.get("/state/:orderId", async (req, res) => {
  const key = req.params.orderId;
  try {
    const readUrl = `http://localhost:${DAPR_HTTP_PORT}/v1.0/state/statestore/${key}`;
    const stateResp = await fetch(readUrl);
    if (!stateResp.ok) {
      const text = await stateResp.text();
      return res.status(404).json({ message: "state not found", details: text });
    }

    const data = await stateResp.json();
    return res.status(200).json(data);
  } catch (err) {
    return res.status(500).json({ message: "state read failed", error: String(err) });
  }
});

app.listen(PORT, () => {
  console.log(`inventory-service listening on ${PORT}`);
});
