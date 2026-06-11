import fs from "node:fs";
import readline from "node:readline";

// ============================================================================
// LEVEL 0 — A PRODUCER JOB (Container App Job, no Dapr)
// ============================================================================
//
// This SAME image runs as two different jobs in the demo:
//   * level0-job1  -> TASK_KIND=order,  reads data/orders.txt
//   * level0-job2  -> TASK_KIND=signup, reads data/signups.txt
//
// A Container App Job has no Dapr sidecar, so this tier does NOT publish to
// Service Bus directly. It reads its file line by line, turns each line into a
// structured task, and HTTP POSTs it to the Level 1 dispatcher, which performs
// the Dapr publish. The dispatcher decides which Level 2 job handles it.
// ============================================================================

const DISPATCHER_URL = process.env.DISPATCHER_URL;
const INPUT_FILE = process.env.INPUT_FILE || "/app/data/orders.txt";
const TASK_KIND = process.env.TASK_KIND || "order";

// Turn one raw line into a structured task. The `kind` field is what the
// dispatcher routes on, so we always set it. Orders also carry an `amount`
// (used by the dispatcher's high-value routing rule).
function buildTask(line, index) {
  const base = {
    taskId: `${TASK_KIND}-${Date.now()}-${index}`,
    kind: TASK_KIND,
    payload: line,
    createdAtUtc: new Date().toISOString()
  };

  if (TASK_KIND === "order") {
    // orders.txt line format: SKU|QTY|AMOUNT  (e.g. "SKU-1003|1|999.00")
    const [sku, qty, amount] = line.split("|");
    return { ...base, sku, qty: Number(qty), amount: Number(amount) };
  }

  if (TASK_KIND === "signup") {
    // signups.txt line format: EMAIL|TIER  (e.g. "alice@example.com|premium")
    const [email, tier] = line.split("|");
    return { ...base, email, tier };
  }

  return base;
}

async function main() {
  if (!DISPATCHER_URL) {
    console.error("DISPATCHER_URL is required");
    process.exit(1);
  }

  if (!fs.existsSync(INPUT_FILE)) {
    console.error(`Input file not found: ${INPUT_FILE}`);
    process.exit(1);
  }

  const rl = readline.createInterface({
    input: fs.createReadStream(INPUT_FILE),
    crlfDelay: Infinity
  });

  let count = 0;
  for await (const raw of rl) {
    const line = raw.trim();
    if (!line) {
      continue;
    }

    const task = buildTask(line, count);

    const resp = await fetch(DISPATCHER_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(task)
    });

    if (!resp.ok) {
      const text = await resp.text();
      console.error(`Dispatch failed for line ${count}`, resp.status, text);
      process.exit(1);
    }

    count++;
    console.log(`Dispatched ${TASK_KIND} task ${count}: ${line}`);
  }

  console.log(`Level 0 (${TASK_KIND}) done. Dispatched ${count} tasks.`);
  process.exit(0);
}

main().catch((err) => {
  console.error("Level 0 job failed", err);
  process.exit(1);
});
