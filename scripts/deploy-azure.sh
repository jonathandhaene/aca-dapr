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

echo "Building and pushing dispatcher image..."
docker build -t "$ACR_LOGIN_SERVER/dispatcher:latest" ./apps/level1-dispatcher
docker push "$ACR_LOGIN_SERVER/dispatcher:latest"

echo "Building and pushing level0-job image..."
docker build -t "$ACR_LOGIN_SERVER/level0-job:latest" ./apps/level0-job
docker push "$ACR_LOGIN_SERVER/level0-job:latest"

echo "Building and pushing level2-job image..."
docker build -t "$ACR_LOGIN_SERVER/level2-job:latest" ./apps/level2-job
docker push "$ACR_LOGIN_SERVER/level2-job:latest"

echo "Deploying infrastructure and apps..."
az deployment group create \
  -g "$RESOURCE_GROUP" \
  -f infra/main.bicep \
  -p "@$PARAMS_FILE" \
  -p dispatcherImage="$ACR_LOGIN_SERVER/dispatcher:latest" \
     level0Image="$ACR_LOGIN_SERVER/level0-job:latest" \
     level2Image="$ACR_LOGIN_SERVER/level2-job:latest" \
  --query properties.outputs -o json

echo "Deployment complete."

echo "Dispatcher URL:"
az containerapp show -g "$RESOURCE_GROUP" -n dispatcher --query properties.configuration.ingress.fqdn -o tsv

echo
echo "To run the pipeline, start the Level 0 producer jobs:"
echo "  az containerapp job start -g $RESOURCE_GROUP -n level0-job1   # orders feed"
echo "  az containerapp job start -g $RESOURCE_GROUP -n level0-job2   # signups feed"
