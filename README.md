# the-upgrade-succeeded

An AKS node pool upgrade that Azure reports as **Succeeded** — and Terraform
reports as **Apply complete** — while the application behind it was failing
requests. Then the same upgrade again, on the same cluster, with the same
application, where nothing fails. The only difference between the two passes
is the workload's Kubernetes manifest.

> **Status: built, not yet run against Azure.** The results section below is
> filled in from live runs, not predicted.

## The problem

A node pool upgrade replaces every node in the pool. AKS adds a surge node,
cordons and drains an old one, upgrades it, and moves on to the next. Azure
reports the operation by whether the *nodes* ended up at the new version. It
has no idea whether the application on them stayed up, and it is not asked.

So an upgrade can be green in the portal, green in the pipeline, and an outage
for users. Whether it is depends on things only the workload's manifest
declares: whether Kubernetes knows when a pod is actually ready, and whether a
drain is allowed to take the last replica that is serving.

## How it measures

- **Terraform** builds a cluster on the free control plane: Entra ID sign-in
  with Azure RBAC, no local admin account, the API server reachable from the
  runner's address only, and a system pool that runs nothing but AKS itself.
- For each pass, Terraform adds a two-node app pool at the **older** version,
  the workload is deployed onto it, and a **probe** on the runner starts
  requesting the app through Azure's public load balancer five times a second,
  each request on a new connection.
- The upgrade is a Terraform apply that changes the pool's
  `orchestrator_version` — the way a team managing AKS with Terraform would do
  it. Its exit code and the pool's `provisioningState` afterwards are recorded
  as what was *reported*.
- The cluster is then read again to prove the upgrade really happened: every
  node must have moved from the old version to the new one, and every pod that
  existed before must be gone. A pass where that cannot be shown is graded
  **Unknown**, never passed — zero failed requests during an upgrade that
  drained nothing would prove nothing.

Both passes use identical pool settings (size, node count, `max_surge = 1`,
drain timeout) and an identical application: the same image, which takes
twenty seconds to start answering after its container starts, as anything
that loads configuration or warms a cache does.

| | unprotected | protected |
|---|---|---|
| Replicas | 2 | 2 |
| Readiness probe | none | `GET /` every 2s |
| PodDisruptionBudget | none | `minAvailable: 1` |
| Spread across nodes | scheduler's choice | `topologySpreadConstraints` on hostname |
| preStop | none | `sleep 10` |

## Predicted before it runs

`Test-DrainReadiness` reads the manifests and predicts which will hurt traffic
during a drain. CI fails if its prediction differs from what
[`expectations.json`](expectations.json) declares, so removing a protection
from the protected manifest fails the build before anything is deployed.

| Rule | Severity | Why it matters during a drain |
|---|---|---|
| `SingleReplica` | Error | Draining its node is an outage. |
| `NoReadinessProbe` | Error | A replacement pod is sent traffic when its container starts, not when the app answers. |
| `NoDisruptionBudget` | Error | Nothing stops a drain evicting the last ready replica while its replacement is still starting. |
| `DrainBlocked` | Error | A budget no eviction can satisfy (`minAvailable` equal to replicas, `maxUnavailable: 0`). The drain waits out its timeout and the upgrade fails — the opposite mistake. |
| `NoGracefulStop` | Warning | No `preStop`: the pod stops while load balancers may still route to it. |
| `NoHostSpread` | Warning | Nothing keeps replicas off the same node. |

## Running it

One-time setup, as an Owner of the subscription:

1. Register `Microsoft.ContainerService`, and create the resource group
   `rg-aksupgrade-lab`.
2. Create an app registration with a federated credential for this
   repository's `lab` environment, and give its service principal:
   - **Contributor** and **Azure Kubernetes Service RBAC Cluster Admin** on
     `rg-aksupgrade-lab` only — it can build and use a cluster there and
     nowhere else;
   - **Reader** on the subscription, so the teardown check can see that the
     node resource group AKS creates outside the lab group is really gone.
3. Set `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` on the
   `lab` environment. Nothing else; there are no stored credentials.

Then run **Drill** from the Actions tab. It picks the versions from what the
region offers, runs both passes, grades them, uploads every sample as an
artifact, and tears down whether or not anything failed. **Destroy** runs
nightly and deletes any cluster a cancelled run left behind.

## Cost

About **$0.30–$0.38 an hour** while it runs, at East US 2 pay-as-you-go
prices: the AKS control plane is free on the Free tier; three or four
`Standard_D2als_v7` nodes at $0.0804/hour; 32 GB managed OS disks; the
Standard load balancer and two public IPs. A drill takes about an hour.
Nothing is left running afterwards; the resource group is empty and free.
