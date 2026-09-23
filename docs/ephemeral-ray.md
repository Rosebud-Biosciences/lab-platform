# Ephemeral Ray clusters

A pattern for running distributed Ray work **without an always-on Ray
cluster**. An orchestrator asks KubeRay for a cluster, one job runs on it, and
the cluster is reclaimed the moment that job finishes. You pay for GPUs and
worker nodes only while a job is actually running, and there is no long-lived
cluster to keep patched, healthy, or right-sized.

Runnable artifacts for everything below live in
[`examples/ephemeral-ray/`](../examples/ephemeral-ray).

## Two ways to run Ray

The module supports both shapes; they are not mutually exclusive.

- **Persistent cluster** (`enable_ray_cluster = true` in `workloads`): a
  standing `RayCluster` with an autoscaling worker group, ideal for interactive
  use — notebooks attach to it, workers scale to zero when idle but the head
  node stays up. Good for humans exploring.
- **Ephemeral cluster** (this document): no standing cluster. Each batch job
  brings up its own throwaway cluster. Good for scheduled/triggered pipelines
  where you know the workload up front and want the floor cost to be zero.

Most deployments want both: a small persistent cluster for interactive work and
ephemeral clusters for pipelines.

## The primitive: `RayJob` with `shutdownAfterJobFinishes`

Everything here is one KubeRay object — a
[`RayJob`](https://docs.ray.io/en/latest/cluster/kubernetes/getting-started/rayjob-quick-start.html):

```yaml
apiVersion: ray.io/v1
kind: RayJob
spec:
  shutdownAfterJobFinishes: true   # <- this is what makes the cluster ephemeral
  ttlSecondsAfterFinished: 120
  entrypoint: python my_job.py
  rayClusterSpec: { ... }          # the cluster to create for this job
```

The operator:

1. creates the `RayCluster` described by `rayClusterSpec`;
2. waits for it to be ready and runs `entrypoint` on it;
3. when the entrypoint exits, **deletes the whole cluster** (because
   `shutdownAfterJobFinishes` is true);
4. garbage-collects the `RayJob` record after `ttlSecondsAfterFinished`.

The full, standalone spec is [`examples/ephemeral-ray/rayjob.yaml`](../examples/ephemeral-ray/rayjob.yaml).
You can `kubectl apply` it directly to see the pattern with no orchestrator at
all — which is the point: **the orchestrator's only job is to create this
object and wait for its status.** Teardown is KubeRay's problem, not the
orchestrator's.

## Who creates the `RayJob`

### Argo Workflows

An Argo `resource` template creates the `RayJob` and blocks on its status:

```yaml
resource:
  action: create
  successCondition: status.jobStatus == SUCCEEDED
  failureCondition: status.jobStatus == FAILED
  manifest: |
    apiVersion: ray.io/v1
    kind: RayJob
    ...
```

Argo watches the RayJob's `status.jobStatus` and fails the step if the job
fails — no custom polling code. Full example:
[`examples/ephemeral-ray/argo/workflow.yaml`](../examples/ephemeral-ray/argo/workflow.yaml).

Use this when Ray work is one node in a larger DAG that already lives in Argo,
or when non-engineers trigger runs from the Argo UI.

### Dagster

A Dagster op creates the same `RayJob` through the Kubernetes API and polls it
to completion:

```python
api.create_namespaced_custom_object(group="ray.io", version="v1",
                                     plural="rayjobs", namespace="ray",
                                     body=rayjob_manifest)
# ...poll get_namespaced_custom_object_status until jobStatus is terminal
```

Full example:
[`examples/ephemeral-ray/dagster/ephemeral_ray.py`](../examples/ephemeral-ray/dagster/ephemeral_ray.py).

Use this when Ray work is part of a data pipeline that already lives in Dagster
and you want the run to show up as a Dagster asset/op with its logs, retries,
and lineage.

### Which one?

They are the *same primitive* with a different submitter, so pick by where the
rest of the workload already lives rather than by Ray considerations:

| | Argo Workflows | Dagster |
| --- | --- | --- |
| Best when | the surrounding DAG is infra/CI-shaped | the surrounding DAG is data-asset-shaped |
| Triggering | schedules, events, Argo UI, `argo submit` | schedules, sensors, Dagster UI |
| Waiting | declarative `successCondition` | Python poll loop (in the example op) |
| Toggle | `enable_argo_workflows` | `enable_dagster` |

## What the module gives you

With `enable_ray = true` (plus `enable_argo_workflows` and/or `enable_dagster`),
the modules provision the substrate these examples assume:

- `aws/eks-platform` installs the **KubeRay operator** (and the Argo Workflows
  CRDs when `enable_argo_workflows = true`).
- `workloads` creates the **`<name_prefix>ray` namespace** and the
  **`ray-s3-sa`** service account (IRSA → S3) that the Ray pods run as.
- `workloads` grants each orchestrator's service account a Role **in its own
  environment's Ray namespace** (bound there to the ServiceAccount of the
  orchestrator's namespace) to manage `rayjobs`/`rayclusters`, and nowhere
  else -- a RayCluster's pods may name any ServiceAccount of the namespace
  they run in, so the right to create one elsewhere would be the right to run
  as another environment:
  - Argo → namespace `<prefix>argo`, service account `argo-workflow`, Role `<prefix>argo-workflow-ray` (plus `<prefix>argo-workflow-role` for its own pods in `<prefix>argo`)
  - Dagster → service account `dagster`, Role `<prefix>dagster-ray-cluster-ops`

> The RBAC intentionally grants **both** `rayjobs` and `rayclusters`. `rayjobs`
> is the ephemeral primitive documented here; `rayclusters` is retained for
> workflows that manage a cluster's lifecycle by hand (create → run several
> steps → delete) when they need finer control than a single `RayJob` gives.

## Works with preview environments

Because everything is `name_prefix`-stamped, ephemeral Ray composes with
[preview environments](preview-environments.md): a preview's Ray namespace,
service account, and RBAC are all prefixed (`pr123-ray`, …), so a preview's
Ray jobs are isolated from prod's and from other previews'. Point the manifests
at the prefixed namespace and you get ephemeral clusters inside an ephemeral
environment.

## GPUs and cost

- The `rayClusterSpec` worker group is where you request GPUs
  (`resources.limits."nvidia.com/gpu"`) and/or pin to a Karpenter GPU NodePool
  via `nodeSelector`. Karpenter provisions the node when the RayJob's pods go
  pending and reclaims it after the cluster is torn down.
- Floor cost is **zero** running Ray nodes between jobs — the whole reason to
  prefer ephemeral over a persistent cluster for scheduled work.
- Set `ttlSecondsAfterFinished` low enough that finished clusters don't linger,
  but high enough to grab logs (`kubectl logs`) before GC if you need them.
