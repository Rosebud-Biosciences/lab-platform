# Complete example

Exercises the entire module family:

- `network` — VPC with one NAT gateway per AZ and a Tailscale subnet router for
  private admin access to the cluster API.
- `s3-bucket` — a hardened, KMS-encrypted bucket for MLflow artifacts.
- `eks-platform` — cluster with monitoring (Prometheus/Grafana), Kubecost,
  FluentBit, the NVIDIA GPU operator, KubeRay, Argo Workflows, and the Tailscale
  operator (which provides the `tailscale` IngressClass).
- `workloads` — a public webapp (ALB + WAF + Route53), JupyterHub, Dagster, a
  persistent Ray cluster, and MLflow, all reachable over the tailnet via private
  Ingresses, plus a GPU Karpenter NodePool.

## Bring your own

This example takes the external inputs the modules never invent for you:

- **DNS/TLS** — an ACM certificate ARN and a Route53 zone id for the public
  webapp host.
- **Tailscale** — an OAuth client that owns `tag:k8s-operator` and
  `tag:subnet-router`. Leave the OAuth fields empty to fall back to a public
  cluster endpoint with the private Ingresses disabled.
- **Databases** — Postgres connection details for the app, Dagster, and MLflow.
  See [`docs/preview-environments.md`](../../docs/preview-environments.md) for
  the recommended SSM Parameter Store pattern instead of plaintext tfvars.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in the blanks
tofu init
# First run: create the cluster before planning the workloads that use it.
tofu apply -target=module.network -target=module.platform
tofu apply
```

## Cost

This stack runs the monitoring/Kubecost/FluentBit add-ons, a per-AZ NAT gateway,
a persistent Ray cluster, and GPU-capable NodePools. Expect **hundreds to low
thousands of USD per month** depending on GPU usage. Turn features off in
`main.tf` to trim it down, or start from `examples/minimal`.
