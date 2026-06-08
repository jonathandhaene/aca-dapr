# Deploy to Azure Container Apps (Short-Term Production Path)

This repo now includes deployable Azure infrastructure for:

- ACA environment and two container apps
- Dapr pub/sub component using Azure Service Bus
- Dapr state store using Azure Blob Storage
- ACR pull using managed identity + AcrPull role assignment

This repository supports only this enterprise Azure path. There is no local broker or local Dapr runtime deployment path.

## Prerequisites

- Azure CLI logged in (`az login`)
- Permissions to deploy into the target resource group
- Existing Azure Container Registry (ACR)
- Docker available locally

## 1) Set required values

Edit `infra/main.parameters.json`:

- `acrName`
- `storageAccountName` (must be globally unique)
- `serviceBusNamespaceName` (must be globally unique)
- `serviceBusDefaultMessageTimeToLive` (example `P14D`)
- `stateBlobRetentionDays` (example `30`)
- `checkoutImage`
- `inventoryImage`

## 2) Deploy in one command

```bash
./scripts/deploy-azure.sh -g rg-aca-dapr -l westeurope
```

This command will:

1. Build and push both images to ACR
2. Deploy `infra/main.bicep`
3. Print app URLs

## 3) Validate runtime behavior

Get checkout URL:

```bash
CHECKOUT_URL=$(az containerapp show -g rg-aca-dapr -n checkout-service --query properties.configuration.ingress.fqdn -o tsv)
```

Send a test order:

```bash
curl -X POST "https://${CHECKOUT_URL}/checkout" \
  -H "content-type: application/json" \
  -d '{"orderId":"ord-prod-1","sku":"SKU-RED-1","qty":2}'
```

Check state:

```bash
INVENTORY_URL=$(az containerapp show -g rg-aca-dapr -n inventory-service --query properties.configuration.ingress.fqdn -o tsv)
curl "https://${INVENTORY_URL}/state/ord-prod-1"
```

## 4) Triage during incident windows

Collect app and sidecar logs:

```bash
az containerapp logs show -g rg-aca-dapr -n checkout-service --tail 200
az containerapp logs show -g rg-aca-dapr -n inventory-service --tail 200
```

## Important short-term production notes

- This is designed for fast stabilization, not final hardening.
- Move Dapr component secrets to Key Vault references as a next step.
- Add private networking and tighter ingress when the incident is stabilized.

## Runtime expectations

- Service Bus pub/sub is at-least-once delivery; duplicate messages can occur.
- Message processing should be idempotent in consumers.
- During revision rollout, brief transient retries can happen.
- Blob-backed statestore is durable but may add small latency compared to in-memory/local stores.
- Messages are completed/expired by broker semantics; your app does not manually delete them.
- Expired messages can move to DLQ; monitor DLQ depth and alert on growth.
