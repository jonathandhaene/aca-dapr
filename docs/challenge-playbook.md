# Dapr on ACA Challenge Playbook

Use this playbook when Dapr-based workloads behave differently on Azure Container Apps than local runs.

Broker model for this repository: Azure Service Bus only.

## Typical Symptoms

- Requests fail right after revision deploy, then recover later
- Pub/sub delivery is inconsistent during rollout
- State reads/writes fail intermittently
- Duplicate event handling appears during scale-out

## Fast Triage Checklist

1. Confirm app revision is healthy and receiving traffic.
2. Check app logs and Dapr sidecar logs together.
3. Validate component metadata (host, secrets, scopes).
4. Verify retries and idempotency behavior for pub/sub handlers.
5. Confirm readiness checks block traffic until dependencies are live.

## Short-Term Production Stabilization

Use this order during an active incident:

1. Pin both apps to `activeRevisionsMode: Single` and keep `minReplicas >= 1`.
2. Ensure Dapr pub/sub uses Azure Service Bus and not local-only components.
3. Ensure statestore uses cloud storage and not local Redis assumptions.
4. Verify Dapr components are scoped only to participating apps.
5. Confirm app health endpoints (`/healthz`) are used by ACA probes.
6. Validate event handlers are idempotent for duplicate delivery safety.
7. Capture app + sidecar logs for every mitigation rollout.

This repository's `infra/main.bicep` applies these controls for quick stabilization.

## Known Workarounds

### 1) Startup race between app and sidecar/dependencies

- Add app-level startup checks and fail fast if Dapr API is unavailable.
- Keep health endpoints simple and dependency-aware.
- Use readiness probes that reflect ability to process real work.

### 2) Revision rollout causes transient duplicate processing

- Make handlers idempotent using deterministic keys.
- Store processed event IDs in state (or external cache) before side effects.
- Use safe retry semantics and dead-letter strategy where applicable.

### 3) Component drift between environments

- Keep components versioned in source control.
- Use explicit `scopes` to reduce accidental cross-service usage.
- Keep only production-targeted component definitions in deployment templates.

### 4) Secret and connectivity issues in ACA

- Move secret values to ACA secrets / Key Vault references.
- Avoid localhost assumptions in cloud components.
- Test connectivity from the running container, not from local machine.

## Operational Guardrails

- Add correlation IDs to all inbound requests and outgoing events.
- Emit event processing metrics: accepted, retried, failed, duplicate.
- Track sidecar restart count and component init errors.
- Include canary smoke checks in deployment pipeline.

## Repro Pattern in This Repo

- `checkout-service` publishes `orders` topic messages.
- `inventory-service` subscribes and writes reservation state.
- Validate by posting an order, then reading persisted state from the API.

## Extend This Playbook

Add a section per incident with:

- Date and environment
- Symptom and impact
- Root cause
- Fix/workaround
- Preventive action
