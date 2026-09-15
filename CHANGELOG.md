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
- `chart-drift` GitHub workflow + `.github/scripts/chart-drift.sh` — monthly
  report (one self-refreshing issue) of every module-input Helm chart pin
  against its repository's stable releases, which Dependabot cannot see. The
  Tailscale operator chart is held to "any newer release": it is the Tailscale
  version of every container on the tailnet and containers cannot self-update.
- `modules/network`: `ts_relay_ami` pins the relay's image (empty keeps the
  previous resolve-Canonical's-current behaviour, which rebuilds the relay on
  Canonical's publish schedule), and a rebuild now re-mints the relay's
  single-use pre-auth key in the same apply via `terraform_data.relay_build` —
  previously a replaced instance booted with the already-spent key and never
  joined the tailnet.
- `docs/upgrades.md` — what Dependabot covers and cannot, the chart-drift
  report, and the three update paths for Tailscale clients (chart pin for
  containers, auto-update on the relay, the tailnet-wide default for the rest).
- Tailscale operator chart default bumped 1.98.9 → 1.102.3.
- A second provider of ephemeral preview data, documented in
  `docs/preview-environments.md` ("Ephemeral data: two providers"): alongside
  the Terraform modules that stamp isolated empty copies, a dataset tool
  ([tether](https://github.com/elyall/tether)) may fork the production stores
  per preview. Three pieces make that possible without touching the tofu path:
  `modules/data-access` (read/write-no-delete IAM on prod store prefixes and
  read/commit on listed S3 Tables tables), a `secrets.extra_tfvars_json` input
  on the reusable `preview-up` / `preview-down` workflows (a JSON object, or
  base64 of one, written to `external.auto.tfvars.json` before apply/destroy,
  for values a previous job minted), and `dagster_user_code_env` /
  `dagster_user_code_secret_env` on the workloads module. The latter also fixes
  a gap: Dagster's user-code deployment and its runs now receive `DATABASE_URL`
  like the webapp does, where previously they received no environment at all.
- `modules/eks-platform`: the EBS CSI IRSA role moves to
  `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts` `~> 6.8`
  (v6 folded the `-eks` submodule into it; the workloads module was already
  there). Applying this to an existing cluster recreates the role under a new
  name; the add-on picks up the new ARN in the same apply.
- GitHub Actions bumped to current majors across the workflows:
  `actions/checkout` v7, `opentofu/setup-opentofu` v2, `actions/github-script`
  v9, `terraform-linters/setup-tflint` v6, `tailscale/github-action` v4.1.3.
- Module READMEs are regenerated from a clean checkout: the provider tables
  showed resolved versions from local `.terraform.lock.hcl` files, which the
  terraform-docs CI gate (no lock files) rejected. Regenerate with no lock
  file beside the module.
- checkov's first run against the modules, resolved one finding at a time
  rather than softened. Adopted: S3 ACLs disabled (`BucketOwnerEnforced`,
  the `aws_s3_bucket_acl` resources are gone) on the state bucket and the
  `s3-bucket` module; point-in-time recovery on the lock table; an
  abort-incomplete-multipart rule on the state bucket; SSE-KMS by default on
  the state bucket with the AWS-managed `aws/s3` key (no customer key policy
  to lock an operator out, no grants to hand out; bucket key on); WAF request
  logging to a 30-day `aws-waf-logs-*` log group; the ECR pull actions scoped
  to the account's repositories (only `GetAuthorizationToken` keeps `*`).
  Declined, with the reason beside each: `.checkov.yml` for the repo-wide
  four (module commit-hash pins, cross-region replication, S3 event
  notifications, a CMK on the lock table) and inline `#checkov:skip` on the
  resource for access logging, the opt-in IAM-user attachments, the
  ephemeral bucket's versioning and the Grafana secret's rotation.
- Module sources and reusable-workflow references in the docs name the
  upstream repo, `github.com/Rosebud-Biosciences/terraform-aws-lab-platform`,
  instead of the `your-org` placeholder; forks of the platform replace it.
- Removed two unused declarations tflint flagged: `ts_tailnet` on
  `modules/network` (a leftover from when the module configured the Tailscale
  provider itself; the caller does) and the `private_mlflow_fqdn` local in
  `modules/workloads` (the output computed the same URL inline).
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
  tag. Note the operator applies tags only when it first provisions a proxy:
  changing a tag on a live Ingress requires recreating it (`tofu apply
  -replace=...`), and the tag must already be in the ACL's `tagOwners`.
- `access_entries` and `enable_cluster_creator_admin_permissions` on
  `modules/eks-platform`. Until now the only human who could reach the cluster
  was whichever identity ran the first apply; any other principal — an
  operator role, an SSO permission set, a CI deployer — needed a module edit.
- Opt-in human-operator identity in `modules/bootstrap`
  (`enable_operator_admin_role`): an admin role assumable only with a recent
  MFA challenge, and a guardrail Deny policy protecting state history, the
  lock table, CloudTrail, and the role itself from a leaked long-lived key.
  Outputs `operator_admin_role_arn` (feed it to `access_entries`) and
  `operator_guardrails_policy_arn` (attach it to your static identity).
- `docs/operator-access.md` — how a person should authenticate to run tofu:
  why `AWS_PROFILE` with `mfa_serial` cannot work with the provider and the
  `export-credentials` workaround; why `aws:MultiFactorAuthPresent` is absent
  from every assumed-role session and what that means for guardrail design;
  `GetSessionToken` as break-glass; the EKS access-entry chicken-and-egg; and
  the two-pass apply for changing a guardrail that binds you.
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
