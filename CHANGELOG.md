# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial open-source release extracted from a private research-platform IaC repo.
- `modules/bootstrap` — Terraform state backend (S3 + DynamoDB lock table) and
  GitHub OIDC CI/preview roles with state writes scoped to `preview/*`.
- `modules/network` — multi-AZ VPC with an optional Tailscale subnet router.
- `modules/eks-platform` — EKS cluster plus toggleable cluster-wide operators
  (Karpenter, AWS Load Balancer Controller, metrics-server, kube-prometheus,
  Fluent Bit, Kubecost, GPU/Neuron device plugins, KubeRay, Argo, Tailscale).
- `modules/workloads` — name-prefixable application layer (webapp, JupyterHub,
  Dagster, MLflow, Ray) with per-service `enable_*` toggles, powering preview
  environments that stamp prefixed copies onto a shared cluster.
- `modules/s3-bucket` — hardened S3 bucket with KMS, lifecycle, and IAM policies.
- `modules/preview-storage` — ephemeral per-preview processed-data bucket.
- `modules/neon-branches` — copy-on-write Neon Postgres branches for previews.
- `examples/{minimal,complete,preview}` — runnable reference stacks.
- Reusable `preview-up`, `preview-down`, and `nightly-sweep` GitHub workflows
  (`workflow_call`).
- Plan-only `tofu test` toggle-matrix suites for `bootstrap`, `network`, and
  `workloads` (mocked providers; assert each `enable_x = false` creates no
  resources of that family).
- terraform-docs-generated tables in every module README, plus a root README and
  `docs/preview-environments.md` design writeup.
- `docs/ephemeral-ray.md` + `examples/ephemeral-ray` — the ephemeral-Ray pattern
  (a `RayJob` with `shutdownAfterJobFinishes`) submitted by either Argo Workflows
  or Dagster, with runnable manifests and a standalone `kubectl apply` primitive.
- `integration-apply` GitHub workflow — real apply/smoke/destroy against an
  ephemeral AWS account, **disabled by default** (gated on the
  `ENABLE_INTEGRATION_APPLY` repo variable and a protected environment) so it
  never spends money until explicitly funded and turned on.
- `examples/jupyterhub` — multi-user lab: per-user logins via the new
  `firstuse` auth mechanism (each user sets their own password at first login),
  per-user EFS home directories (`home/{username}` sub-paths) plus a shared
  `/home/shared` directory, and marimo in the JupyterLab launcher (postStart
  install of `marimo` + `jupyter-marimo-proxy`). The workloads module gained
  `jupyterhub_admin_users`, `jupyterhub_allowed_users`, and
  `jupyterhub_extra_values` for arbitrary caller overrides.
- `modules/iceberg-branches` — ephemeral per-preview Iceberg (S3 Tables)
  namespace with namespace-scoped IAM policies, wired into `examples/preview`
  behind `iceberg_table_bucket_arn`; the bootstrap preview role gained optional
  s3tables statements (`preview_table_bucket_arns`).
- Deletion guards on all persistent data (see "Persistent data & deletion
  guards" in the README): the JupyterHub EFS filesystem is now genuinely
  protected by `lifecycle.prevent_destroy` (two-variant resource pattern —
  previously the flag was documentation-only), the state bucket gets a Deny
  `s3:DeleteBucket` policy, and the lock table gets native DynamoDB deletion
  protection.
- `nightly-sweep` accepts `extra_destroy_args` (parity with `preview-down`) so
  stacks whose variables lack defaults can still be swept.
- `examples/preview` now documents the stack's own S3 backend, including the
  non-obvious `workspace_key_prefix` requirement: workspace state lands at
  `<prefix>/<workspace>/<key>`, so the backend default (`env:`) would fall
  outside the `preview/*` prefix the bootstrap preview role may write.
- Dependabot config covering GitHub Actions and Terraform providers/modules
  across `modules/*` and `examples/*` (Helm chart pins inside `*.tf` are not an
  ecosystem Dependabot understands — bump those by hand or with Renovate).
- CI and the reusable workflows default to OpenTofu 1.12.6 (1.9 left security
  support in May 2026); action pins unified (`checkout@v5`,
  `configure-aws-credentials@v6`).
- First-class OIDC login for JupyterHub: `jupyterhub_auth_mechanism = "oidc"`
  plus `jupyterhub_oidc_*` variables (client, endpoints, callback, username
  claim) drive the generic-oauth authenticator directly — no hand-written
  `jupyterhub_extra_values` YAML. Replaces the placeholder `"cognito"`
  mechanism; the Google worked example lives in `examples/jupyterhub`.
- `private_ingress_annotations` on `modules/workloads`: decorate the private
  Ingresses per service or all at once (`"*"`), built for Tailscale ACL
  scoping via `tailscale.com/tags` device tags — grant ops UIs to a platform
  group, the webapp to every member, or a whole preview environment under one
  tag.
- The family is now **OpenTofu-only** (`required_version >= 1.12` everywhere):
  persistent-data guards use OpenTofu 1.12's dynamic `prevent_destroy`. The
  JupyterHub EFS two-resource guard pattern collapses into one resource whose
  guard follows `jupyterhub_efs_prevent_destroy` — flipping the flag is now a
  plan-time guard change instead of a filesystem REPLACEMENT — and the
  `s3-bucket` module's bucket/KMS key (plus the bootstrap state bucket) gain
  plan-time guards layered on the existing Deny policies. Terraform's
  literal-only `prevent_destroy` cannot express any of this; the repo keeps
  the `terraform-aws-*` name only because registries require it.

### Changed vs. the original private repo

- Provider blocks hoisted out of the `s3-bucket` and `network` modules
  (registry compatibility; enables `count`/`for_each`).
- JupyterHub moved from the cluster module into `workloads` so it can be
  toggled per environment and previewed.
- Dagster's implicit dependency on Ray is now an explicit precondition.
- Private ingress class is configurable (Tailscale remains the documented default).
- Helm chart tarballs un-vendored in favour of pinned upstream repositories.
- Preview GPU NodePools are name-prefixed; preview MLflow artifacts route to the
  ephemeral bucket.
- EKS module bumped from v20 to v21 so the whole family standardizes on the AWS
  v6 provider (the v20 module capped `aws < 6.0`, which conflicted with the
  VPC v6 module and blocked composing the modules in one configuration).
- Helm provider 3 + `eks-blueprints-addons` 1.24.3 (the private repo is stuck on
  helm 2 / blueprints 1.23 because the provider-2→3 state migration is broken
  upstream; a green-field OSS apply never migrates state, so it adopts helm 3
  cleanly — and shipping the `~> 2.17` cap would otherwise force every consumer
  onto helm 2). No divorce from `eks-blueprints-addons` is needed: 1.24.3
  supports helm 3.
- Fixed the `network` secondary (pod) CIDR split, which was hardcoded to two
  AZs (`cidrsubnet(secondary, 1, k)`) yet defaulted to three; newbits now scale
  with the AZ count.
- The Argo and Dagster ClusterRoles now grant `rayjobs` in addition to
  `rayclusters`, enabling the ephemeral `RayJob` pattern without hand-managing a
  cluster's lifecycle.
