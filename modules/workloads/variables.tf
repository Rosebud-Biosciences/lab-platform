# ------------------------------------------------------------------------------
# NAMING
# ------------------------------------------------------------------------------

variable "environment" {
  description = "Environment name (prod / dev / preview), published to pipelines as PIPELINE_ENV"
  type        = string
  default     = "dev"
}

variable "name_prefix" {
  description = <<-EOT
    Prefix applied to every namespace, Helm release, and private hostname so
    multiple workload environments can share one cluster. Empty ("")
    reproduces the base names. A preview uses e.g. "pr123-".

    Backend adapters derive their own resource names (IAM roles, NodePools,
    filesystems) from the same prefix, so it is validated against the tightest
    downstream limits -- a Kubernetes namespace (63), an AWS IAM role name
    (64), an ALB name (32) -- rather than only what this module creates.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^([a-z0-9][a-z0-9-]*)?$", var.name_prefix))
    error_message = "name_prefix must be empty or lowercase alphanumeric/dashes starting with an alphanumeric."
  }

  validation {
    # 21 leaves headroom under every downstream limit once suffixes like
    # "<cluster>-<prefix>argo-workflow-sa" (IAM 64) or an ALB name (32) are added.
    condition     = length(var.name_prefix) <= 21
    error_message = "name_prefix must be <= 21 characters to stay within cloud/Kubernetes name limits after suffixes are appended."
  }
}

# ------------------------------------------------------------------------------
# CONTRACT: IDENTITY
#
# How each service's pods obtain credentials for the data backend. Keyed by
# service: "webapp", "dagster", "ray", "argo", "mlflow", "jupyterhub". Every
# key is optional; a missing service gets no identity at all.
#
# Three mechanisms, all expressed through the same object, so any backend can
# be paired with any cluster:
#   service_account_annotations  webhook-injected identity when compute and
#                                data are in the same cloud: EKS IRSA
#                                ("eks.amazonaws.com/role-arn"), GKE Workload
#                                Identity, AKS Workload Identity.
#   projected_token + env        web-identity federation from ANY cluster to a
#                                cloud that trusts its OIDC issuer: the pod
#                                mounts a projected ServiceAccount token and
#                                the SDK reads AWS_ROLE_ARN +
#                                AWS_WEB_IDENTITY_TOKEN_FILE (or the GCP/Azure
#                                equivalents) from env. No mutating webhook is
#                                needed because this module mounts the token.
#   secret_env                   static credentials (an S3-compatible store, an IAM user) in a
#                                Kubernetes Secret, see
#                                workload_identity_secret_env.
#
# The ServiceAccount an adapter must trust for each service is fixed by this
# module -- see output.service_accounts and the README "Identity contract".
# ------------------------------------------------------------------------------

variable "workload_identity" {
  description = <<-EOT
    Per-service identity (non-secret part). Keys: webapp, dagster, ray, argo,
    mlflow, jupyterhub. For each: `service_account_annotations` stamped on the
    service's ServiceAccount; `env` plain variables the pods receive (e.g.
    AWS_REGION, AWS_ROLE_ARN, AWS_WEB_IDENTITY_TOKEN_FILE, AWS_ENDPOINT_URL);
    `projected_token` mounts a projected ServiceAccount token at
    <mount_path>/<file_name> with the given audience for web-identity
    federation. Produced by a backend adapter (aws/data-adapter) or written by
    hand. For "ray", `env` also lands in the analytics-config ConfigMap so
    RayJobs launched by user code can envFrom it.
  EOT
  type = map(object({
    service_account_annotations = optional(map(string), {})
    env                         = optional(map(string), {})
    projected_token = optional(object({
      audience           = string
      mount_path         = optional(string, "/var/run/secrets/workload-identity")
      file_name          = optional(string, "token")
      expiration_seconds = optional(number, 3600)
    }))
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.workload_identity) : contains(["webapp", "dagster", "ray", "argo", "mlflow", "jupyterhub"], k)])
    error_message = "workload_identity keys must be among: webapp, dagster, ray, argo, mlflow, jupyterhub."
  }
}

variable "workload_identity_secret_env" {
  description = <<-EOT
    Per-service SECRET environment variables (same keys as workload_identity),
    delivered through a Kubernetes Secret named <service>-identity-env in the
    service's namespace and injected with envFrom. This is the static-credential
    path (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY for an S3-compatible store or an IAM user).
    Keys must be known at plan time. The Secret exists for every enabled
    service, empty when nothing is set, so charts can reference it
    unconditionally.
  EOT
  type        = map(map(string))
  default     = {}
  sensitive   = true
}

# ------------------------------------------------------------------------------
# CONTRACT: SCHEDULING
# ------------------------------------------------------------------------------

variable "scheduling" {
  description = <<-EOT
    Node placement per pod role: webapp, dagster (webserver, daemon, user code,
    run pods), mlflow, argo (controller + server), jupyterhub (hub + proxy),
    jupyterhub_singleuser, ray_head, ray_worker. Each gives a nodeSelector and tolerations. Empty
    (the default) schedules anywhere, which is what a laptop kind cluster
    wants; aws/compute-adapter emits `karpenter.sh/nodepool` selectors and the
    matching tolerations for the NodePools it creates. Unknown keys are ignored.
  EOT
  type = map(object({
    node_selector = optional(map(string), {})
    tolerations = optional(list(object({
      key      = optional(string)
      operator = optional(string, "Equal")
      value    = optional(string)
      effect   = optional(string)
    })), [])
  }))
  default = {}
}

# ------------------------------------------------------------------------------
# FEATURE TOGGLES
# ------------------------------------------------------------------------------

variable "enable_webapp" {
  description = "Deploy the generic web application (Deployment + Service + ServiceAccount)"
  type        = bool
  default     = false
}

variable "enable_jupyterhub" {
  description = "Deploy JupyterHub (namespace, shared RWX volume, ServiceAccount, Helm release, optional public ingress). Requires jupyterhub_shared_storage."
  type        = bool
  default     = false
}

variable "enable_dagster" {
  description = "Deploy Dagster (requires enable_ray = true)"
  type        = bool
  default     = false
}

variable "enable_ray" {
  description = "Deploy the Ray namespace + ServiceAccount (the KubeRay operator is a cluster prerequisite, see README)"
  type        = bool
  default     = false
}

variable "enable_argo_workflows" {
  description = "Deploy Argo Workflows for this environment: namespace, workflow ServiceAccount + RBAC (may manage RayJobs in the Ray namespace), a namespace-scoped controller + server, optional workflow archive. The CRDs are a cluster prerequisite (aws/eks-platform enable_argo_workflows)."
  type        = bool
  default     = false
}

variable "enable_mlflow" {
  description = "Deploy the MLflow tracking server"
  type        = bool
  default     = false
}

variable "enable_ray_cluster" {
  description = "Deploy a persistent Ray cluster (previews often want their own dedicated cluster)"
  type        = bool
  default     = false
}

variable "enable_private_ingress" {
  description = "Create private Ingresses for the workload UIs (e.g. via the Tailscale operator's IngressClass)"
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# STAMP OR SHARE
#
# Each stateful service (MLflow, Dagster, Argo) is either stamped into this
# environment (enable_x = true) or shared from another one by passing that
# environment's in-cluster URL here (its `in_cluster_urls` output) with
# enable_x = false. The URL reaches every pod that runs code as
# MLFLOW_TRACKING_URI / DAGSTER_WEBSERVER_URL / ARGO_SERVER_URL either way.
# Sharing trades isolation for cost and speed; the consequences are spelled
# out in README "Stamp or share".
# ------------------------------------------------------------------------------

variable "mlflow_tracking_uri" {
  description = "Use another environment's MLflow instead of running one here (enable_mlflow = false): its in-cluster URL, e.g. http://mlflow.mlflow.svc.cluster.local:80. Experiments and artifacts then land in THAT environment's store."
  type        = string
  default     = ""

  validation {
    condition     = !(var.enable_mlflow && var.mlflow_tracking_uri != "")
    error_message = "mlflow_tracking_uri is for sharing another environment's MLflow; unset it or set enable_mlflow = false."
  }
}

variable "dagster_webserver_url" {
  description = "Use another environment's Dagster instead of running one here (enable_dagster = false): its in-cluster webserver URL. Runs the app triggers there use THAT environment's code location, database and data -- an app-only preview, not a pipeline one."
  type        = string
  default     = ""

  validation {
    condition     = !(var.enable_dagster && var.dagster_webserver_url != "")
    error_message = "dagster_webserver_url is for sharing another environment's Dagster; unset it or set enable_dagster = false."
  }
}

variable "argo_server_url" {
  description = "Use another environment's Argo server instead of running one here (enable_argo_workflows = false): its in-cluster URL. Workflows submitted through it run in THAT environment's namespace with its identity and data."
  type        = string
  default     = ""

  validation {
    condition     = !(var.enable_argo_workflows && var.argo_server_url != "")
    error_message = "argo_server_url is for sharing another environment's Argo; unset it or set enable_argo_workflows = false."
  }
}

# ------------------------------------------------------------------------------
# PRIVATE INGRESS (defaults to the Tailscale operator's IngressClass)
# ------------------------------------------------------------------------------

variable "private_ingress_class_name" {
  description = "IngressClass backing the private workload Ingresses. 'tailscale' uses the operator (a cluster prerequisite); set to your own private ingress controller to bring your own."
  type        = string
  default     = "tailscale"
}

variable "private_ingress_hostname_prefix" {
  description = "Prefix for the private hostnames (keeps names unique per env). Usually equal to name_prefix."
  type        = string
  default     = ""
}

variable "private_ingress_annotations" {
  description = <<-EOT
    Annotations for the private Ingresses, keyed by service ("dagster",
    "mlflow", "webapp", "ray", "argo"); the special key "*" applies to every service,
    with per-service entries winning on conflict.

    The flagship use is Tailscale ACL scoping. The operator tags every proxy
    device tag:k8s by default, so one grant governs all UIs; per-service
    device tags let the tailnet policy grant them individually -- ops UIs to
    the platform group, the webapp (which authenticates users itself) to
    every member:

      private_ingress_annotations = {
        dagster = { "tailscale.com/tags" = "tag:svc-dagster" }
        mlflow  = { "tailscale.com/tags" = "tag:svc-mlflow" }
        ray     = { "tailscale.com/tags" = "tag:svc-ray" }
        webapp  = { "tailscale.com/tags" = "tag:svc-webapp" }
      }

    A preview stack instead collapses to one tag, so a single grant covers
    the whole environment:

      private_ingress_annotations = { "*" = { "tailscale.com/tags" = "tag:svc-preview" } }

    Each tag needs the operator's tag as an owner in the policy's tagOwners
    ("tag:svc-preview": ["tag:k8s-operator"]), applied BEFORE any Ingress
    uses it, or the operator cannot mint the device.

    Tags apply only at provisioning. The operator reads tailscale.com/tags
    when it first creates a proxy device and never again, so editing the
    annotation on a live Ingress changes nothing on the tailnet -- and since
    the ACL grants by tag, that device silently falls out of the new grant.
    Whenever a tag changes (including the first time you set one on an
    existing environment), recreate the Ingress so a fresh device is minted:

      tofu apply -replace='module.workloads.kubernetes_ingress_v1.webapp_private[0]'

    The hostname is unaffected; the service blips while the new proxy pod
    starts. Only ProxyGroup-mode Ingresses reconcile tag changes in place.
  EOT
  type        = map(map(string))
  default     = {}
}

variable "private_ingress_dns_suffix" {
  description = "DNS suffix for the private hostnames (e.g. your MagicDNS tailnet suffix <tailnet>.ts.net). Used to build output URLs and, in auth mode \"oidc\", the OAuth redirect URLs."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# AUTH: who may open which UI, and how the webapp learns who is calling
# ------------------------------------------------------------------------------

variable "auth" {
  description = <<-EOT
    How this environment's UIs are gated and how the webapp learns the
    caller's identity. Three modes:

    "headers" (default) -- the private network is the authentication. Every
      request arrives through a proxy that has already identified the caller
      (the Tailscale operator's Ingress sets Tailscale-User-Login); nothing is
      deployed here. identity_header / identity_groups_header name the headers
      the webapp should trust (its IDENTITY_HEADER / IDENTITY_GROUPS_HEADER
      env). Only meaningful when the proxy is the sole route to the pods.

    "oidc" -- OpenID Connect against issuer_url, portable to any network and
      any IngressClass. Services that cannot authenticate on their own
      (Dagster, MLflow, the Ray dashboard, optionally the webapp) get an
      oauth2-proxy in front of them, one per service, that runs the login
      and hands the upstream X-Forwarded-Email / -User / -Groups; the private
      Ingress is re-pointed at the proxy. Argo Workflows uses its native SSO
      (with group rbac-rules), JupyterHub's oidc mechanism points at the same
      issuer, and the webapp gets OIDC_* env to run its own login (its
      users/sessions then live in ITS database and branch with it).

      dex_namespace set: the issuer is modules/dex and this module registers
      the environment's clients as OAuth2Client CRs there, with generated
      secrets -- no static redirect-URI list anywhere, so previews mint their
      own. Empty: bring your own clients, keyed oauth2-proxy / argo /
      jupyterhub / webapp, registered at the issuer by hand with the redirect
      URLs output.auth reports.

      Default-deny. protect maps each proxied service to its gate:
      allowed_groups (the groups_claim must contain one), allowed_emails (an
      explicit list), or -- neither set -- allowed_email_domains, which is
      empty by default so an ungated service fails the plan. ["*"] admits
      everyone the issuer admits: choose it only when its connectors are
      already restricted (a Dex GitHub connector without `orgs` admits all
      of GitHub). A service absent from protect is not proxied.

      argo_rbac_rules maps a name to { rule, access = "read" | "write",
      precedence }: rule is an Argo rbac-rule expression (e.g.
      "'platform' in groups"), access picks the Role its ServiceAccount is
      bound to, and Argo tries rules from the numerically highest precedence
      down, so broad rules get low numbers. A user matching no rule gets no
      Argo, and Argo in this mode requires at least one rule.

      superadmin_group (e.g. "/platform-admins") is the platform's
      superadmins everywhere unless a service is told otherwise: the Ray
      dashboard's gate when protect.ray names nobody, an Argo "write" rule at
      precedence 100 (added to argo_rbac_rules), MLflow's and JupyterHub's
      admin group, and the webapp's APP_ADMIN_GROUP.

      mlflow_mode: "proxy" (an oauth2-proxy gate like Dagster's) or "oidc"
      (MLflow's own login through the mlflow-oidc-auth plugin, with per-
      experiment permissions): mlflow_groups may log in, superadmin_group
      administers, everyone else has NO_PERMISSIONS until a permission or a
      mlflow_group_rules pattern (group, experiment-name regex, READ | EDIT |
      MANAGE) grants it. Permissions live in the MLflow database (schema
      mlflow_auth), so they branch with its experiments.

      Sessions: proxy cookies are host-only and re-validated every
      session_refresh (so a revoked group stops working then), ending after
      session_lifetime. Cross-service single sign-on therefore comes from the
      issuer's own session (Dex has none in any release yet; an upstream IdP
      such as Google or Keycloak keeps one), not from a shared cookie domain.

    "none" -- nothing gates the UIs and the webapp identifies nobody.

    The webapp receives AUTH_MODE and accepts only that mode's identity
    source; a public webapp Ingress is refused in "headers" mode, where any
    internet client could send the trusted header.
  EOT
  type = object({
    mode                   = optional(string, "headers")
    identity_header        = optional(string, "Tailscale-User-Login")
    identity_groups_header = optional(string, "")
    issuer_url             = optional(string, "")
    dex_namespace          = optional(string, "")
    clients = optional(map(object({
      client_id     = string
      client_secret = string
    })), {})
    protect = optional(map(object({
      allowed_groups   = optional(list(string), [])
      allowed_emails   = optional(list(string), [])
      skip_auth_routes = optional(list(string), [])
    })), { dagster = {}, mlflow = {}, ray = {} })
    allowed_email_domains = optional(list(string), [])
    scopes                = optional(list(string), ["openid", "email", "profile", "groups"])
    groups_claim          = optional(string, "groups")
    argo_rbac_rules = optional(map(object({
      rule       = string
      access     = optional(string, "read")
      precedence = optional(number, 0)
    })), {})
    jupyterhub_allowed_groups = optional(list(string), [])
    superadmin_group          = optional(string, "")
    mlflow_mode               = optional(string, "proxy")
    mlflow_groups             = optional(list(string), [])
    mlflow_group_rules = optional(list(object({
      group      = string
      regex      = string
      permission = optional(string, "READ")
      priority   = optional(number, 10)
    })), [])
    session_refresh  = optional(string, "1h")
    session_lifetime = optional(string, "24h")
    cookie_secure    = optional(bool, true)
    external_scheme  = optional(string, "https")
  })
  default = {}

  validation {
    condition     = contains(["headers", "oidc", "none"], var.auth.mode)
    error_message = "auth.mode must be \"headers\", \"oidc\" or \"none\"."
  }
  validation {
    condition     = var.auth.mode != "oidc" || can(regex("^https?://", var.auth.issuer_url))
    error_message = "auth.issuer_url (an http(s) URL) is required in mode \"oidc\"."
  }
  validation {
    condition     = alltrue([for svc in keys(var.auth.protect) : contains(["dagster", "mlflow", "ray", "webapp"], svc)])
    error_message = "auth.protect keys must be among dagster, mlflow, ray, webapp (Argo and JupyterHub authenticate natively)."
  }
  validation {
    condition     = contains(["http", "https"], var.auth.external_scheme)
    error_message = "auth.external_scheme must be http or https."
  }
  validation {
    condition     = contains(["proxy", "oidc"], var.auth.mlflow_mode)
    error_message = "auth.mlflow_mode must be \"proxy\" or \"oidc\"."
  }
  validation {
    condition     = alltrue([for r in var.auth.mlflow_group_rules : contains(["READ", "EDIT", "MANAGE", "NO_PERMISSIONS"], r.permission)])
    error_message = "auth.mlflow_group_rules[*].permission must be READ, EDIT, MANAGE or NO_PERMISSIONS."
  }
  validation {
    condition     = alltrue([for r in values(var.auth.argo_rbac_rules) : contains(["read", "write"], r.access)])
    error_message = "auth.argo_rbac_rules[*].access must be \"read\" or \"write\"."
  }
  validation {
    condition     = alltrue([for d in [var.auth.session_refresh, var.auth.session_lifetime] : can(regex("^[0-9]+(s|m|h)$", d))])
    error_message = "auth.session_refresh and auth.session_lifetime are durations like \"1h\" or \"30m\"."
  }
}

variable "mlflow_service_accounts" {
  description = <<-EOT
    auth.mlflow_mode = "oidc": MLflow service accounts for in-cluster clients,
    keyed by account name, merged over the ones the module derives (one per
    enabled client service of this environment -- svc-<prefix>dagster,
    -ray, -webapp, EDIT on every experiment -- and one per Dagster code
    location with an mlflow_account). mlflow-auth-sync creates each one,
    keeps its token (renewed a month before MLflow's one-year cap) in each of
    its secrets (MLFLOW_TRACKING_USERNAME / MLFLOW_TRACKING_PASSWORD), and
    grants its experiment_patterns. A secret outside this environment must be
    pre-created, and writable by this MLflow's mlflow-auth-sync
    ServiceAccount, by the environment that owns its namespace
    (mlflow_client_credentials there).
  EOT
  type = map(object({
    secrets = list(object({
      namespace = string
      name      = optional(string, "mlflow-credentials")
    }))
    experiment_patterns = optional(list(object({
      regex      = string
      permission = optional(string, "EDIT")
      priority   = optional(number, 100)
    })), [])
  }))
  default = {}
}

variable "mlflow_job_execution" {
  description = "Run MLflow's server-side job execution (MLflow >= 3.x: a job runner and Huey consumers for GenAI jobs, about 200 MiB each). Off saves over a GiB on a tracking server that runs none."
  type        = bool
  default     = true
}

variable "mlflow_client_credentials" {
  description = "Give this environment's MLflow clients (Dagster, Ray, the webapp) an mlflow-credentials Secret through envFrom, filled by an MLflow's mlflow-auth-sync. Null: on when this environment runs MLflow with auth.mlflow_mode = \"oidc\". Set it on stamps whose clients use a shared MLflow on OIDC, with mlflow_auth_sync_namespace naming that MLflow's namespace."
  type        = bool
  default     = null
}

variable "mlflow_auth_sync_namespace" {
  description = "Namespace of the mlflow-auth-sync ServiceAccount allowed to fill this environment's mlflow-credentials Secrets; empty = this environment's MLflow namespace"
  type        = string
  default     = ""
}

variable "kubernetes_service_account_issuer" {
  description = "The cluster's ServiceAccount token issuer (`kubectl get --raw /.well-known/openid-configuration`): on EKS https://<aws/eks-platform's oidc_provider>, on a cluster started with --service-account-issuer that URL (examples/kind-aws-data), otherwise the default. MLflow on OIDC accepts mlflow-auth-sync's projected token from it."
  type        = string
  default     = "https://kubernetes.default.svc.cluster.local"
}

variable "mlflow_auth_sync_schedule" {
  description = "Cron schedule of mlflow-auth-sync"
  type        = string
  default     = "*/15 * * * *"
}

variable "python_image" {
  description = "Image with a Python 3 standard library, for small platform jobs (mlflow-auth-sync)"
  type        = string
  default     = "python:3.14-alpine"
}

variable "postgres_client_image" {
  description = "Image with psql, for schema set-up (MLflow's mlflow_auth schema)"
  type        = string
  default     = "postgres:17-alpine"
}

variable "network_policies" {
  description = <<-EOT
    Fence each UI service so its gate is the only way in (netpol.tf).
    ingress_namespaces: where the ingress controller's proxies run -- the
    Tailscale operator's (default "tailscale"), ingress-nginx's, ... -- the
    only namespaces allowed to reach a login proxy, or a service that has
    none. clients: per service, which other services (by the
    lab-platform.io/service namespace label, any environment) may call it
    directly; defaults: dagster <- webapp; mlflow <- webapp, dagster, ray,
    argo, jupyterhub; ray <- dagster, argo; argo <- webapp; webapp <- none.
    extra_namespaces: per service, other namespaces by name (default: ray <-
    kuberay-system). tenant (a tenant's stamp, modules/tenancy): the
    namespaces also carry lab-platform.io/tenant = <tenant>, and clients
    match only namespaces of the same tenant. extra_peers: per service, more
    callers as namespace + pod label selectors (e.g. the platform's
    JupyterHub pods labelled with this tenant). Policies are inert unless the CNI enforces them (kind's
    kindnet does; EKS needs aws/eks-platform enable_network_policy).
  EOT
  type = object({
    enabled            = optional(bool, true)
    ingress_namespaces = optional(list(string), ["tailscale"])
    clients            = optional(map(list(string)), {})
    extra_namespaces   = optional(map(list(string)), {})
    tenant             = optional(string, "")
    extra_peers = optional(map(list(object({
      namespace_labels = optional(map(string), {})
      pod_labels       = optional(map(string), {})
    }))), {})
  })
  default = {}

  validation {
    condition     = alltrue([for svc in concat(keys(var.network_policies.clients), keys(var.network_policies.extra_namespaces)) : contains(["webapp", "dagster", "mlflow", "ray", "argo"], svc)])
    error_message = "network_policies.clients / extra_namespaces keys must be among webapp, dagster, mlflow, ray, argo."
  }
}

variable "oauth2_proxy_image" {
  description = "oauth2-proxy image for the per-service login proxies (auth mode \"oidc\"); a pinned tag, bumped like the chart versions"
  type        = string
  default     = "quay.io/oauth2-proxy/oauth2-proxy:v7.15.4"
}

# ------------------------------------------------------------------------------
# DATABASE / SECRETS (connection values are always supplied by the caller)
# ------------------------------------------------------------------------------

variable "database_url" {
  description = "Application database URL, published as the DATABASE_URL secret key for services that use it"
  type        = string
  default     = ""
  sensitive   = true
}

variable "dagster_db_host" {
  description = "Dagster metadata Postgres host"
  type        = string
  default     = ""
}
variable "dagster_db_name" {
  description = "Dagster metadata Postgres database name"
  type        = string
  default     = ""
}
variable "dagster_db_user" {
  description = "Dagster metadata Postgres user"
  type        = string
  default     = ""
}
variable "dagster_db_password" {
  description = "Dagster metadata Postgres password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mlflow_db_host" {
  description = "MLflow tracking Postgres host"
  type        = string
  default     = ""
}
variable "mlflow_db_name" {
  description = "MLflow tracking Postgres database name"
  type        = string
  default     = ""
}
variable "mlflow_db_user" {
  description = "MLflow tracking Postgres user"
  type        = string
  default     = ""
}
variable "mlflow_db_password" {
  description = "MLflow tracking Postgres password"
  type        = string
  default     = ""
  sensitive   = true
}

# ------------------------------------------------------------------------------
# WEBAPP
# ------------------------------------------------------------------------------

variable "webapp_app_name" {
  description = "Name used for the webapp namespace/Service/Deployment (auto-prefixed)"
  type        = string
  default     = "webapp"
}

variable "webapp_image" {
  description = "Full container image reference for the webapp (required when enable_webapp is true)"
  type        = string
  default     = ""
}

variable "webapp_container_port" {
  description = "Container port the webapp listens on"
  type        = number
  default     = 8080
}

variable "webapp_replicas" {
  description = "Replica count for the webapp Deployment (ignored once the public HPA is enabled)"
  type        = number
  default     = 1
}

variable "webapp_env" {
  description = "Plain (non-secret) environment variables for the webapp container"
  type        = map(string)
  default     = {}
}

variable "webapp_secret_env" {
  description = "Secret environment variables for the webapp container (stored in a Kubernetes Secret and injected via envFrom)"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "webapp_health_check_path" {
  description = "HTTP path used for the webapp readiness/liveness probes (adapters reuse it for load-balancer health checks)"
  type        = string
  default     = "/"
}

variable "webapp_cpu_request" {
  description = "CPU request for the webapp container (also the HPA scaling baseline)"
  type        = string
  default     = "100m"
}

variable "webapp_memory_request" {
  description = "Memory request for the webapp container"
  type        = string
  default     = "512Mi"
}

variable "webapp_memory_limit" {
  description = "Memory limit for the webapp container"
  type        = string
  default     = "1Gi"
}

variable "webapp_ignore_image_changes" {
  description = "Ignore changes to the webapp image so an external CI (kubectl set image) owns the running tag. Also ignores replica count so it does not fight the HPA."
  type        = bool
  default     = false
}

variable "wait_for_rollouts" {
  description = "Wait for the webapp's rollout and Dagster's release to become ready before an apply succeeds. Turn it off where an external deploy owns those images and they may not exist yet (the first apply of a stack whose CI pushes them): the apply then only submits them."
  type        = bool
  default     = true
}

variable "webapp_session_affinity_seconds" {
  description = "ClientIP session affinity timeout on the webapp Service (0 disables). Needed for stateful single-pod sessions routed through the Service (e.g. private ingress)."
  type        = number
  default     = 0

  validation {
    condition     = var.webapp_session_affinity_seconds >= 0 && var.webapp_session_affinity_seconds <= 86400
    error_message = "webapp_session_affinity_seconds must be 0..86400 (the Service sessionAffinity clientIP ceiling)."
  }
}

# --- Public (internet-facing) ingress + autoscaling ---------------------------
#
# CONTRACT: the class and annotations come from a backend adapter
# (aws/compute-adapter: "alb" + ACM certificate + WAF ACL annotations) or from
# whatever ingress controller the cluster runs (ingress-nginx + cert-manager).

variable "enable_webapp_public_ingress" {
  description = "Create an internet-facing Ingress for the webapp (plus HPA and PodDisruptionBudget). Requires webapp_public_ingress_class_name."
  type        = bool
  default     = false
}

variable "webapp_public_host" {
  description = "Public hostname the Ingress serves. Also stamped as external-dns.alpha.kubernetes.io/hostname so external-dns (if installed) publishes the record."
  type        = string
  default     = ""
}

variable "webapp_public_ingress_class_name" {
  description = "IngressClass for the public webapp Ingress ('alb' from aws/compute-adapter, 'nginx', ...). Required when enable_webapp_public_ingress is true."
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_webapp_public_ingress || var.webapp_public_ingress_class_name != ""
    error_message = "webapp_public_ingress_class_name is required when enable_webapp_public_ingress is true."
  }
}

variable "webapp_public_ingress_annotations" {
  description = "Annotations for the public webapp Ingress (aws/compute-adapter emits the alb.ingress.kubernetes.io/* set; cert-manager users add cert-manager.io/cluster-issuer)."
  type        = map(string)
  default     = {}
}

variable "webapp_public_tls_secret_name" {
  description = "TLS Secret for the public webapp Ingress (e.g. issued by cert-manager). Empty adds no tls block, which is right for TLS terminated at a cloud load balancer via annotations."
  type        = string
  default     = ""
}

variable "webapp_public_wait_for_load_balancer" {
  description = "Block the apply until the Ingress reports a load-balancer address, surfacing controller errors at apply time. Set false on clusters whose ingress controller never populates the status (kind)."
  type        = bool
  default     = true
}

variable "webapp_hpa_min_replicas" {
  description = "HPA floor for the webapp (only used with the public ingress)"
  type        = number
  default     = 2
}

variable "webapp_hpa_max_replicas" {
  description = "HPA ceiling for the webapp"
  type        = number
  default     = 10
}

variable "webapp_hpa_cpu_target" {
  description = "Target average CPU utilisation (percent of the request) the HPA holds the webapp at"
  type        = number
  default     = 70
}

# ------------------------------------------------------------------------------
# JUPYTERHUB
# ------------------------------------------------------------------------------

variable "jupyterhub_chart_version" {
  description = "JupyterHub Helm chart version"
  type        = string
  default     = "3.3.8"
}

variable "jupyterhub_auth_mechanism" {
  description = "JupyterHub authentication: 'dummy' (shared password), 'firstuse' (each user sets their own password at first login), or 'oidc' (any OIDC provider -- Google, Cognito, Okta, Keycloak -- via the jupyterhub_oidc_* variables). Null (the default) follows auth.mode: 'oidc' when auth.mode is \"oidc\" (against the same issuer, a Dex client registered for it), 'dummy' otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.jupyterhub_auth_mechanism == null || contains(["dummy", "firstuse", "oidc"], coalesce(var.jupyterhub_auth_mechanism, "dummy"))
    error_message = "jupyterhub_auth_mechanism must be null, 'dummy', 'firstuse', or 'oidc'."
  }
}

variable "jupyterhub_oidc_client_id" {
  description = "OIDC client id (auth mechanism 'oidc'). Leave empty with auth = { mode = \"oidc\", dex_namespace = ... } and the module registers a client at Dex and fills in every jupyterhub_oidc_* endpoint itself."
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_jupyterhub || coalesce(var.jupyterhub_auth_mechanism, var.auth.mode == "oidc" ? "oidc" : "dummy") != "oidc" || var.jupyterhub_oidc_client_id != "" || (var.auth.mode == "oidc" && var.auth.dex_namespace != "")
    error_message = "jupyterhub_oidc_client_id is required when JupyterHub authenticates with 'oidc' (unless auth.mode = \"oidc\" with auth.dex_namespace, which registers one)."
  }
}

variable "jupyterhub_oidc_client_secret" {
  description = "OIDC client secret (auth mechanism 'oidc')"
  type        = string
  default     = ""
  sensitive   = true
}

variable "jupyterhub_oidc_authorize_url" {
  description = "OIDC authorization endpoint, e.g. https://accounts.google.com/o/oauth2/v2/auth"
  type        = string
  default     = ""
}

variable "jupyterhub_oidc_token_url" {
  description = "OIDC token endpoint, e.g. https://oauth2.googleapis.com/token"
  type        = string
  default     = ""
}

variable "jupyterhub_oidc_userdata_url" {
  description = "OIDC userinfo endpoint, e.g. https://openidconnect.googleapis.com/v1/userinfo"
  type        = string
  default     = ""
}

variable "jupyterhub_oidc_callback_url" {
  description = "OAuth callback: https://<jupyterhub host>/hub/oauth_callback (the host may be a tailnet ts.net name — the IdP only needs the browser to reach it, so private hubs work)"
  type        = string
  default     = ""
}

variable "jupyterhub_oidc_username_claim" {
  description = "Claim used as the JupyterHub username (also the {username} home sub-path on the shared volume, and what jupyterhub_admin_users/jupyterhub_allowed_users match against)"
  type        = string
  default     = "email"
}

variable "jupyterhub_oidc_scopes" {
  description = "OAuth scopes to request"
  type        = list(string)
  default     = ["openid", "email"]
}

variable "jupyterhub_oidc_login_service" {
  description = "Label on the JupyterHub login button, e.g. 'Google'"
  type        = string
  default     = "OIDC"
}

variable "jupyterhub_user_password" {
  description = "Shared password for JupyterHub users (dummy auth)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "jupyterhub_admin_users" {
  description = "JupyterHub usernames granted admin rights"
  type        = list(string)
  default     = []
}

variable "jupyterhub_allow_all" {
  description = "With the 'oidc' mechanism, let every account the issuer admits log in (and get a notebook server). Off by default: name jupyterhub_allowed_users or auth.jupyterhub_allowed_groups instead, or turn this on only when the issuer's connectors already restrict who can log in. The 'dummy' and 'firstuse' mechanisms keep allowing everyone when jupyterhub_allowed_users is empty."
  type        = bool
  default     = false
}

variable "jupyterhub_auth_refresh_seconds" {
  description = "JupyterHub on OIDC: refresh a user's tokens and groups before a spawn when they are older than this, so a group removed at the IdP stops the next server"
  type        = number
  default     = 300
}

variable "jupyterhub_cookie_max_age_days" {
  description = "How long a JupyterHub login lasts before the IdP is asked again (JupyterHub's default is 14)"
  type        = number
  default     = 1
}

variable "jupyterhub_server_max_age_seconds" {
  description = "The culler stops a notebook server this long after it started, busy or not (0 = never). Bounds how long a server keeps credentials its user has since lost. Default: a day with the oidc mechanism (group profiles, refreshed groups), never otherwise."
  type        = number
  default     = null

  validation {
    condition     = var.jupyterhub_server_max_age_seconds == null || coalesce(var.jupyterhub_server_max_age_seconds, 0) >= 0
    error_message = "jupyterhub_server_max_age_seconds must be null, 0, or a positive number of seconds."
  }
}

variable "jupyterhub_group_profiles" {
  description = <<-EOT
    Per-group notebook server profiles, keyed by IdP group path (e.g.
    "/acme/research"). Members of the group are offered it; its server runs
    as ServiceAccount <prefix>jh-<tenant>-<group> (service_account_annotations,
    e.g. an IRSA role), with env and secret_env, the group's directory at
    ~/group (group_directory), without the platform's identity Secret
    (replace_identity) and, with mount_shared = false, without /home/shared.
    Requires JupyterHub on OIDC.
  EOT
  type = map(object({
    display_name                = optional(string)
    service_account_annotations = optional(map(string), {})
    env                         = optional(map(string), {})
    secret_env                  = optional(map(string), {})
    group_directory             = optional(bool, true)
    replace_identity            = optional(bool, true)
    mount_shared                = optional(bool, true)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.jupyterhub_group_profiles) : can(regex("^(/[a-z][a-z0-9_-]*)+$", k))])
    error_message = "jupyterhub_group_profiles keys are group paths like /tenant/group."
  }
}

variable "jupyterhub_allowed_users" {
  description = "JupyterHub usernames allowed to log in. Empty: with 'dummy'/'firstuse' any username; with 'oidc' only jupyterhub_allow_all or auth.jupyterhub_allowed_groups admit anyone."
  type        = list(string)
  default     = []
}

variable "jupyterhub_extra_values" {
  description = "Additional YAML documents merged into the JupyterHub Helm values after the built-in template (highest precedence). Use for profiles, lifecycle hooks, resource limits, etc."
  type        = list(string)
  default     = []
}

variable "jupyterhub_singleuser_image" {
  description = "Container image (repository:tag) for JupyterHub single-user servers. Empty uses the chart default."
  type        = string
  default     = ""
}

# --- CONTRACT: shared storage ---------------------------------------------------

variable "jupyterhub_shared_storage" {
  description = <<-EOT
    The ReadWriteMany volume holding every user's home directory and the
    shared directory -- the only persistent user data in this module. Exactly
    one of:
      nfs_server          static NFS PersistentVolumes pointing at an existing
                          server: an EFS filesystem's DNS name
                          (aws/compute-adapter), a Filestore IP, any NFS box.
      storage_class_name  dynamic RWX PersistentVolumeClaims from a
                          StorageClass (efs-sc, standard-rwx, azurefile,
                          nfs-client; kind's local-path works on one node).
    `size` is the claim size (nominal for NFS). Required when
    enable_jupyterhub is true.
  EOT
  type = object({
    nfs_server         = optional(string)
    nfs_path           = optional(string, "/")
    storage_class_name = optional(string)
    size               = optional(string, "100Gi")
  })
  default = {}

  validation {
    condition     = !var.enable_jupyterhub || ((var.jupyterhub_shared_storage.nfs_server != null) != (var.jupyterhub_shared_storage.storage_class_name != null))
    error_message = "With enable_jupyterhub, set exactly one of jupyterhub_shared_storage.nfs_server or .storage_class_name."
  }
}

# --- Public ingress (optional) ---------------------------------------------------

variable "jupyterhub_public_host" {
  description = "Hostname for a JupyterHub Ingress on jupyterhub_public_ingress_class_name (also stamped for external-dns). Empty skips the Ingress."
  type        = string
  default     = ""
}

variable "jupyterhub_public_ingress_class_name" {
  description = "IngressClass for the JupyterHub Ingress. Required when jupyterhub_public_host is set."
  type        = string
  default     = ""

  validation {
    condition     = var.jupyterhub_public_host == "" || var.jupyterhub_public_ingress_class_name != ""
    error_message = "jupyterhub_public_ingress_class_name is required when jupyterhub_public_host is set."
  }
}

variable "jupyterhub_public_ingress_annotations" {
  description = "Annotations for the JupyterHub Ingress (aws/compute-adapter emits the alb.ingress.kubernetes.io/* set)."
  type        = map(string)
  default     = {}
}

variable "jupyterhub_public_tls_secret_name" {
  description = "TLS Secret for the JupyterHub Ingress (e.g. cert-manager). Empty adds no tls block."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# DAGSTER
# ------------------------------------------------------------------------------

variable "dagster_chart_version" {
  description = "Version of the official dagster/dagster Helm chart. Must be >= 1.13.23: earlier images are amd64-only, and an arm64 cluster (kind on Apple Silicon, Graviton nodes) cannot pull them."
  type        = string
  default     = "1.13.23"
}

variable "dagster_repository" {
  description = "Helm repository for the Dagster chart"
  type        = string
  default     = "https://dagster-io.github.io/helm"
}

variable "dagster_user_code_image" {
  description = "User-code (code location) image for Dagster, repository:tag, exposing /opt/dagster/app/repo.py. Empty deploys the module's own hello-world code location (helm-defaults/dagster/hello_repo.py) in the stock dagster-k8s image."
  type        = string
  default     = ""
}

variable "dagster_code_locations" {
  description = <<-EOT
    More Dagster code locations, keyed by name (a tenant's, a team's). Each
    runs -- and launches its runs -- as its own ServiceAccount
    (<prefix>dagster-<name>, with service_account_annotations such as an IRSA
    role) with its own secret_env; the platform's Dagster identity is not
    given to it. image must expose /opt/dagster/app/repo.py unless grpc_args
    says otherwise. mlflow_account (auth.mlflow_mode = "oidc"): the MLflow
    service account its runs use, delivered in mlflow-credentials-<name>;
    mlflow_experiment_patterns scope it (default: EDIT on "^<name>/").
  EOT
  type = map(object({
    image                       = string
    grpc_args                   = optional(list(string), ["--python-file", "/opt/dagster/app/repo.py"])
    env                         = optional(map(string), {})
    secret_env                  = optional(map(string), {})
    service_account_annotations = optional(map(string), {})
    mlflow_account              = optional(string, "")
    mlflow_experiment_patterns = optional(list(object({
      regex      = string
      permission = optional(string, "EDIT")
      priority   = optional(number, 50)
    })))
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.dagster_code_locations) : can(regex("^[a-z][a-z0-9-]{0,30}$", k)) && !contains(["hello", "user-code"], k)])
    error_message = "dagster_code_locations keys are DNS labels (^[a-z][a-z0-9-]{0,30}$), and hello / user-code are the default location's names."
  }
}

variable "dagster_user_code_env" {
  description = <<-EOT
    Plain environment variables for the Dagster user-code deployment and, through
    includeConfigInLaunchedRuns, every run it launches -- how assets learn where
    their data lives (e.g. DATA_REFS, ICEBERG_CATALOG; see
    docs/preview-environments.md). Ignored when dagster_user_code_image is empty.
  EOT
  type        = map(string)
  default     = {}
}

variable "dagster_user_code_secret_env" {
  description = <<-EOT
    Secret environment variables for the Dagster user-code deployment and its
    runs, delivered through a Kubernetes Secret. database_url is added as
    DATABASE_URL automatically, mirroring the webapp, so assets and the webapp
    read the same database without extra wiring.
  EOT
  type        = map(string)
  default     = {}
  sensitive   = true
}

# ------------------------------------------------------------------------------
# MLFLOW
# ------------------------------------------------------------------------------

variable "mlflow_chart_version" {
  description = "Version of the community-charts/mlflow Helm chart. Must be >= 1.x: the 0.7 chart's image bundles a libpq too old for SCRAM authentication, which Postgres 14+ and Neon default to."
  type        = string
  default     = "1.11.7"
}

variable "mlflow_repository" {
  description = "Helm repository for the MLflow chart"
  type        = string
  default     = "https://community-charts.github.io/helm-charts"
}

variable "mlflow_image" {
  description = "MLflow server image (the chart's burakince/mlflow, which bundles mlflow-oidc-auth); on OIDC also the init container that makes mlflow-auth-sync an MLflow admin. Keep tag at the chart's appVersion when bumping mlflow_chart_version."
  # On OIDC, mlflow-auth-sync needs the bundled mlflow-oidc-auth >= 7.18: its
  # AUTH_PROVIDERS registry and k8s provider, and mlflow_oidc_auth.user's
  # create_user (3.16.0 bundles 7.18.1). Check both on a bump.
  type = object({
    repository = optional(string, "burakince/mlflow")
    tag        = optional(string, "3.16.0")
  })
  default = {}
}

variable "mlflow_artifact_root" {
  description = <<-EOT
    Artifact store URI for the tracking server, e.g. s3://my-bucket/mlflow.
    Any S3-compatible store works: point AWS_ENDPOINT_URL /
    MLFLOW_S3_ENDPOINT_URL at it through workload_identity["mlflow"].env.
    Empty uses the chart's default local artifact root (fine for kind).
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.mlflow_artifact_root == "" || can(regex("^s3://[^/]+", var.mlflow_artifact_root))
    error_message = "mlflow_artifact_root must be empty or an s3://bucket[/prefix] URI (S3-compatible stores included)."
  }
}

variable "mlflow_workers" {
  description = "uvicorn worker processes for the tracking server (`mlflow server --workers`). Each is a few hundred MiB; the chart's default is 4."
  type        = number
  default     = 2

  validation {
    condition     = var.mlflow_workers >= 1
    error_message = "mlflow_workers must be at least 1."
  }
}

variable "mlflow_allowed_hosts" {
  description = <<-EOT
    Extra Host headers the MLflow server accepts (MLflow >= 3.5 rejects any it
    was not told about). The module already allows its own names -- the
    in-cluster Service, the private hostname under private_ingress_dns_suffix,
    the oauth2-proxy, localhost -- so add only other names you reach it by
    (a public hostname, a port-forward alias). "*.example.com" wildcards work.
  EOT
  type        = list(string)
  default     = []
}

variable "mlflow_cors_allowed_origins" {
  description = <<-EOT
    Extra browser origins the MLflow server accepts API calls from (MLflow >=
    3.5 refuses the rest's POSTs as "Cross-origin request blocked", which is
    every search its own UI makes). The module already allows the UI's origin
    under private_ingress_dns_suffix, so add only other web apps that call
    MLflow from a browser, e.g. "https://notebooks.example.com".
  EOT
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------------------------
# ARGO WORKFLOWS
# ------------------------------------------------------------------------------

variable "argo_workflows_chart_version" {
  description = "Version of the argo/argo-workflows Helm chart. Its appVersion must match the CRDs the platform installed (aws/eks-platform argo_workflows_version; 2.0.6 -> v4.1.3)."
  type        = string
  default     = "2.0.6"
}

variable "argo_workflows_repository" {
  description = "Helm repository for the Argo Workflows chart"
  type        = string
  default     = "https://argoproj.github.io/argo-helm"
}

variable "enable_argo_workflow_archive" {
  description = "Persist completed workflows to Postgres (the workflow archive), so they outlive their etcd objects and the UI keeps history. Requires argo_db_*."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_argo_workflow_archive || (var.argo_db_host != "" && var.argo_db_name != "" && var.argo_db_user != "")
    error_message = "enable_argo_workflow_archive requires argo_db_host, argo_db_name and argo_db_user."
  }
}

variable "argo_db_host" {
  description = "Argo workflow-archive Postgres host"
  type        = string
  default     = ""
}
variable "argo_db_port" {
  description = "Argo workflow-archive Postgres port"
  type        = number
  default     = 5432
}
variable "argo_db_name" {
  description = "Argo workflow-archive Postgres database name"
  type        = string
  default     = ""
}
variable "argo_db_user" {
  description = "Argo workflow-archive Postgres user"
  type        = string
  default     = ""
}
variable "argo_db_password" {
  description = "Argo workflow-archive Postgres password"
  type        = string
  default     = ""
  sensitive   = true
}
variable "argo_db_ssl_mode" {
  description = "libpq sslmode for the archive connection: require (Neon, RDS) or disable (an in-cluster Postgres)"
  type        = string
  default     = "require"

  validation {
    condition     = contains(["disable", "require", "verify-ca", "verify-full"], var.argo_db_ssl_mode)
    error_message = "argo_db_ssl_mode must be one of disable, require, verify-ca, verify-full."
  }
}

# ------------------------------------------------------------------------------
# RAY
# ------------------------------------------------------------------------------

variable "ray_version" {
  description = <<-EOT
    Ray version used for the cluster image tags and the RayCluster spec.
    Anything connecting via Ray client (`ray://`, e.g. Dagster user code) must
    match the cluster on BOTH the Ray version and the Python minor version;
    the robust pattern is building those images FROM the same base
    (`rayproject/ray:<ray_version>-pyXXX`) so they match by construction.
  EOT
  type        = string
  default     = "2.55.1"
}

variable "ray_image_repository" {
  description = "Container image repository for Ray head/worker (CPU). Empty uses the public rayproject/ray image."
  type        = string
  default     = "rayproject/ray"
}

variable "ray_image_tag" {
  description = "Image tag for Ray head/worker (CPU). Empty derives '<ray_version>'."
  type        = string
  default     = ""
}

variable "ray_gpu_image_repository" {
  description = "Container image repository for Ray GPU workers. Empty uses the public rayproject/ray image."
  type        = string
  default     = "rayproject/ray"
}

variable "ray_gpu_image_tag" {
  description = "Image tag for Ray GPU workers. Empty derives '<ray_version>-gpu'."
  type        = string
  default     = ""
}

variable "ray_cluster_chart_version" {
  description = "Version of the kuberay ray-cluster Helm chart"
  type        = string
  default     = "1.6.0"
}

variable "ray_cluster_repository" {
  description = "Helm repository for the kuberay ray-cluster chart"
  type        = string
  default     = "https://ray-project.github.io/kuberay-helm/"
}

variable "ray_cluster_release_name" {
  description = "Helm release name for the persistent Ray cluster (auto-prefixed)"
  type        = string
  default     = "ray-cluster"
}

variable "ray_head_resources" {
  description = "Resource requests/limits for the persistent Ray head container"
  type = object({
    requests = optional(map(string), { cpu = "1", memory = "2Gi" })
    limits   = optional(map(string), { cpu = "2", memory = "4Gi" })
  })
  default = {}
}

variable "ray_worker_resources" {
  description = "Resource requests/limits for the persistent Ray CPU worker containers"
  type = object({
    requests = optional(map(string), { cpu = "1", memory = "2Gi" })
    limits   = optional(map(string), { cpu = "2", memory = "4Gi" })
  })
  default = {}
}

variable "ray_enable_autoscaler" {
  description = "Run the Ray autoscaler in the head pod, so workers scale from 0 to ray_worker_max_replicas with demand (and back)"
  type        = bool
  default     = true
}

variable "ray_autoscaler_resources" {
  description = "Resources of the autoscaler container in the Ray head pod (ray_enable_autoscaler). null keeps KubeRay's default of 500m CPU / 512Mi for requests and limits alike, which on a small node reserves more than a small head itself"
  type = object({
    requests = optional(map(string))
    limits   = optional(map(string))
  })
  default = null
}

variable "ray_head_num_cpus" {
  description = "CPUs the head advertises to Ray (rayStartParams num-cpus); null keeps Ray's default (all of the pod's). 0 keeps tasks off the head: a small head, work on autoscaled workers."
  type        = number
  default     = null
}

variable "ray_head_start_params" {
  description = "More `ray start` parameters for the head (rayStartParams), e.g. { \"object-store-memory\" = \"100000000\" } -- Ray otherwise sizes its object store at 30% of the pod's memory"
  type        = map(string)
  default     = {}
}

variable "ray_worker_max_replicas" {
  description = "Autoscaling ceiling for the persistent Ray CPU worker group (min is 0)"
  type        = number
  default     = 10
}

variable "ray_dashboard_cluster_name" {
  description = "RayCluster whose head Pod backs the private ray Ingress. Empty follows the persistent cluster ('<name_prefix><ray_cluster_release_name>')."
  type        = string
  default     = ""
}
