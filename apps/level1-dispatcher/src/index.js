import express from "express";

// ============================================================================
// LEVEL 1 — THE DISPATCHER (always-on Container App, Dapr enabled)
// ============================================================================
//
// This is the only tier that can use Dapr (Container App JOBS cannot run a Dapr
// sidecar). Its job is to look at each incoming task and use Dapr pub/sub to
// decide:
//
//   * HOW  -> WHICH Level 2 job should handle it. We do this by publishing to a
//             DIFFERENT Service Bus topic per Level 2 job. Each topic has its
//             own KEDA-scaled worker job, so "pick the topic" == "pick the job".
//
//   * WHEN -> WHEN the chosen job should be triggered. Dapr forwards a
//             `metadata.ScheduledEnqueueTimeUtc` value to Service Bus, which
//             holds the message until that time. KEDA only sees the message
//             (and starts the worker) once it becomes active. No CRON needed.
//
// Level 0 producers send tasks here over plain HTTP; this app does the Dapr
// publish on their behalf.
// ============================================================================

const app = express();
app.use(express.json());

const PORT = process.env.APP_PORT || 3000;
const DAPR_HTTP_PORT = process.env.DAPR_HTTP_PORT || 3500;
const PUBSUB_NAME = process.env.PUBSUB_NAME || "pubsub";

// One topic per Level 2 worker job. The infra wires each topic to its own
// KEDA-scaled job, so choosing a topic here chooses which job runs.
const TOPIC_JOB1 = process.env.TOPIC_JOB1 || "tasks-job1"; // priority orders
const TOPIC_JOB2 = process.env.TOPIC_JOB2 || "tasks-job2"; // standard orders
const TOPIC_JOB3 = process.env.TOPIC_JOB3 || "tasks-job3"; // signups / welcome

// Routing "knobs". These let you change HOW and WHEN work is dispatched without
// touching code — just change the env values in the infra.
const HIGH_VALUE_THRESHOLD = Number(process.env.HIGH_VALUE_THRESHOLD || 100);
const SIGNUP_DELAY_SECONDS = Number(process.env.SIGNUP_DELAY_SECONDS || 30);

// route() is the heart of the demo: it turns a task into a routing decision
// (which topic = which Level 2 job, and how long to delay it).
function route(task) {
  if (task.kind === "order") {
    const amount = Number(task.amount || 0);
    if (amount >= HIGH_VALUE_THRESHOLD) {
      // Big orders jump the queue: priority fulfillment, run immediately.
      return {
        topic: TOPIC_JOB1,
        delaySeconds: 0,
        reason: `order amount ${amount} >= ${HIGH_VALUE_THRESHOLD} -> priority fulfillment (job1)`
      };
    }
    // Smaller orders go to standard fulfillment, also immediately.
    return {
      topic: TOPIC_JOB2,
      delaySeconds: 0,
      reason: `order amount ${amount} < ${HIGH_VALUE_THRESHOLD} -> standard fulfillment (job2)`
    };
  }

  if (task.kind === "signup") {
    // Welcome emails are not urgent. We DELAY them with Dapr so they are
    // batched into a window instead of firing instantly. This shows "WHEN".
    return {
      topic: TOPIC_JOB3,
      delaySeconds: SIGNUP_DELAY_SECONDS,
      reason: `signup -> welcome email (job3), delayed ${SIGNUP_DELAY_SECONDS}s`
    };
  }

  // Anything we don't recognize falls back to standard fulfillment.
  return {
    topic: TOPIC_JOB2,
    delaySeconds: 0,
    reason: `unknown kind "${task.kind}" -> standard fulfillment (job2)`
  };
}

app.get("/healthz", (_req, res) => {
  res.status(200).json({ status: "ok", service: "dispatcher" });
});

app.post("/dispatch", async (req, res) => {
  const task = req.body;

  if (!task || !task.payload) {
    return res.status(400).json({ message: "payload is required" });
  }

  // 1) Decide HOW + WHEN.
  const decision = route(task);

  // 2) Build the Dapr publish URL for the chosen topic. Dapr forwards any
  //    `metadata.*` query parameters to the broker. For Azure Service Bus,
  //    `ScheduledEnqueueTimeUtc` (RFC1123 / toUTCString format) tells the
  //    broker to hold the message until that moment -> this is the "WHEN".
  let publishUrl = `http://localhost:${DAPR_HTTP_PORT}/v1.0/publish/${PUBSUB_NAME}/${decision.topic}`;
  if (decision.delaySeconds > 0) {
    const when = new Date(Date.now() + decision.delaySeconds * 1000).toUTCString();
    publishUrl += `?metadata.ScheduledEnqueueTimeUtc=${encodeURIComponent(when)}`;
  }

  try {
    const resp = await fetch(publishUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(task)
    });

    if (!resp.ok) {
      const text = await resp.text();
      return res.status(502).json({
        message: "Failed to publish task via Dapr",
        daprStatus: resp.status,
        daprBody: text
      });
    }

    console.log(`Routed task ${task.taskId} -> ${decision.topic} (${decision.reason})`);
    return res.status(202).json({
      message: "task published",
      taskId: task.taskId,
      routedTo: decision.topic,
      delaySeconds: decision.delaySeconds,
      reason: decision.reason
    });
  } catch (err) {
    return res.status(500).json({ message: "dispatch failed", error: String(err) });
  }
});

app.listen(PORT, () => {
  console.log(`dispatcher listening on ${PORT}`);
});
