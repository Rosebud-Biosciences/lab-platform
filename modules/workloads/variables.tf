# ------------------------------------------------------------------------------
# TARGET CLUSTER (existing) + NAMING
# ------------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the existing EKS cluster to deploy the workloads onto"
  type        = string
}

variable "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN of the target cluster"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_name" {
  description = "VPC name used by Karpenter NodePools for subnet/SG discovery"
  type        = string
}

variable "karpenter_node_iam_role_name" {
  description = "Name of the Karpenter node IAM role (used by NodePool nodeRole). Empty disables NodePool creation."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment name (prod / dev / preview)"
  type        = string
  default     = "dev"
}

variable "name_prefix" {
  description = <<-EOT
    Prefix applied to every namespace, Helm release, IAM role, NodePool, and
    private hostname so multiple workload environments can share one cluster.
    Empty ("") reproduces the base names. A preview uses e.g. "pr123-".

    Validated against the tightest downstream AWS/Kubernetes limits so a long
    prefix cannot silently produce an invalid namespace (63), IAM role name
    (64), or ALB name (32).
  EOT
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^([a-z0-9][a-z0-9-]*)?$", var.name_prefix))
    error_message = "name_prefix must be empty or lowercase alphanumeric/dashes starting with an alphanumeric."
  }

  validation {
    # 20 leaves headroom under every downstream limit once suffixes like
    # "<cluster>-<prefix>argo-workflow-sa" (IAM 64) or the ALB name (32) are added.
    condition     = length(var.name_prefix) <= 21
    error_message = "name_prefix must be <= 21 characters to stay within AWS/Kubernetes name limits after suffixes are appended."
  }
}

variable "tags" {
  description = "Tags applied to AWS resources"
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# FEATURE TOGGLES
# ------------------------------------------------------------------------------

variable "enable_webapp" {
  description = "Deploy the generic web application (Deployment + Service + IRSA)"
  type        = bool
  default     = false
}

variable "enable_jupyterhub" {
  description = "Deploy JupyterHub (namespace, EFS shared volume, IRSA, Helm release, optional ALB ingress)"
  type        = bool
  default     = false
}

variable "enable_dagster" {
  description = "Deploy Dagster (requires enable_ray = true)"
  type        = bool
  default     = false
}

variable "enable_ray" {
  description = "Deploy the Ray namespace + IRSA (the KubeRay operator lives in the platform module)"
  type        = bool
  default     = false
}

variable "enable_argo_workflows" {
  description = "Create the Argo Workflows service account + RBAC in the Ray namespace"
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
# PRIVATE INGRESS (defaults to the Tailscale operator's IngressClass)
# ------------------------------------------------------------------------------

variable "private_ingress_class_name" {
  description = "IngressClass backing the private workload Ingresses. 'tailscale' uses the operator from the platform module; set to your own private ingress controller to bring your own."
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
    "mlflow", "webapp", "ray"); the special key "*" applies to every service,
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

variable "webapp_bucket_policies" {
  description = "Map of IAM policy ARNs attached to the webapp service account (e.g. read-only S3 access)"
  type        = map(string)
  default     = {}
}

variable "webapp_health_check_path" {
  description = "HTTP path used for the webapp readiness/liveness probes and ALB health check"
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

# --- Public (internet-facing) ALB ingress + autoscaling ----------------------

variable "enable_webapp_public_ingress" {
  description = "Create an internet-facing ALB Ingress for the webapp (plus HPA, PodDisruptionBudget, and optional Route53 alias). Requires the AWS Load Balancer Controller."
  type        = bool
  default     = false
}

variable "webapp_public_host" {
  description = "Public hostname the ALB serves and the Route53 alias points at"
  type        = string
  default     = ""
}

variable "webapp_acm_certificate_arn" {
  description = "ACM certificate ARN for the ALB HTTPS listener. Required when enable_webapp_public_ingress is true."
  type        = string
  default     = ""
}

variable "webapp_route53_zone_id" {
  description = "Route53 hosted zone id for webapp_public_host. Empty skips the alias record."
  type        = string
  default     = ""
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

variable "enable_webapp_waf" {
  description = "Attach a WAFv2 web ACL (AWS managed common rules + a per-IP rate limit) to the public ALB"
  type        = bool
  default     = false
}

variable "webapp_waf_rate_limit" {
  description = "WAF rate-based rule limit: max requests per 5-minute window from a single IP before it is blocked"
  type        = number
  default     = 2000
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
  description = "Claim used as the JupyterHub username (also the {username} EFS home sub-path, and what jupyterhub_admin_users/jupyterhub_allowed_users match against)"
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

variable "jupyterhub_public_host" {
  description = "Hostname for the JupyterHub ALB ingress. Empty skips the ingress/DNS."
  type        = string
  default     = ""
}

variable "jupyterhub_ingress_scheme" {
  description = "ALB scheme for the JupyterHub ingress ('internal' or 'internet-facing')"
  type        = string
  default     = "internal"
}

variable "jupyterhub_route53_zone_id" {
  description = "Route53 hosted zone id for jupyterhub_public_host. Empty skips the alias record."
  type        = string
  default     = ""
}

variable "jupyterhub_efs_prevent_destroy" {
  description = <<-EOT
    Protect the JupyterHub EFS filesystem (user home directories) from
    `tofu destroy` via lifecycle.prevent_destroy (dynamic; OpenTofu >= 1.12).
    Leave true for durable environments — destroys then fail until this is
    first flipped off, an intentional two-step. Set false for
    previews/ephemeral stamps so they can tear down.
  EOT
  type        = bool
  default     = true
}

# EFS placement (only needed when enable_jupyterhub is true)
variable "vpc_id" {
  description = "VPC ID (required for the JupyterHub EFS security group)"
  type        = string
  default     = ""
}

variable "private_subnets" {
  description = "Private subnet IDs (JupyterHub EFS mount targets)"
  type        = list(string)
  default     = []
}

variable "private_subnets_cidr_blocks" {
  description = "Private subnet CIDR blocks, same order as private_subnets (used to place EFS mount targets in the pod CIDR)"
  type        = list(string)
  default     = []
}

variable "efs_subnet_cidr_octet_prefix" {
  description = "First-octet prefix selecting which private subnets host the JupyterHub EFS mount targets"
  type        = string
  default     = "100."
}

variable "vpc_secondary_cidr_blocks" {
  description = "Secondary VPC CIDR blocks allowed to reach the JupyterHub EFS (NFS 2049)"
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------------------------
# DAGSTER
# ------------------------------------------------------------------------------

variable "dagster_chart_version" {
  description = "Version of the official dagster/dagster Helm chart. Must be >= 1.12.8." # renovate: chart=dagster registryUrl=https://dagster-io.github.io/helm
  type        = string
  default     = "1.13.14"
}

variable "dagster_repository" {
  description = "Helm repository for the Dagster chart"
  type        = string
  default     = "https://dagster-io.github.io/helm"
}

variable "dagster_user_code_image" {
  description = "User-code (code location) image for Dagster, repository:tag. Empty deploys the chart with the example user code."
  type        = string
  default     = ""
}

variable "dagster_bucket_policies" {
  description = "Map of IAM policy ARNs attached to the Dagster service account"
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# MLFLOW
# ------------------------------------------------------------------------------

variable "mlflow_chart_version" {
  description = "Version of the community-charts/mlflow Helm chart" # renovate: chart=mlflow registryUrl=https://community-charts.github.io/helm-charts
  type        = string
  default     = "0.7.19"
}

variable "mlflow_repository" {
  description = "Helm repository for the MLflow chart"
  type        = string
  default     = "https://community-charts.github.io/helm-charts"
}

variable "mlflow_artifact_bucket" {
  description = "S3 bucket name for MLflow artifacts"
  type        = string
  default     = ""
}

variable "mlflow_artifact_bucket_arn" {
  description = "S3 bucket ARN for MLflow artifacts (grants the tracking server access)"
  type        = string
  default     = ""
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

variable "ray_storage_bucket_policies" {
  description = "Map of IAM policy ARNs attached to the Ray/Argo/Dagster service accounts"
  type        = map(string)
  default     = {}
}

variable "ray_dashboard_cluster_name" {
  description = "RayCluster whose head Pod backs the private ray Ingress. Empty follows the persistent cluster ('<name_prefix><ray_cluster_release_name>')."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# KARPENTER NODEPOOLS (created per workload environment, name-prefixed)
# ------------------------------------------------------------------------------

variable "karpenter_node_pools" {
  description = "Map of Karpenter NodePool configurations (created only if karpenter_node_iam_role_name is set)"
  type = map(object({
    name                   = optional(string)
    instance_sizes         = optional(list(string), ["large", "xlarge", "2xlarge", "4xlarge", "8xlarge"])
    instance_families      = optional(list(string), ["t3a", "c5", "m5", "r5", "r6g"])
    instance_architectures = optional(list(string), ["amd64"])
    capacity_types         = optional(list(string), ["spot", "on-demand"])
    ami_family             = optional(string, "AL2023")
    labels                 = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
    limits = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for pool in values(var.karpenter_node_pools) : contains(["AL2", "AL2023", "Bottlerocket"], pool.ami_family)
    ])
    error_message = "ami_family must be one of: AL2, AL2023, Bottlerocket."
  }
}
