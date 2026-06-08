#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 -g <resource-group> -l <location> [-p <params-file>]

Example:
  $0 -g rg-aca-dapr -l westeurope -p infra/main.parameters.json
EOF
}

RESOURCE_GROUP=""
LOCATION=""
PARAMS_FILE="infra/main.parameters.json"

while getopts ":g:l:p:h" opt; do
  case "$opt" in
    g) RESOURCE_GROUP="$OPTARG" ;;
    l) LOCATION="$OPTARG" ;;
    p) PARAMS_FILE="$OPTARG" ;;
    h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$RESOURCE_GROUP" || -z "$LOCATION" ]]; then
  usage
  exit 1
fi

if [[ ! -f "$PARAMS_FILE" ]]; then
  echo "Parameters file not found: $PARAMS_FILE"
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI (az) is required."
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required."
  exit 1
fi

ACR_NAME=$(grep -E '"acrName"' -A 3 "$PARAMS_FILE" | grep -Eo '"value"\s*:\s*"[^"]+"' | sed -E 's/.*"([^"]+)"/\1/' | head -n1)

if [[ -z "$ACR_NAME" || "$ACR_NAME" == "<your-acr-name>" ]]; then
  echo "Set a valid acrName in $PARAMS_FILE before deploying."
  exit 1
fi

ACR_LOGIN_SERVER=$(az acr show -n "$ACR_NAME" --query loginServer -o tsv)

echo "Using ACR: $ACR_LOGIN_SERVER"

az group create -n "$RESOURCE_GROUP" -l "$LOCATION" >/dev/null
az acr login -n "$ACR_NAME"

echo "Building and pushing checkout-service image..."
docker build -t "$ACR_LOGIN_SERVER/checkout-service:latest" ./apps/checkout-service
docker push "$ACR_LOGIN_SERVER/checkout-service:latest"

echo "Building and pushing inventory-service image..."
docker build -t "$ACR_LOGIN_SERVER/inventory-service:latest" ./apps/inventory-service
docker push "$ACR_LOGIN_SERVER/inventory-service:latest"

echo "Deploying infrastructure and apps..."
az deployment group create \
  -g "$RESOURCE_GROUP" \
  -f infra/main.bicep \
  -p "@$PARAMS_FILE" \
  -p checkoutImage="$ACR_LOGIN_SERVER/checkout-service:latest" \
     inventoryImage="$ACR_LOGIN_SERVER/inventory-service:latest" \
  --query properties.outputs -o json

echo "Deployment complete."

echo "Checkout URL:"
az containerapp show -g "$RESOURCE_GROUP" -n checkout-service --query properties.configuration.ingress.fqdn -o tsv

echo "Inventory URL:"
az containerapp show -g "$RESOURCE_GROUP" -n inventory-service --query properties.configuration.ingress.fqdn -o tsv
