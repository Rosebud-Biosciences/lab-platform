# kind: local compute + local data

The whole workloads layer -- webapp, Dagster, a Ray cluster, MLflow, Argo
Workflows (with its archive), optionally JupyterHub -- on a
[kind](https://kind.sigs.k8s.io/) cluster on your laptop,
with [SeaweedFS](https://github.com/seaweedfs/seaweedfs) as the S3 API and
Postgres as the database. **No cloud account, no adapters, no `aws`
provider.** This is the same `modules/workloads` the AWS
examples deploy; the four contract inputs are simply written by hand here,
which also makes this file the template for a `metal/` backend.

It doubles as the module's integration test:
[`.github/workflows/kind-smoke.yml`](../../.github/workflows/kind-smoke.yml)
runs it on every PR that touches `modules/workloads`, for free.

## Run it

Needs `kind`, `kubectl`, `helm`, `tofu`, and a container runtime (Podman or
Docker; ~6 GiB of memory for the runtime).

```bash
cd examples/kind
scripts/up.sh            # cluster + prerequisites + tofu apply + health checks (~8 min)
tofu output port_forwards
scripts/down.sh          # tofu destroy + delete the cluster
```

`scripts/up.sh` does, in order:

1. `kind create cluster` from [`kind-config.yaml`](kind-config.yaml);
2. [`scripts/prereqs.sh`](scripts/prereqs.sh): what any cluster must provide
   (KubeRay operator, the Argo Workflows CRDs, metrics-server) plus the local
   data backend (SeaweedFS with `mlflow` and `data` buckets, Postgres with
   `app`/`dagster`/`mlflow`/`argo` databases). See the workloads README, "Cluster prerequisites";
3. `tofu apply` of [`main.tf`](main.tf);
4. [`scripts/verify.sh`](scripts/verify.sh): every Deployment rolled out, the
   RayCluster `ready`, and MLflow / Dagster / the webapp answering their health
   endpoints from inside the cluster.

## What to look at

- `workload_identity` / `workload_identity_secret_env` in `main.tf`: the
  static-credential path of the identity contract. Every service gets
  `AWS_ENDPOINT_URL` (SeaweedFS) in `env` and the access keys in a
  `<service>-identity-env` Secret. Any S3-compatible store works here; the
  `AWS_*_CHECKSUM_*` settings keep the AWS SDKs off the flexible-checksum
  uploads only AWS S3 itself is guaranteed to accept. Swap these for the outputs of
  `aws/data-adapter` and the same pods talk to real S3 -- that is
  [`examples/kind-aws-data`](../kind-aws-data).
- `jupyterhub_shared_storage = { storage_class_name = "standard" }`: the
  dynamic-RWX branch of the storage contract (kind's local-path class is RWO
  but a single node mounts it everywhere).
- `scheduling` is left at its default: one node, everything schedules anywhere.
- No private ingress: port-forward instead (`tofu output port_forwards`). The
  Tailscale operator installs on kind too if you want the prod URLs.

## Sizing

Requests total about 2.5 vCPU / 5 GiB with JupyterHub off (the default), which
fits a 4-vCPU / 16 GiB GitHub runner alongside kind itself. `enable_jupyterhub
= true` adds the hub, proxy and one notebook server on first login.
