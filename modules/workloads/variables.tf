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
  description = "DNS suffix for the private hostnames (e.g. your MagicDNS tailnet suffix <tailnet>.ts.net). Used only to build output URLs."
  type        = string
  default     = ""
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
  description = "JupyterHub authentication: 'dummy' (shared password), 'firstuse' (each user sets their own password at first login), or 'oidc' (any OIDC provider — Google, Cognito, Okta, Keycloak — via the jupyterhub_oidc_* variables)"
  type        = string
  default     = "dummy"

  validation {
    condition     = contains(["dummy", "firstuse", "oidc"], var.jupyterhub_auth_mechanism)
    error_message = "jupyterhub_auth_mechanism must be 'dummy', 'firstuse', or 'oidc'."
  }
}

variable "jupyterhub_oidc_client_id" {
  description = "OIDC client id (auth mechanism 'oidc')"
  type        = string
  default     = ""

  validation {
    condition     = var.jupyterhub_auth_mechanism != "oidc" || var.jupyterhub_oidc_client_id != ""
    error_message = "jupyterhub_oidc_client_id is required when jupyterhub_auth_mechanism is 'oidc'."
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

variable "jupyterhub_allowed_users" {
  description = "JupyterHub usernames allowed to log in. Empty allows any authenticated username (allow_all)."
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
  description = "Version of the official dagster/dagster Helm chart. Must be >= 1.13.23: earlier images are amd64-only, and an arm64 cluster (kind on Apple Silicon, Graviton nodes) cannot pull them." # renovate: chart=dagster registryUrl=https://dagster-io.github.io/helm
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
  description = "Version of the community-charts/mlflow Helm chart. Must be >= 1.x: the 0.7 chart's image bundles a libpq too old for SCRAM authentication, which Postgres 14+ and Neon default to." # renovate: chart=mlflow registryUrl=https://community-charts.github.io/helm-charts
  type        = string
  default     = "1.11.7"
}

variable "mlflow_repository" {
  description = "Helm repository for the MLflow chart"
  type        = string
  default     = "https://community-charts.github.io/helm-charts"
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

# ------------------------------------------------------------------------------
# ARGO WORKFLOWS
# ------------------------------------------------------------------------------

variable "argo_workflows_chart_version" {
  description = "Version of the argo/argo-workflows Helm chart. Its appVersion must match the CRDs the platform installed (aws/eks-platform argo_workflows_version; 2.0.6 -> v4.1.3)." # renovate: chart=argo-workflows registryUrl=https://argoproj.github.io/argo-helm
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
  description = "Version of the kuberay ray-cluster Helm chart" # renovate: chart=ray-cluster registryUrl=https://ray-project.github.io/kuberay-helm
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
