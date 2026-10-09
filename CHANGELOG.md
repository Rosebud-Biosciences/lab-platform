# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-10-09

Previews confined: a preview's deploy identity owns only the `preview-*`
namespaces it creates, the roles it makes reach only what it owns, and a pull
request cannot write prod's trunk or its pins. This closes the two gaps
SECURITY.md listed for 0.2.0, and new clusters' first apply works again.
Several changes are breaking: read each "Upgrading" note first, and upgrade
with no preview standing (every Kubernetes name a preview makes changes).

### Fixed: a new cluster's first apply deadlocked (since 0.2.0)

- `aws/eks-platform`: the EKS module (21.x) creates clusters without EKS's
  own VPC CNI and kube-proxy (`bootstrap_self_managed_addons` is hard-coded
  off), and the platform installed them through the blueprints module, whose
  add-ons wait for the Helm provider. Since 0.2.0 the `cluster_endpoint` the
  providers are configured from waits for the node group (so a destroy
  removes in-cluster resources first), and the node group waits for the CNI:
  a new cluster's apply hung until the node group failed with
  `NodeCreationFailure: Unhealthy nodes in the kubernetes cluster`. Both now
  come from the EKS module's `addons` with `before_compute = true`, which
  wait for the cluster alone; `moved` blocks carry an existing cluster's
  add-ons over without reinstalling them. Existing clusters were unaffected.

### Security (**breaking**): a preview deploys inside its own namespaces only

- New `modules/preview-access`: what a preview's deploy identity may do
  outside its namespaces -- create, change and delete its namespaces and,
  with Karpenter, its NodePools and EC2NodeClasses, and read the
  cluster-scoped kinds the providers look up -- with a
  ValidatingAdmissionPolicy that admits only names starting with
  `namespace_prefix` (`preview-`) from its group, on the new and the old
  object; optionally OAuth2Clients in Dex's namespace. Inside each namespace
  it creates, the preview binds the module's namespace-admin ClusterRole to
  its group first, and owns the namespace through RBAC; the ClusterRole lets
  it bind that role alone, and the policy keeps its RoleBindings to `preview-`
  namespaces. On EKS the preview role's access entry maps it to the group
  with no access policy, replacing cluster admin (`AmazonEKSAdminPolicy`
  covers no custom resources, and the API server lets nobody create a Role
  granting more than they hold through RBAC, as every chart a preview
  installs does). `aws/eks-platform`'s new `preview_access` installs it and
  documents the access entry; `preview_access_group` and
  `preview_namespace_admin_cluster_role` are its outputs.
- `modules/workloads`: `namespace_admin = { cluster_role, group }` binds the
  role in every namespace the module creates, and everything namespaced
  waits for the binding.
- `aws/compute-adapter`: `node_pools_namespace` (default `karpenter`) holds
  the NodePool Helm releases; a preview passes its own namespace, so it writes
  nothing in Karpenter's.
- `modules/dex` (**breaking**): `client_admission.allowed_id_pattern`
  defaults to `^preview-`, matching the preview prefix; it was `^pr[0-9]+-`.
- Upgrading a preview stack: its `name_prefix` (namespaces, NodePools, the
  Dex clients and IRSA subjects that derive from it) must start with the
  prefix -- the template uses `preview-pr<N>-` -- and its NodePools'
  `node_pools_namespace` is one of its own namespaces. Hostnames can keep
  their old prefix (`private_ingress_hostname_prefix`).

### Security: a pull request cannot write prod's trunk or its pins

- `aws/data-access`: `protect_trunk` denies writes and deletes to each
  store's trunk and the pins on it -- Lance's root versions, manifest and tags
  (`*.lance`), Icechunk 1.x's `main` ref and tags (`*.icechunk`), Delta's log
  (`*.delta`) -- while a fork's own branch, new data and chunks stay
  writable. Set it on every policy a pull request controls: the preview's
  pods' (the template's `infra/preview`) and the role its workflow assumes
  for `fork-data` and `data-down` (`DATA_ROLE_ARN`). The pins then come from
  default-branch runs alone: `data-pull` and `tether-matrix` assume
  `aws/bootstrap`'s teardown role, whose policy has no `protect_trunk`.
  Iceberg and Icechunk 2.x are not covered (each keeps every ref in one
  object a new branch rewrites: a table's metadata file, the repository's
  `repo`); keep the data bucket versioned.

### Security (**breaking**): the preview boundary caps resources, not only actions

- `aws/bootstrap`: the permissions boundary on every `/preview/` role no
  longer allows its actions on `preview_boundary_resources` (default `["*"]`,
  removed): a PR could make a preview role that read, wrote or deleted any
  bucket's objects in the account. It now reaches what a preview owns -- its
  ephemeral bucket, the KMS keys tagged as a preview's, reads in
  `preview_table_bucket_arns` and table writes in its own namespaces, image
  pulls from `preview_ecr_repositories` -- plus what the new
  `preview_boundary_access` lists, separately for `read`, `write` and
  `delete`, with `kms_key_arns`. S3 grants are pinned to the account
  (`aws:ResourceAccount`): the ephemeral bucket pattern also matches buckets
  in other accounts. Opt-in `preview_boundary_federated_providers` denies a
  preview role session that did not come through the listed OIDC providers
  (a role a PR made assumable from elsewhere); wildcards match, so
  `arn:aws:iam::<account>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/*`
  survives a cluster rebuild, which changes the cluster's own provider ARN.
- Upgrading: drop `preview_boundary_resources`. tether mode lists the
  preview stack's `aws/data-access` grants: `read` the data bucket ARN,
  `write` each data prefix (`arn:aws:s3:::<bucket>/tether/*`) and the prod
  table ARNs, `delete` the Lance working branches
  (`arn:aws:s3:::<bucket>/tether/*/_refs/branches/tether.ws.*` and
  `.../tree/tether.ws.*`), `kms_key_arns` the bucket's key. A deployment
  whose previews read other stores (a shared read-only policy in
  `preview_attachable_policy_arns`) lists them under `read`. Anything
  unlisted is now refused.
- `nightly-sweep` retires `/preview/` roles and policies (input `iam_path`,
  default `/preview/`; empty skips it) whose name belongs to no preview
  workspace still standing and that are older than `iam_min_age_hours`
  (24): a role a PR's workflow made outside the stack, or one a failed
  destroy left, no longer outlives its preview. A policy still attached is
  left in place.

## [0.2.0] - 2026-10-08 [YANKED]

Withdrawn on 2026-10-09, its tag and release deleted: a new cluster's first
apply deadlocks (0.3.0's first "Fixed" entry). Use 0.3.0.

The first release, and the first public one. Pin to it: the template app's
workflows call this repository's reusable workflows, which run with the
caller's AWS role.

### Added: what a public project needs

- `SECURITY.md` (private reporting, scope, and the two known gaps in the
  preview defaults: a cluster-admin preview role, and a permissions boundary
  that caps actions but not resources until `preview_boundary_resources` is
  set), `CONTRIBUTING.md` (the six CI gates), a Code of Conduct (Contributor
  Covenant 2.1), CODEOWNERS for the workflows and `aws/bootstrap`, and issue
  templates.
- `NOTICE`: the copyright holder, and the Helm values in
  `aws/eks-platform/helm-defaults` adapted from AWS's Data on EKS and NVIDIA's
  GPU Operator chart (both Apache-2.0), each file now marked as adapted.
- `ci` gains a job named `ci` that passes only when every gate did: the one
  check a branch ruleset needs to require.
- The workflows pin every third-party action to a commit SHA (Dependabot
  keeps them current). `kind smoke`'s AWS-data job no longer runs on pull
  requests once enabled: dispatch or schedule only, as its comment says.
- Removed `renovate.json`: its regex matched none of the markers, and
  Dependabot plus `chart-drift` are the update paths.

### Security: a preview cannot reach prod's IAM or another environment's identity

- `aws/bootstrap` (**breaking**): the preview role manages IAM only under
  `preview_iam_path` (default `/preview/`) instead of the `eks-*` name
  patterns, which on a shared cluster also matched prod's roles; it creates or
  changes only roles carrying a new permissions boundary (object-level S3, the
  S3 Tables data plane, KMS data keys, ECR pulls; `preview_boundary_resources`
  and `preview_boundary_extra_actions` tune it), and attaches only policies
  under the path (plus `preview_attachable_policy_arns`). Before, anyone able
  to push a branch could have attached any policy to an `eks-*` role.
  `preview_managed_role_pattern` and `preview_managed_policy_patterns` are
  gone; new outputs `preview_iam_path` and `preview_permissions_boundary_arn`.
- `aws/bootstrap` (**breaking**): the preview role reads state only under
  `preview_state_key_prefix` plus `preview_state_read_keys` -- set the latter
  to the preview stack's backend `key` if it lies outside the prefix, since
  `tofu init` reads the default workspace's object -- instead of the whole
  bucket, which holds prod's state and its secrets. The preview boundary
  denies the state bucket outright, so no policy a PR writes reaches it.
- `aws/data-adapter` gains `iam_path` and `permissions_boundary_arn`;
  `aws/data-access`, `aws/s3-bucket` gain `iam_path`; `aws/preview-storage` and
  `aws/iceberg-branches` gain `iam_path` (default `/preview/`).
  `examples/preview` wires them.
- `aws/data-adapter`: MLflow's artifact policy covers its prefix only, not the
  whole bucket (a tether-mode preview's prefix sits in prod's data bucket);
  `jupyterhub_s3_read_only` now defaults to `false` (it granted read on every
  bucket in the account).
- `modules/workloads`: Dagster's and Argo's Ray access (and Argo's pods) are
  namespaced Roles in the environment's own namespaces instead of
  ClusterRoles: creating a pod or RayCluster in any namespace let a preview,
  or another tenant, run as that namespace's ServiceAccounts.
- `aws/eks-platform`: `enable_network_policy` defaults to `true`, so the
  workloads' NetworkPolicies are enforced (without them, in auth mode
  `headers`, any pod could assert an identity to the webapp).

### Fixed: kind smoke ran out of CPU on a private repository's runner

- `examples/kind`: the tenants (`tenants.tf`) brought the requests to about
  2.6 vCPU with kind's control plane, on a node of 2 (a private repository's
  `ubuntu-latest`). The three Ray heads stayed `Pending` ("Insufficient cpu")
  until the verify script timed out. The first run to see it was the weekly
  schedule, because the commits went to `main` without a pull request. The
  Ray heads and workers, Postgres and SeaweedFS now request 25-50m each
  (limits unchanged). kind smoke's diagnostics now print each node's
  allocated resources and each pod's requests.
- `modules/workloads`: `ray_autoscaler_resources` sizes the autoscaler
  container in the Ray head pod. Unset, KubeRay gives it 500m CPU / 512Mi,
  which was most of each kind head's reservation (1.5 vCPU across three);
  `examples/kind` sets 50m, bringing the requests to about 1.8 vCPU.
- `examples/kind`: `verify-tenants.sh` checks the group role's login with
  `kubectl exec` in the Postgres pod. The `kubectl run --rm -i` it used lost
  the output of a `psql` that exits that fast, failing the check.

### Added: delete rights for retiring previews, split by who may hold them

- `aws/data-access`: two opt-ins to its "never delete".
  `working_branch_prefix` (e.g. `"tether.ws."`) lets the holder delete
  Lance working branches with that prefix (each one's ref file and tree)
  and nothing else. Retiring a tether-mode preview needs this, because
  Lance keeps a branch until its keys are deleted. `allow_delete` lets the
  holder delete anything under the prefixes, such as the stores a PR
  created. Pods keep neither.
- `aws/bootstrap`: an optional teardown role (`enable_teardown_role`,
  `teardown_repos`, `teardown_ref`) whose trust is one exact subject,
  `repo:…:ref:refs/heads/main`. A pull_request run can rewrite the workflow
  that assumes a role, so the broad deletes must sit on a role such a run
  can't assume. The role has no permissions of its own: the stack that owns
  the data attaches them, e.g. `aws/data-access` with `allow_delete`.

### Fixed: a destroy could cut its own path to a private cluster API

- `aws/eks-platform`: in-cluster resources depend on the cluster (their
  providers read its endpoint), but not on the path an operator reaches a
  private endpoint by: the Tailscale relay and the security group rule that
  admits it. A targeted destroy of the network removed that path, and the
  core node group, alongside them, and every in-cluster delete then timed out
  ("dial tcp 10.x.x.x:443: i/o timeout"), leaving a half-destroyed stack.
  The `cluster_endpoint` output is now read through
  `terraform_data.cluster_access`. That node depends on the cluster module
  (nodes and security group rules included) and on the new
  `cluster_access_dependencies` input, e.g.
  `[module.network.tailscale_instance_id]`. So a stack whose
  kubernetes/helm/kubectl providers use the output, as the examples do,
  destroys every in-cluster resource first. The value is unchanged and known
  at plan time; the first apply creates the node.
- `aws/network`: the relay instance depends on its security group's rules.
  Nothing depended on them, so a destroy deleted the relay's egress rule in
  its first second: the relay kept running but could open no connection to
  the API, and the in-cluster deletes timed out as before. The rules now go
  after the relay, and its first boot no longer races the egress it
  downloads Tailscale through.

### Changed: `aws/eks-platform` plans without a module `depends_on`

- Phase 2 of the add-ons waited for phase 1 through a module `depends_on`,
  which makes tofu resolve all of phase 1 transitively for every data source
  in phase 2. That was about 6 of the 9 s a `validate` of a full platform
  stack took, spent again on every plan, apply, destroy and import before
  any refresh. Phase 2 now references `terraform_data.phase_1_ready`, which
  carries the `depends_on`: through the blueprints module's
  `create_delay_dependencies`, which its add-ons' IAM roles and cluster
  settings pass through, and through the values of argo-events and
  kube-prometheus-stack, which reference nothing else. The order is
  unchanged. The first apply creates that node and replaces the blueprints
  module's internal `time_sleep`, a one-time 30 s wait.

### Fixed: a failed Helm install blocked every later apply

- Every Helm release the modules install (`modules/workloads`, `keycloak`,
  `dex`, and `aws/eks-platform`'s and `aws/compute-adapter`'s charts, including
  the blueprints addons) is now `atomic`. A release whose install timed out
  used to stay behind as `failed` outside the state, and each re-apply stopped
  at "cannot re-use a name that is still in use" until someone ran
  `helm uninstall`. Now a failed install uninstalls itself and a failed
  upgrade rolls back, so a re-apply starts clean. Dagster's release is atomic
  only with `wait_for_rollouts`, since atomic implies waiting.

### Fixed: the MLflow UI's lists failed behind the private ingress

- `modules/workloads`: MLflow >= 3.5 refuses state-changing requests from
  browser origins it was not told about, and its UI's searches (runs, logged
  models, traces) are POSTs from the UI's own origin: the UI loaded, but its
  run list said `INTERNAL_ERROR` and its models tab "You do not have
  permission". The module now sets `MLFLOW_SERVER_CORS_ALLOWED_ORIGINS` to the
  UI's origin under `private_ingress_dns_suffix`; `mlflow_cors_allowed_origins`
  adds others.

### Fixed: previews could not create Iceberg tables

- `aws/iceberg-branches`: `s3tables:CreateTable` was granted on
  `<bucket>/table/*`, but S3 Tables authorizes it against the table bucket, so
  a preview's pods could create no table in their own namespace. It is now
  granted on the bucket, still confined to the namespace by the
  `s3tables:namespace` condition.

### Fixed: CI and preview roles for repositories on GitHub's immutable OIDC subject

- `aws/bootstrap` gains `github_owner_id` and `github_repository_ids`. A
  repository created, renamed or transferred since 2026-07-15 (or opted in)
  gets Actions tokens whose subject names its owner and itself by ID as well
  (`repo:OWNER@OWNER_ID/REPO@REPO_ID:…`), which the roles' name-only pattern
  never matched, so its workflows could not assume either role. A listed
  repository is trusted under its immutable subject only; unlisted ones keep
  the name-only pattern, so existing callers see no change.

### Changed: long-running services off spot

- `examples/preview` splits its pool: Dagster, Argo, MLflow and the Ray head
  share an on-demand `services` pool, and Ray workers get a tainted spot
  `workers` pool. A spot reclaim of the Ray head ended the Ray cluster and its
  jobs; one of Dagster's killed its in-flight runs. The `aws/compute-adapter`
  README's example and guidance say the same.

### Fixed: a new VPC's Tailscale relay could fail to join the tailnet

- `aws/network`: the relay instance waited only for its subnet, so its first
  boot could run before the NAT gateway's route existed; the Tailscale
  download failed, the boot script stopped before `tailscale up`, and the
  private cluster endpoint stayed unreachable. It now waits for the whole VPC,
  and the boot script retries the download. The user-data change stops and
  starts an existing relay once on the next apply.

### Added: `modules/workloads` `wait_for_rollouts`

- Default `true`, as before. Off, an apply submits the webapp deployment and
  the Dagster release without waiting for them to become ready: for a stack
  whose CI pushes those images, whose first apply comes before any exist
  (and would otherwise time out after ten minutes).

### Fixed: the load balancer controller on a new cluster

- `aws/eks-platform`: the AWS Load Balancer Controller crash-looped: it
  discovers its VPC from instance metadata, which the EKS module's nodes
  (one metadata hop) do not let pods reach. Its VPC ID and region are now
  passed in.
- Phase 1 did not wait for the controller's pods either, so Karpenter, the
  KubeRay operator and the other releases that create Services could hit its
  webhook before anything served it ("no endpoints available for service
  aws-load-balancer-webhook-service"). Its release now waits (up to 10
  minutes) for the controller to be ready.

### Fixed: preview teardown with Iceberg tables

- `aws/iceberg-branches` drops the namespace's tables on destroy
  (`drop_tables_on_destroy`, default on); a namespace with tables cannot be
  deleted, so `preview-down` failed and leaked it.

### Fixed: tether-mode access to an SSE-KMS data bucket

- `aws/data-access` gains `kms_key_arn`: with it, the policy also grants
  `kms:Decrypt` / `kms:GenerateDataKey` on the bucket's key, without which
  the prefix grants cannot read or write a single object of a bucket
  `aws/s3-bucket` made (it encrypts with its own customer-managed key).

### Added: groups, admins, tenants -- `modules/keycloak`, `modules/keycloak-realm`, `modules/tenancy`, `modules/postgres-group-roles`, `aws/tenant-data`

- New `modules/keycloak`: Keycloak (codecentric/keycloakx 7.3.2, Keycloak
  26.7.4) on an external Postgres, hostname v2 with a dynamic back-channel,
  fine-grained admin permissions v2, a bootstrap admin that is a
  service-account client (no master-realm user or password), optional
  NodePort, a public Ingress serving the platform realms (`/realms/<realm>`,
  never master) and `/resources` only, and an optional admin hostname +
  Ingress for the console.
- New `modules/keycloak-realm`: tenants as group subtrees with admins groups,
  superadmins in `/platform-admins` (authoritative), delegated tenant and
  group admins fenced to their own groups, a Dex client whose tokens carry
  full-path groups (`dex_connector` / `dex_connector_env`), brokered Google /
  GitHub / OIDC logins (linking a first login to an existing user by email
  opt-in per provider and only on trusted emails; generic OIDC always
  issuer- and signature-checked), SSO sessions that outlast the relying
  parties' refreshes (`sso_session_idle_timeout` 4h,
  `sso_session_max_lifespan` 24h), optional `smtp` and `verify_email`,
  brute-force protection, local users for CI.
- New `modules/tenancy`: the tenancy matrix (shared / isolated / off per
  service and tenant), refused at plan time where a shared service cannot
  isolate an external tenant; outputs the shared instance's hooks and each
  tenant's stamp spec.
- New `modules/postgres-group-roles`: `nb_<tenant>__<group>` login roles,
  created by SQL, members of `app_notebook` only.
- New `aws/tenant-data`: per tenant an IAM role for its own ServiceAccounts, a
  prefix of the shared bucket or a bucket of its own, and optionally its own
  database.
- `modules/workloads`: `auth.superadmin_group` (the Ray dashboard's default
  gate, a top-precedence Argo write rule, MLflow's and JupyterHub's admin
  group, the webapp's `APP_ADMIN_GROUP`); `auth.mlflow_mode = "oidc"` (the
  chart's mlflow-oidc-auth plugin with per-experiment permissions in the
  MLflow database, `mlflow_groups`, `mlflow_group_rules`, and the
  `mlflow-auth-sync` CronJob keeping service-account tokens in
  `mlflow-credentials` Secrets, itself authenticated by its projected
  ServiceAccount token -- `kubernetes_service_account_issuer` -- and made an
  MLflow admin by an init container; `mlflow_image` pins the server);
  `dagster_code_locations` (each with its own
  ServiceAccount, Secret and MLflow account); `jupyterhub_group_profiles`
  (per-group identity, DB role, directory, labels; membership re-checked at
  spawn) and, on OIDC, a hub that refreshes tokens and groups before each
  spawn (`jupyterhub_auth_refresh_seconds`), one-day logins
  (`jupyterhub_cookie_max_age_days`) and servers culled a day after start
  (`jupyterhub_server_max_age_seconds`, never by default on the other
  mechanisms); `ray_enable_autoscaler`
  (default on: workers now actually scale from 0) and `ray_head_num_cpus`;
  `network_policies.tenant` and `extra_peers`; `python_image`,
  `postgres_client_image`; `ray_head_start_params`; `mlflow_job_execution`
  (MLflow 3's server-side job runner and Huey consumers, over a GiB idle,
  can be turned off).
- `aws/eks-platform`: `enable_tailscale_dnsconfig` -- the operator's DNSConfig
  nameserver at a fixed ClusterIP and a CoreDNS stub zone, so pods resolve a
  tailnet-only issuer like browsers do.
- `examples/kind`: Keycloak behind Dex with tenants lab (internal) and acme
  (external), six users across every admin level, tenant stamps, MLflow on
  OIDC; `verify-tenants.sh` checks gates, Argo rules, delegated admins,
  MLflow permissions, Ray autoscaling, data scoping, the tenant fence, and the
  refusal of an invalid matrix. `enable_keycloak = false` keeps the smaller
  password-DB flow.
- `docs/tenancy.md`; `docs/auth.md` covers the user store, MLflow's own
  login, the tailnet-only issuer and the extended state map.

### Added: OSS auth -- `modules/dex` and `modules/workloads` `auth`

- New `modules/dex`: one Dex per cluster as the OIDC issuer every service
  trusts. Connectors (Google, GitHub, LDAP, SAML, generic OIDC) or a password
  DB for CI; `kubernetes` storage so environments register their own OAuth2
  clients as `OAuth2Client` CRs; optional Ingress.
- `modules/workloads` gains `var.auth` with three modes. `headers` (default:
  the private network authenticates), `oidc` and `none`; the webapp receives
  `AUTH_MODE` (plus `IDENTITY_HEADER` / `IDENTITY_GROUPS_HEADER` in `headers`
  mode) and accepts only that mode's identity source. In `oidc` mode: an
  `oauth2-proxy` per protected service (Dagster, MLflow, the Ray dashboard,
  optionally the webapp) with per-service `allowed_groups` / `allowed_emails`
  gates, host-only cookies refreshed every `session_refresh` (1h) and ending
  after `session_lifetime` (24h), and the private Ingress re-pointed at it;
  Argo Workflows on native SSO with `argo_rbac_rules` (name => `{ rule,
  access = read | write, precedence }`, one Role per level, no catch-all);
  JupyterHub's mechanism following `auth.mode`, against the same issuer, with
  `jupyterhub_allowed_groups`; the webapp handed `OIDC_*` env and a
  `SESSION_SECRET` to run its own login, or -- proxied -- `IDENTITY_JWT_*` to
  verify the proxy's ID token. Default-deny throughout: a proxied service
  must name groups, emails or `allowed_email_domains` (empty by default),
  Argo SSO needs at least one rule, JupyterHub on OIDC needs allowed users or
  groups or `jupyterhub_allow_all`. With `dex_namespace` the module registers
  every client it needs (generated secrets, Dex object names computed in
  HCL); without it, bring your own via `clients`. New output `auth`. The
  module now requires the `hashicorp/random` provider (`tofu init -upgrade`).
- `modules/workloads` `network_policies` (on by default): a NetworkPolicy per
  UI service admitting only its namespace, its client services (by the new
  `lab-platform.io/service` namespace label) and the ingress controller's
  namespaces (or, for a proxied service, only its proxy). Needs an enforcing
  CNI; `aws/eks-platform` gains `enable_network_policy` (the VPC CNI's policy
  agent, off by default).
- A public webapp Ingress is refused in `auth.mode = "headers"`;
  `examples/complete` switches to `none` when it is public.
- `jupyterhub_auth_mechanism` now defaults to null, meaning "follow
  `auth.mode`" (`oidc` in `oidc` mode, `dummy` otherwise).
- `modules/dex`: ID tokens last 1h (was 24h); connector secrets from
  `connector_env` / `connector_env_secret_name` via Dex's `$VAR` expansion;
  `client_admission`, a ValidatingAdmissionPolicy limiting restricted
  principals (a preview's CI) to `pr<N>-` clients. Requires the
  `gavinbunney/kubectl` provider.
- `docs/auth.md`: the design, the group model, the network fence, which auth
  state is global, stamped per environment, or branched with a preview (and
  why the webapp's sessions are hashed), and what `oidc` mode still needs
  before production use.

### Fixed: MLflow >= 3.5 behind any hostname

- MLflow 3.5 added DNS-rebinding protection that rejects every Host header it
  was not told about (only localhost and private IPs pass), so the UI answered
  `403 Invalid Host header` through the private Ingress while `/health` kept
  passing. `modules/workloads` now sets `MLFLOW_SERVER_ALLOWED_HOSTS` to the
  names it gives the server (in-cluster Service, private hostname, its
  oauth2-proxy, localhost) plus `mlflow_allowed_hosts` for any others.
- New `mlflow_workers` (default 2; the chart's default of 4 uvicorn processes
  idles at several hundred MiB).

### Changed: `examples/kind` object store is SeaweedFS

- MinIO's community edition was archived in April 2026 and receives no fixes,
  so the local data backend of `examples/kind` (and the `kind-smoke` local
  leg) is now [SeaweedFS](https://github.com/seaweedfs/seaweedfs) in its
  single-binary form. The identity contract is unchanged (static keys via
  `workload_identity_secret_env`); the example's inputs are backend-neutral
  (`s3_endpoint`, `s3_access_key`, `s3_secret_key`; `WITH_S3=0` skips it) and
  the pods carry `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` /
  `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required` so the AWS SDKs stay off the
  flexible-checksum uploads only AWS S3 itself is guaranteed to accept.

### Changed (breaking): portable workloads, `aws/` split along data and compute

Consumers pinned to the pre-split layout (`//modules/bootstrap`, ...) must
update paths and wiring; tag the first release carrying this as **0.2.0**.

- `modules/workloads` is now cloud-agnostic: it requires only the
  `kubernetes`/`helm`/`kubectl` providers and runs on EKS, kind, GKE, AKS or
  bare metal. Every AWS specific left it and comes back through four
  **contract inputs**:
  - `workload_identity` + `workload_identity_secret_env` (per service:
    ServiceAccount annotations for webhook identity, `env` +
    `projected_token` for web-identity federation, static `secret_env`);
  - `scheduling` (nodeSelector + tolerations per pod role);
  - `jupyterhub_shared_storage` (`nfs_server` for a static NFS PV, or
    `storage_class_name` for a dynamic RWX claim);
  - `webapp_public_ingress_class_name` / `_annotations` /
    `_tls_secret_name` (+ the `jupyterhub_public_*` twins) for the public edge.
  Removed inputs: `cluster_name`, `oidc_provider_arn`, `region`, `vpc_name`,
  `karpenter_node_iam_role_name`, `karpenter_node_pools`, `tags`,
  `*_bucket_policies`, `mlflow_artifact_bucket(_arn)` (now
  `mlflow_artifact_root`, an `s3://` URI), `webapp_acm_certificate_arn`,
  `*_route53_zone_id`, `enable_webapp_waf`, `webapp_waf_rate_limit`,
  `jupyterhub_ingress_scheme`, `jupyterhub_efs_prevent_destroy`, `vpc_id`,
  `private_subnets*`, `efs_subnet_cidr_octet_prefix`,
  `vpc_secondary_cidr_blocks`. Removed output: `jupyterhub_efs_id`. New
  outputs: `service_accounts`, `identity_secret_names`,
  `webapp_public_ingress`. New inputs: `ray_head_resources`,
  `ray_worker_resources`, `ray_worker_max_replicas`,
  `webapp_public_wait_for_load_balancer`.
- Public DNS records are no longer written by the module. Public Ingresses
  carry `external-dns.alpha.kubernetes.io/hostname`; `aws/eks-platform` gains
  `enable_external_dns` + `external_dns_route53_zone_arns` (+
  `external_dns_domain_filters`) to publish them.
- The JupyterHub single-user ServiceAccount is now `jupyterhub-single-user`
  (was `<cluster>-<prefix>jupyterhub-single-user`); the shared-volume claims
  are `jupyterhub-home` / `jupyterhub-shared` (were `efs-persist` /
  `efs-persist-shared`), and their PersistentVolumes are namespaced so two
  environments on one cluster can each bind their own. Data on an NFS export
  is untouched by the rename (both claims mount the same export root).
- MLflow's Postgres credentials are passed to the chart directly (its
  `backendStore` has no existing-secret hook; the previous `existingSecret`
  keys were silently ignored and the chart failed to render), and the invalid
  `runLauncher.config.k8sRunLauncher.serviceAccountName` was dropped from the
  Dagster values (run pods use `global.serviceAccountName`). Both were latent
  apply-time failures found by rendering the module's values against the
  charts' schemas.
- Chart defaults bumped from a live run on kind: `mlflow_chart_version`
  0.7.19 -> 1.11.7 (MLflow 3; the 0.7 image's libpq predates SCRAM, so it
  could not authenticate to Postgres 14+ or Neon) and `dagster_chart_version`
  1.13.14 -> 1.13.23 (first release with arm64 images; earlier ones cannot
  run on Apple Silicon kind or Graviton nodes).
- With no `dagster_user_code_image`, the module now deploys its own
  hello-world code location (`helm-defaults/dagster/hello_repo.py`, mounted
  from a ConfigMap into the stock `dagster-k8s` image) instead of the chart's
  example deployment, whose image no longer ships the file it points at.
- The persistent RayCluster is now named `<name_prefix><ray_cluster_release_name>`
  (`fullnameOverride`); the chart used to append `-kuberay`, so the module's
  Ray dashboard Service selector never matched the head pod. Existing
  clusters are recreated under the new name.
- AWS-only modules moved from `modules/` to `aws/`: `bootstrap`, `network`,
  `eks-platform`, `s3-bucket`, `preview-storage`, `iceberg-branches`,
  `data-access`. `modules/` keeps `workloads` and `neon-branches`.
- New `aws/data-adapter` (data axis): per-service IAM roles trusting any IAM
  OIDC provider (the EKS cluster's, or a foreign cluster's), attaching bucket /
  S3 Tables / ECR policies, emitted as `workload_identity` with `binding =
  "webhook"` (IRSA) or `"projected"` (web identity from any cluster). Role
  names keep the old pattern so existing roles can be state-moved.
- New `aws/oidc-provider`: registers a non-EKS cluster's issuer with IAM;
  `host_discovery` publishes the discovery document + JWKS to S3 for clusters
  AWS cannot reach (kind, on-prem).
- New `aws/compute-adapter` (compute axis): the EFS filesystem behind
  JupyterHub (guarded), the ALB/ACM/WAF annotation set, and the Karpenter
  NodePools (moved here from `workloads`) with `node_pool_roles` turning them
  into the `scheduling` contract.
- New examples: `examples/kind` (local compute + local data: SeaweedFS +
  Postgres, static credentials, free) and `examples/kind-aws-data` (local
  compute + AWS data: hosted issuer + projected-token roles, no static keys).
  New `kind-smoke` workflow runs the first on every PR touching the module and
  the second when `ENABLE_KIND_AWS_DATA` is set.
- Repository renamed `terraform-aws-lab-platform` -> **`lab-platform`**: a
  portable `modules/` core with a backend directory per cloud is neither
  Terraform-only nor AWS-only, and the registry naming convention bought
  nothing for modules consumed by `github.com/...//path` refs. GitHub
  redirects the old name (git, module sources, reusable-workflow `uses:`);
  consumers should still update their `//` sources and `uses:` lines.
- `modules/neon-branches` branches per **(project, parent branch)** instead
  of per source: databases that live in one project now share one branch and
  one compute per preview (the same snapshot for all of them) instead of one
  branch each; sources in separate projects are unchanged, including branch
  names. New `branches` output; `branch_names` stays keyed by source. A live
  preview whose sources share a project is recreated once on upgrade (its
  branches are ephemeral anyway).
- **Stamp or share**: each stateful service is either stamped into an
  environment (`enable_x`) or shared from another one through a new override
  -- `mlflow_tracking_uri`, `dagster_webserver_url`, `argo_server_url` -- fed
  from that environment's new `in_cluster_urls` output. Either way pods see
  `MLFLOW_TRACKING_URI` / `DAGSTER_WEBSERVER_URL` / `ARGO_SERVER_URL`.
  `examples/preview` exposes it as `preview_profile = "full" | "app"`
  (app-only previews: the webapp on its own database branch, prod's
  pipelines); the consequences are documented in the workloads README and
  docs/preview-environments.md.
- Argo Workflows is now **per environment**, like Dagster and MLflow:
  `modules/workloads` `enable_argo_workflows` deploys a namespace-scoped
  controller + server (chart 2.0.6 / Argo v4.1.3) in `<prefix>argo`, the
  `argo-workflow` ServiceAccount (identity contract key `argo`, now in that
  namespace rather than the Ray namespace), an optional **workflow archive**
  on the environment's Postgres (`enable_argo_workflow_archive` + `argo_db_*`;
  a Neon branch for a preview), a `scheduling` role `argo`, and a private
  Ingress at `<prefix>argo` (`argo_private_url`). `aws/eks-platform`
  `enable_argo_workflows` now installs only the cluster-scoped CRDs, from the
  upstream release at `argo_workflows_version` (keep it equal to the chart's
  appVersion). The server Service is `ClusterIP` in `server` auth mode; the
  previous platform-level install had `serviceType: LoadBalancer`, which made
  the AWS Load Balancer Controller allocate an NLB and security groups outside
  Terraform state that orphaned on destroy and held the VPC open. No chart in
  the family asks for a `LoadBalancer` Service any more (eks-platform README,
  "Teardown is closed-loop"). Submit workflows into the argo namespace; the
  example workflow creates its RayJob in the Ray namespace cross-namespace.

Migration for an existing deployment (`examples/*` show the wiring):

1. Update module sources (`//modules/x` -> `//aws/x` for the moved modules)
   and add `aws/data-adapter` + `aws/compute-adapter` next to `workloads`,
   feeding their outputs to the contract inputs.
2. `tofu state mv` the resources that changed owner so nothing is recreated:
   IRSA roles `module.workloads.module.<svc>_irsa[0]` ->
   `module.<data>.module.role["<svc>"]`; `aws_iam_policy.ecr_read` /
   `mlflow_s3` -> the data adapter; `aws_efs_file_system.jupyterhub`,
   `aws_security_group.efs`, `aws_efs_mount_target.jupyterhub`,
   `aws_wafv2_web_acl.webapp` and its log group / logging config,
   `helm_release.karpenter_node_pools` -> the compute adapter. Roles and the
   WAF ACL may also simply be recreated (no data); the EFS filesystem holds
   home directories and its `prevent_destroy` guard refuses to recreate it,
   so move it.
3. `aws_route53_record.*` and `data.aws_lb.*` are removed; enable
   `external_dns` on the platform (or keep your own record) before applying.
4. The JupyterHub SA rename and claim renames recreate those Kubernetes
   objects; do it while no notebook servers are running.

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
  ([tether](https://github.com/Rosebud-Biosciences/tether)) may fork the production stores
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
- Reusable `preview-up` / `preview-down` / `nightly-sweep` accept an optional
  `modules_git_token` secret and, when set, `git config url...insteadOf` it
  before `tofu init`, so a consumer can fetch `github.com/...` module sources
  from this repo while it is private (a runner's `GITHUB_TOKEN` reaches only
  its own repository). Unset it once the repo is public.
- Module sources and reusable-workflow references in the docs name the
  upstream repo, `github.com/Rosebud-Biosciences/lab-platform`,
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
  literal-only `prevent_destroy` cannot express any of this.

### Changed vs. the production stack it was extracted from

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
- Helm provider 3 + `eks-blueprints-addons` 1.24.3 (that stack is stuck on
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

[Unreleased]: https://github.com/Rosebud-Biosciences/lab-platform/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/Rosebud-Biosciences/lab-platform/compare/76a2d7b5793ae5447eacf8bcc28ea349da0377c4...v0.3.0
[0.2.0]: https://github.com/Rosebud-Biosciences/lab-platform/tree/76a2d7b5793ae5447eacf8bcc28ea349da0377c4
