import { ServiceBusClient } from "@azure/service-bus";

// ============================================================================
// LEVEL 2 — A WORKER JOB (event-driven Container App Job, no Dapr)
// ============================================================================
//
// This SAME image runs as three different jobs in the demo, one per topic:
//   * level2-job1  -> TASKS_TOPIC=tasks-job1, WORKER_NAME=job1-priority
//   * level2-job2  -> TASKS_TOPIC=tasks-job2, WORKER_NAME=job2-standard
//   * level2-job3  -> TASKS_TOPIC=tasks-job3, WORKER_NAME=job3-welcome
//
// KEDA watches each job's own Service Bus subscription and starts one execution
// per pending message (no CRON). The dispatcher already decided WHICH topic
// (and therefore which of these jobs) handles each task, and WHEN it becomes
// visible. A Container App Job cannot run a Dapr sidecar, so this tier reads
// and completes its message directly with the Service Bus SDK.
// ============================================================================

const CONNECTION = process.env.SERVICEBUS_CONNECTION;
const TOPIC = process.env.TASKS_TOPIC || "tasks-job1";
const SUBSCRIPTION = process.env.TASKS_SUBSCRIPTION || "workers";
const WORKER_NAME = process.env.WORKER_NAME || "level2";
const MAX_IDLE_MS = Number(process.env.MAX_IDLE_MS || 5000);

async function processTask(task) {
  // Replace this with the real per-item work for THIS worker. The WORKER_NAME
  // makes it obvious in the logs which of the three jobs handled the task.
  console.log(`[${WORKER_NAME}] processing task ${task?.taskId}: ${task?.payload}`);
}

async function main() {
  if (!CONNECTION) {
    console.error("SERVICEBUS_CONNECTION is required");
    process.exit(1);
  }

  const client = new ServiceBusClient(CONNECTION);
  const receiver = client.createReceiver(TOPIC, SUBSCRIPTION);
  let processed = 0;

  try {
    // Drain the messages that triggered this execution. The loop ends once the
    // subscription is empty, then the job execution exits.
    while (true) {
      const messages = await receiver.receiveMessages(1, { maxWaitTimeInMs: MAX_IDLE_MS });
      if (messages.length === 0) {
        break;
      }

      for (const msg of messages) {
        try {
          await processTask(msg.body);
          await receiver.completeMessage(msg);
          processed++;
        } catch (err) {
          console.error(`[${WORKER_NAME}] processing failed; abandoning message for retry`, err);
          await receiver.abandonMessage(msg);
        }
      }
    }
  } finally {
    await receiver.close();
    await client.close();
  }

  console.log(`[${WORKER_NAME}] done. Processed ${processed} tasks from ${TOPIC}.`);
  process.exit(0);
}

main().catch((err) => {
  console.error(`[${WORKER_NAME}] job failed`, err);
  process.exit(1);
});
