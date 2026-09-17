# Minimal example

The smallest useful stack:

- `network` — a VPC with a single NAT gateway (no Tailscale router).
- `eks-platform` — an EKS cluster with the always-on add-ons (Karpenter, AWS
  Load Balancer Controller, metrics-server). Monitoring/Kubecost/FluentBit are
  off by default.
- `workloads` — a single `webapp` Deployment + Service.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # set webapp_image, region
tofu init
```

### Two-step apply (first run only)

The `kubernetes`/`helm`/`kubectl` providers are configured from the cluster this
stack creates, so the cluster must exist before Terraform plans the workloads
that talk to it. On a **fresh** apply, create the cluster first, then apply the
rest:

```bash
tofu apply -target=module.network -target=module.platform
tofu apply
```

Subsequent applies are just `tofu apply` — the cluster already exists.

### Remote state

This example ships with local state so it runs out of the box. For real use,
copy `backend.tf.example` to `backend.tf`, point it at the bucket/table from
`aws/bootstrap`, and re-run `tofu init`.

## Cost

Ballpark on-demand (us-west-2), nothing running on Karpenter yet:

| Item                         | ~$/mo |
| ---------------------------- | ----- |
| EKS control plane            | 73    |
| Core node group (2× t3a.large) | 120 |
| Single NAT gateway           | 33    |
| **Baseline**                 | **~225** |

Karpenter-scheduled workloads (Ray, JupyterHub, etc.) add on top when enabled.
Destroy with `tofu destroy` when you are done.
