#!/usr/bin/env bash
# Signs the Azure CLI in again with a fresh GitHub OIDC token.
#
# A drill runs for about an hour. The token azure/login exchanged at the start
# is not renewed by the CLI, and kubectl reaches the cluster through the CLI
# (kubelogin's azurecli mode), so a pass that starts after the original token
# has gone stale fails on its first kubectl call -- or, worse, the teardown
# does. Terraform is unaffected: it requests its own OIDC tokens as it needs
# them. This runs before each phase so nothing depends on the first login.
set -euo pipefail

: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?not running in a job with id-token: write}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?not running in a job with id-token: write}"
: "${ARM_CLIENT_ID:?ARM_CLIENT_ID is not set}"
: "${ARM_TENANT_ID:?ARM_TENANT_ID is not set}"
: "${ARM_SUBSCRIPTION_ID:?ARM_SUBSCRIPTION_ID is not set}"

token=$(curl -sS --fail \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" \
  | jq -r '.value')

if [ -z "$token" ] || [ "$token" = "null" ]; then
  echo "GitHub returned no OIDC token, so the Azure CLI cannot be signed in." >&2
  exit 1
fi

az login --service-principal \
  --username "$ARM_CLIENT_ID" \
  --tenant "$ARM_TENANT_ID" \
  --federated-token "$token" \
  --output none
az account set --subscription "$ARM_SUBSCRIPTION_ID"

# Prove the login can mint what the next phase needs rather than assuming it.
# 6dae42f8-4368-4678-94ff-3960e28e3630 is the AKS Entra server application,
# the audience kubelogin asks for.
for resource in https://management.azure.com/ 6dae42f8-4368-4678-94ff-3960e28e3630; do
  if [ -z "$(az account get-access-token --resource "$resource" --query accessToken -o tsv)" ]; then
    echo "Signed in, but no token was issued for $resource." >&2
    exit 1
  fi
done

echo "Azure CLI signed in; tokens for ARM and the AKS API are available."
