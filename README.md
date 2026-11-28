# the-upgrade-succeeded

An AKS node pool upgrade that Azure reports as **Succeeded** — and Terraform
reports as **Apply complete** — while the application behind it was failing
requests. Then the same upgrade again, on the same cluster, with the same
application, where nothing fails. The only difference between the two passes
is the workload's Kubernetes manifest.

## The result

One live run, 25 November 2026, a patch upgrade from Kubernetes 1.36.4 to
1.36.5 in East US 2. Both passes were graded against
[`expectations.json`](expectations.json), which was written before the run.

| | unprotected | protected |
|---|---|---|
| Terraform | `Apply complete`, exit 0, 606 s | `Apply complete`, exit 0, 646 s |
| Azure, node pool `provisioningState` | **Succeeded** at 1.36.5 | **Succeeded** at 1.36.5 |
| Proof the upgrade ran | both nodes 1.36.4 → 1.36.5, both pods replaced | both nodes 1.36.4 → 1.36.5, both pods replaced |
| Requests before the upgrade | 149, none failed | 149, none failed |
| Requests during the upgrade | **181 of 3,180 failed** | **0 of 3,517 failed** |
| Failure windows | two, **30.6 s** and **29.3 s** from first to last failure | none |
| Longest unbroken run of failures | **29.5 s** | 0 |

The two windows in the unprotected pass were one per node drained, 176 and 535
seconds into the upgrade; almost every request inside them failed. 167 of the failed requests were refused connections
and 14 timed out. Nothing in Terraform's output, the pool's state or the
upgrade's exit code distinguishes the two passes.

## What the run showed that the prediction did not

**Both unprotected replicas were on the same node, twice.** The scheduler put
both pods on `vmss000000`. When AKS drained it, both were killed in the same
second (14:12:50), and their replacements were again scheduled together — so
the second node's drain (14:18:47) killed both again. "Two replicas" gave no
redundancy at all against a drain. With no readiness probe, each pair of
replacements was then sent traffic for the twenty seconds before the app
answered, which is where the refused connections come from.

`Test-DrainReadiness` grades a missing spread constraint as a **warning**, not
an error, and this run is the case for that being too lenient: it is what made
each drain a full outage rather than half the requests failing. It stays a
warning for now because a disruption budget alone would also have prevented
it — the drain would not have been allowed to evict both — and one run is not
enough to promote a rule.

**The protected pass's pods were reported Unhealthy, on purpose.** Every new
pod logged readiness-probe failures for about twenty seconds after it started.
Those are the same twenty seconds in which the unprotected pass was sending
users to pods that refused the connection; with a probe, Kubernetes simply
did not route to them yet. The protected upgrade took 40 seconds longer,
because each drain waited for a replacement to become ready before evicting
the next pod.

**The Azure load balancer caused no failures in this run.** Nodes leaving the
backend pool during the drain were a possible source of errors that no
manifest setting could fix (`externalTrafficPolicy` is `Cluster` in both
passes). None appeared in 3,517 requests. One run is not proof it cannot happen.

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
Standard load balancer and two public IPs. The run above took 45 minutes from
the first Terraform apply to a verified teardown, so roughly **$0.21**,
calculated from those rates and the run's own timestamps. Azure's bill for
it, read from Cost Management afterwards, was **$0.19**. Nothing is left
running afterwards; the resource group is empty and free.

## How it got here

Two drills. The first stopped before creating anything: the tenant ID secret
had been set by piping it through Windows PowerShell, which stored a trailing
newline. The Azure CLI sign-in ignored it; Terraform's provider rejected the
value as an invalid tenant. The second is the run reported above, and passed
both checks on its first attempt — because the grading had already been
through fifty unit tests in CI, including every way a pass can be **Unknown**.

## What this does not show

- **One run, one patch upgrade.** A minor-version upgrade drains nodes the
  same way, but it was not measured here.
- **Short requests only.** The probe makes a fresh connection five times a
  second. Long-lived connections and requests in flight during a drain are
  what `preStop` exists for, and this probe would not see one being cut.
- **No autoscaling, one workload.** A busy pool where replacements wait for
  capacity, or a budget shared by many deployments, behaves differently.
- **Zero failures in 3,517 requests is a measurement, not a guarantee.** It
  says the protections worked here, at this rate, on this run.
