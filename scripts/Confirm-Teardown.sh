#!/usr/bin/env bash
# Fails unless Azure itself shows nothing left from this lab.
#
# Checks the service, not Terraform's state: the nightly Destroy has no state
# at all, and a drill whose state was lost would destroy nothing and exit 0.
# Every query must succeed before its empty answer is believed -- an
# authorisation error that printed nothing would otherwise read as "clean".
set -euo pipefail

: "${TF_VAR_resource_group_name:?TF_VAR_resource_group_name is not set}"
nodes_rg="${NODES_RESOURCE_GROUP:-rg-aksupgrade-nodes}"

for i in $(seq 1 40); do
  clusters=$(az aks list --resource-group "$TF_VAR_resource_group_name" --query "length(@)" -o tsv)
  # az group exists prints false for a group it cannot see as well as one that
  # is gone, so read the subscription's group list instead and insist the
  # call itself worked. The drill identity has Reader on the subscription
  # for exactly this.
  groups=$(az group list --query "[?name=='${nodes_rg}'] | length(@)" -o tsv)
  if [ -z "$clusters" ] || [ -z "$groups" ]; then
    echo "A teardown query returned nothing at all; refusing to call that clean." >&2
    exit 1
  fi
  if [ "$clusters" = "0" ] && [ "$groups" = "0" ]; then
    echo "Confirmed on check $i: no cluster in $TF_VAR_resource_group_name and no $nodes_rg."
    exit 0
  fi
  echo "  clusters=$clusters, node resource group present=$groups (check $i)"
  sleep 30
done

echo "Something from this lab is still in Azure after twenty minutes." >&2
az aks list --resource-group "$TF_VAR_resource_group_name" --query "[].name" -o tsv >&2 || true
exit 1
