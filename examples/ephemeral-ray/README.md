# Ephemeral Ray clusters

Runnable artifacts for the pattern described in
[`docs/ephemeral-ray.md`](../../docs/ephemeral-ray.md): an orchestrator spins up
a Ray cluster on demand, runs one job on it, and lets it disappear. There is no
always-on Ray cluster to pay for or keep healthy.

The mechanism is the same in every case — a KubeRay
[`RayJob`](https://docs.ray.io/en/latest/cluster/kubernetes/getting-started/rayjob-quick-start.html)
with `shutdownAfterJobFinishes: true`. The only thing that differs is who
creates it.

| File | Who submits the RayJob |
| --- | --- |
| [`rayjob.yaml`](rayjob.yaml) | You, via `kubectl` (the bare primitive) |
| [`argo/workflow.yaml`](argo/workflow.yaml) | An Argo Workflows step |
| [`dagster/ephemeral_ray.py`](dagster/ephemeral_ray.py) | A Dagster op |

## Prerequisites

Deploy the `workloads` module with the relevant toggles on:

```hcl
module "workloads" {
  # ...
  enable_ray             = true
  enable_argo_workflows  = true   # only for the Argo example
  enable_dagster         = true   # only for the Dagster example
}
```

This creates the `<name_prefix>ray` namespace, the `ray-s3-sa` service account
(IRSA for S3), and — for each orchestrator — a service account bound to a
ClusterRole that can manage `rayjobs`. The KubeRay operator itself is installed
by the `eks-platform` module (`enable_ray = true`; add `enable_argo_workflows`
for the Argo controller).

Namespaces and pool names are prefixed in stamped/preview environments (e.g.
`pr123-ray`); adjust the `-n` flag and any `nodeSelector` accordingly.

## Try it

Bare primitive — no orchestrator:

```bash
kubectl apply -n ray -f rayjob.yaml
kubectl get rayjob -n ray -w        # PENDING -> RUNNING -> SUCCEEDED
kubectl get raycluster -n ray -w    # a cluster appears, then is reclaimed
```

Argo:

```bash
argo submit -n argo argo/workflow.yaml --watch   # the RayJob it creates lands in the ray namespace
```

Dagster (local dev UI against your kubeconfig):

```bash
pip install dagster kubernetes
dagster dev -f dagster/ephemeral_ray.py
```

See [`docs/ephemeral-ray.md`](../../docs/ephemeral-ray.md) for the "why", the
RBAC contract, and cost/GPU notes.
