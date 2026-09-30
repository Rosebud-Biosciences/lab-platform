# kind: local compute + local data

The whole workloads layer -- webapp, Dagster, a Ray cluster, MLflow, Argo
Workflows (with its archive), optionally JupyterHub -- on a
[kind](https://kind.sigs.k8s.io/) cluster on your laptop,
with [SeaweedFS](https://github.com/seaweedfs/seaweedfs) as the S3 API,
Postgres as the database and [Dex](../../modules/dex) as the OIDC issuer
gating the UIs. **No cloud account, no adapters, no `aws` provider, no
external identity provider.** This is the same `modules/workloads` the AWS
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
3. `tofu apply` of [`main.tf`](main.tf): Dex first, then the workloads with
   `auth = { mode = "oidc" }` against it;
4. [`scripts/verify.sh`](scripts/verify.sh): every Deployment rolled out, the
   RayCluster `ready`, MLflow / Dagster / the webapp answering their health
   endpoints from inside the cluster -- then the auth gates, the network
   fence and client ownership (below).

## Tenants and admins (the default: `enable_keycloak = true`)

Keycloak holds the users behind Dex ([`tenants.tf`](tenants.tf)), and
[`modules/tenancy`](../../modules/tenancy) places two tenants: **lab**
(internal) shares everything but runs its own Ray (`t-lab-ray`); **acme**
(external) shares only the webapp, JupyterHub and MLflow and runs its own
Ray, Argo and Dagster (`t-acme-*`), with a bucket and a SeaweedFS identity
of its own. MLflow runs its own OIDC with per-experiment permissions.

| User (`@example.com`, password `password`) | Groups | Is |
| --- | --- | --- |
| sam | `/platform-admins` | superadmin |
| ann | `/lab/authors` | member |
| alice | `/lab/authors/admins` | group admin |
| bob | none | nobody -- until alice adds him |
| cara | `/acme/research` | member of the external tenant |
| dan | `/acme/admins` | tenant admin |

[`scripts/verify-tenants.sh`](scripts/verify-tenants.sh) proves each rule
from inside the cluster: who opens which Ray, Dagster and Argo (and who may
submit), what alice and dan may change in Keycloak (and what not), which
MLflow experiments each sees and that acme's compute got its service-account
token, that Ray scales a worker from zero, that `nb_lab__authors` connects,
that acme's identity cannot read lab's bucket nor lab's namespaces reach
acme's Ray, and that an external tenant on a shared Dagster fails `tofu plan`.
sam administers the realm at `http://localhost:30080/admin/lab/console`
(`tofu output keycloak`); the master realm has no users at all, only the
admin client tofu configures the realm with. This flow needs about 7.5 GiB
for the node; `enable_keycloak = false` runs the smaller flow below.

## Logging in (`enable_keycloak = false`)

Dex has two ways in, so both a plain login and a group gate can be exercised
without any external IdP:

| Login | Identity | Groups | Opens |
| --- | --- | --- | --- |
| password DB: `admin@example.com` / `password` (`dex_admin_password_hash`) | admin | none | MLflow, Ray dashboard; **Dagster refuses** (403) |
| the "Example (mock user, group authors)" button | `kilgore@kilgore.trout` | `authors` | everything |

`main.tf` gates Dagster on `allowed_groups = ["authors"]` and admits MLflow
and Ray to the two test identities' email domains (gates are default-deny, so
even "any user" is named); Argo runs its native SSO against Dex with one rule,
authors may run workflows. `verify.sh` scripts exactly those outcomes with a
curl pod ([`scripts/oidc-login.sh`](scripts/oidc-login.sh) runs the OIDC dance
from inside the cluster) and asserts anonymous requests bounce to Dex. Two
more checks:

- **the fence** -- the probe pod runs in namespace `verify`, which `main.tf`
  names as the ingress namespace (`network_policies`). From there the proxies
  answer and Dagster's and MLflow's own pods refuse the connection; from the
  webapp's namespace, a legitimate client, both answer. kind's kindnet
  enforces NetworkPolicy, so this is the real behaviour.
- **client ownership** -- impersonating `preview-ci` (Dex's
  `client_admission` restricts that principal), it creates and deletes a
  `pr9-` client, and is refused when it tries to rewrite this environment's
  oauth2-proxy client.

From a browser the redirects point at in-cluster hostnames
(`dagster-auth.dagster.svc.cluster.local`, `dex.dex.svc.cluster.local`),
because that is what both the curl pod and the proxies can reach. To click
through a login from the laptop, port-forward Dex on 5556 and a proxy on 80
and add those two hostnames to `/etc/hosts` as `127.0.0.1`; the
`port_forwards` output for Dagster/MLflow bypasses the proxy (a plain
port-forward to the service) when you only want the UI.

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
- `auth = { mode = "oidc", dex_namespace = module.dex.namespace, ... }`: the
  module registers this environment's OAuth2 clients as `OAuth2Client` CRs in
  Dex's namespace (`kubectl -n dex get oauth2clients`), puts an
  `oauth2-proxy` in front of each service in `protect`, and switches Argo to
  SSO. `tofu output auth` shows the clients and their redirect URIs. The same
  block on EKS behind Tailscale gives defence in depth; `mode = "headers"`
  (the default) is the tailnet-only setup. Design: [`docs/auth.md`](../../docs/auth.md).
- No private ingress: port-forward instead (`tofu output port_forwards`). The
  Tailscale operator installs on kind too if you want the prod URLs.

## Sizing

Requests total about 1.8 vCPU / 5 GiB with JupyterHub off (the default),
kind's own control plane (about 1 vCPU of it) included. That fits the
2-vCPU / 7 GiB runner GitHub gives a private repository, with little to
spare. The requests are deliberately small (25-50m for the Ray heads, their
autoscalers and workers, Postgres and SeaweedFS; 100m for Keycloak) and the
limits let a busy pod burst: nothing here is load-tested. `enable_jupyterhub = true` adds the hub, proxy and one
notebook server on first login, beyond this budget.
