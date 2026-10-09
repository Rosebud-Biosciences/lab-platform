# ------------------------------------------------------------------------------
# WORKLOADS MODULE - MLFLOW ON ITS OWN OIDC (auth.mlflow_mode = "oidc")
#
# The chart's mlflow-oidc-auth plugin logs users in through the issuer and
# enforces per-experiment permissions: mlflow_groups may log in,
# superadmin_group administers, everyone else starts at NO_PERMISSIONS.
# Its users, groups and permissions live in the MLflow database (schema
# mlflow_auth, created by an init container), so they branch with the
# experiments they govern.
#
# In-cluster clients authenticate as MLflow service accounts: mlflow-auth-sync
# (a CronJob) creates them, keeps their tokens in an mlflow-credentials Secret
# in each client namespace, and applies the declarative experiment patterns.
# Every environment whose clients use an OIDC MLflow -- this one, or a stamp
# using a shared one (mlflow_client_credentials) -- pre-creates that Secret
# empty and lets the sync job's ServiceAccount fill it.
#
# The sync job holds no MLflow credential: it presents its own projected
# ServiceAccount token (kubelet rotates it), which the plugin's "k8s" provider
# accepts from MLflow's namespace only, and an init container in MLflow's pod
# -- which has the plugin's database -- keeps that account an admin.
# ------------------------------------------------------------------------------

locals {
  mlflow_sync_name = "mlflow-auth-sync"
  mlflow_schema    = "mlflow_auth"

  mlflow_client_credentials = coalesce(var.mlflow_client_credentials, local.mlflow_oidc)
  mlflow_sync_namespace     = var.mlflow_auth_sync_namespace != "" ? var.mlflow_auth_sync_namespace : local.mlflow_namespace

  # This environment's MLflow clients (their namespaces get the Secret).
  mlflow_client_namespaces = {
    for svc, ns in {
      dagster = local.dagster_namespace
      ray     = local.ray_namespace
      webapp  = local.webapp_namespace
    } : svc => ns if lookup({ dagster = local.enable_dagster, ray = var.enable_ray, webapp = var.enable_webapp }, svc, false)
  }

  mlflow_service_accounts = merge(
    {
      for svc, ns in local.mlflow_client_namespaces : "svc-${local.prefix}${svc}" => {
        secrets             = [{ namespace = ns, name = "mlflow-credentials" }]
        experiment_patterns = [{ regex = ".*", permission = "EDIT", priority = 100 }]
      }
    },
    {
      for name, loc in local.dagster_locations : loc.mlflow_account => {
        secrets             = [{ namespace = local.dagster_namespace, name = "mlflow-credentials-${name}" }]
        experiment_patterns = coalesce(loc.mlflow_experiment_patterns, [{ regex = "^${name}/", permission = "EDIT", priority = 50 }])
      } if loc.mlflow_account != ""
    },
    var.mlflow_service_accounts,
  )

  # Client side: the Secrets this environment owns for an OIDC MLflow's sync
  # job to fill -- one per client service, one per code location with an
  # account -- grouped by namespace for the writer Roles.
  mlflow_credential_secrets = merge(
    local.mlflow_client_credentials ? {
      for svc, ns in local.mlflow_client_namespaces : "${ns}/mlflow-credentials" => { namespace = ns, name = "mlflow-credentials" }
    } : {},
    {
      for name, loc in local.dagster_locations : "${local.dagster_namespace}/mlflow-credentials-${name}" => {
        namespace = local.dagster_namespace
        name      = "mlflow-credentials-${name}"
      } if loc.mlflow_account != ""
    },
  )
  mlflow_credential_namespaces = {
    for ns in distinct([for s in values(local.mlflow_credential_secrets) : s.namespace]) :
    ns => [for s in values(local.mlflow_credential_secrets) : s.name if s.namespace == ns]
  }

  mlflow_sync_config = {
    service_accounts = local.mlflow_service_accounts
    group_rules = {
      for g in distinct([for r in var.auth.mlflow_group_rules : r.group]) : g => [
        for r in var.auth.mlflow_group_rules : { regex = r.regex, permission = r.permission, priority = r.priority } if r.group == g
      ]
    }
  }

  mlflow_oidc_groups = distinct(compact(concat(var.auth.mlflow_groups, [var.auth.superadmin_group])))

  # The plugin names a ServiceAccount <name>.<namespace>@serviceaccount.cluster.local.
  mlflow_sync_user     = "${local.mlflow_sync_name}.${local.mlflow_namespace}@serviceaccount.cluster.local"
  mlflow_sync_audience = "http://${local.mlflow_service}.${local.mlflow_namespace}.svc.cluster.local"

  # An explicit registry replaces the provider the plugin would build from the
  # OIDC_* variables, so the issuer is restated as "default" (still reading
  # OIDC_CLIENT_SECRET, still /login and /callback) beside the cluster.
  mlflow_client_id = try(local.auth_client.mlflow.id, "")
  mlflow_auth_providers = [
    {
      id            = "default"
      type          = "oidc"
      display_name  = "Login with OIDC"
      audience      = local.mlflow_client_id
      client_id     = local.mlflow_client_id
      issuer        = var.auth.issuer_url
      discovery_url = "${var.auth.issuer_url}/.well-known/openid-configuration"
    },
    {
      id                  = "cluster"
      type                = "k8s"
      audience            = local.mlflow_sync_audience
      issuer              = var.kubernetes_service_account_issuer
      namespace_allowlist = [local.mlflow_namespace]
      jwks_uri            = "https://kubernetes.default.svc/openid/v1/jwks"
      in_cluster          = true
    },
  ]

  # create_user creates the account as an admin, or makes it one again; the
  # plugin's store runs its migrations first.
  mlflow_promote_sync = <<-EOT
    import os
    from mlflow_oidc_auth.user import create_user
    print(create_user(username=os.environ["SYNC_USER"], display_name="mlflow-auth-sync (service account)", is_admin=True, is_service_account=True)[1])
  EOT

  # Helm replaces lists rather than merging them: this document restates the
  # whole envFrom list the base values set.
  mlflow_oidc_values = local.mlflow_oidc ? yamlencode({
    oidcAuth = {
      enabled             = true
      discoveryUrl        = "${var.auth.issuer_url}/.well-known/openid-configuration"
      clientId            = local.auth_client.mlflow.id
      existingSecret      = { name = kubernetes_secret_v1.mlflow_oidc[0].metadata[0].name, clientSecretKey = "OIDC_CLIENT_SECRET" }
      redirectUri         = local.auth_redirect_uris.mlflow[0]
      scope               = join(",", var.auth.scopes)
      groupsAttribute     = var.auth.groups_claim
      groupName           = local.mlflow_oidc_groups
      adminGroupName      = compact([var.auth.superadmin_group])
      defaultPermission   = "NO_PERMISSIONS"
      sessionCookieSecure = var.auth.cookie_secure
    }
    # A map, so Helm merges it with the base values' identity env.
    extraEnvVars = { AUTH_PROVIDERS = jsonencode(local.mlflow_auth_providers) }
    extraSecretNamesForEnvFrom = [
      kubernetes_secret_v1.mlflow_identity_env[0].metadata[0].name,
      kubernetes_secret_v1.mlflow_auth_db[0].metadata[0].name,
      kubernetes_secret_v1.mlflow_oidc[0].metadata[0].name,
    ]
    initContainers = [
      {
        name    = "create-auth-schema"
        image   = var.postgres_client_image
        command = ["psql", "-v", "ON_ERROR_STOP=1", "-c", "CREATE SCHEMA IF NOT EXISTS ${local.mlflow_schema}"]
        envFrom = [{ secretRef = { name = kubernetes_secret_v1.mlflow_auth_db[0].metadata[0].name } }]
        securityContext = {
          allowPrivilegeEscalation = false
          runAsNonRoot             = true
          runAsUser                = 70
          capabilities             = { drop = ["ALL"] }
        }
      },
      {
        name    = "admin-auth-sync"
        image   = "${var.mlflow_image.repository}:${var.mlflow_image.tag}"
        command = ["python", "-c", local.mlflow_promote_sync]
        env = [
          { name = "SYNC_USER", value = local.mlflow_sync_user },
          { name = "PYTHONDONTWRITEBYTECODE", value = "1" },
        ]
        envFrom      = [{ secretRef = { name = kubernetes_secret_v1.mlflow_auth_db[0].metadata[0].name } }]
        volumeMounts = [{ name = "tmp", mountPath = "/tmp" }]
        securityContext = {
          allowPrivilegeEscalation = false
          readOnlyRootFilesystem   = true
          runAsNonRoot             = true
          runAsUser                = 1001
          capabilities             = { drop = ["ALL"] }
        }
      },
    ]
  }) : ""
}

resource "kubernetes_secret_v1" "mlflow_oidc" {
  count = local.mlflow_oidc ? 1 : 0

  metadata {
    name      = "${local.mlflow_release}-oidc"
    namespace = local.mlflow_namespace
  }

  data = {
    OIDC_CLIENT_SECRET = local.auth_client.mlflow.secret
    # Signs the plugin's session cookie. Unset, each server process draws its
    # own, and a login made in one worker is unknown to the next.
    SECRET_KEY = random_password.mlflow_session[0].result
  }

  lifecycle {
    precondition {
      condition     = length(local.mlflow_oidc_groups) > 0
      error_message = "MLflow on OIDC admits only auth.mlflow_groups (and auth.superadmin_group), and neither is set, so nobody could log in."
    }
  }
}

resource "random_password" "mlflow_session" {
  count = local.mlflow_oidc ? 1 : 0

  length  = 48
  special = false
}

# The plugin's store: the MLflow database, its own schema. PG* are for the
# init container's psql.
resource "kubernetes_secret_v1" "mlflow_auth_db" {
  count = local.mlflow_oidc ? 1 : 0

  metadata {
    name      = "${local.mlflow_release}-auth-db"
    namespace = local.mlflow_namespace
  }

  data = {
    OIDC_USERS_DB_URI = "postgresql+psycopg2://${urlencode(var.mlflow_db_user)}:${urlencode(var.mlflow_db_password)}@${var.mlflow_db_host}:5432/${var.mlflow_db_name}?options=${urlencode("-csearch_path=${local.mlflow_schema}")}"
    PGHOST            = var.mlflow_db_host
    PGDATABASE        = var.mlflow_db_name
    PGUSER            = var.mlflow_db_user
    PGPASSWORD        = var.mlflow_db_password
  }
}

# ------------------------------------------------------------------------------
# Client side: the Secret the sync job fills, and its right to fill it
# ------------------------------------------------------------------------------

resource "kubernetes_secret_v1" "mlflow_credentials" {
  for_each = local.mlflow_credential_secrets

  metadata {
    name      = each.value.name
    namespace = each.value.namespace
  }

  data = {}

  lifecycle {
    # mlflow-auth-sync owns the contents.
    ignore_changes = [data, metadata[0].annotations]
  }

  depends_on = [kubernetes_namespace_v1.dagster, kubernetes_namespace_v1.ray, kubernetes_namespace_v1.webapp, kubernetes_role_binding_v1.namespace_admin]
}

resource "kubernetes_role_v1" "mlflow_credentials" {
  for_each = local.mlflow_credential_namespaces

  metadata {
    name      = "mlflow-credentials-writer"
    namespace = each.key
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = each.value
    verbs          = ["get", "patch"]
  }

  depends_on = [kubernetes_secret_v1.mlflow_credentials]
}

resource "kubernetes_role_binding_v1" "mlflow_credentials" {
  for_each = local.mlflow_credential_namespaces

  metadata {
    name      = "mlflow-credentials-writer"
    namespace = each.key
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.mlflow_credentials[each.key].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = local.mlflow_sync_name
    namespace = local.mlflow_sync_namespace
  }
}

# ------------------------------------------------------------------------------
# mlflow-auth-sync (next to MLflow)
# ------------------------------------------------------------------------------

resource "kubernetes_service_account_v1" "mlflow_auth_sync" {
  count = local.mlflow_oidc ? 1 : 0

  metadata {
    name      = local.mlflow_sync_name
    namespace = local.mlflow_namespace
  }
}

resource "kubernetes_config_map_v1" "mlflow_auth_sync" {
  count = local.mlflow_oidc ? 1 : 0

  metadata {
    name      = local.mlflow_sync_name
    namespace = local.mlflow_namespace
  }

  data = {
    "sync.py"     = file("${path.module}/files/mlflow_auth_sync.py")
    "config.json" = jsonencode(local.mlflow_sync_config)
  }
}

resource "kubernetes_cron_job_v1" "mlflow_auth_sync" {
  #checkov:skip=CKV_K8S_43:the image is pinned by tag (python_image) and bumped like every other pin in this repo; a digest would defeat that
  count = local.mlflow_oidc ? 1 : 0

  metadata {
    name      = local.mlflow_sync_name
    namespace = local.mlflow_namespace
  }

  spec {
    schedule                      = var.mlflow_auth_sync_schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3

    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {
            labels = { app = local.mlflow_sync_name }
          }
          spec {
            service_account_name = kubernetes_service_account_v1.mlflow_auth_sync[0].metadata[0].name
            restart_policy       = "Never"

            security_context {
              run_as_non_root = true
              run_as_user     = 65532
              run_as_group    = 65532
              seccomp_profile {
                type = "RuntimeDefault"
              }
            }

            volume {
              name = "config"
              config_map {
                name = kubernetes_config_map_v1.mlflow_auth_sync[0].metadata[0].name
              }
            }
            # Its MLflow credential: a token for MLflow's audience only.
            volume {
              name = "mlflow-token"
              projected {
                sources {
                  service_account_token {
                    audience           = local.mlflow_sync_audience
                    expiration_seconds = 3600
                    path               = "token"
                  }
                }
              }
            }

            container {
              name              = "sync"
              image             = var.python_image
              image_pull_policy = "Always"
              command           = ["python3", "/etc/mlflow-auth-sync/sync.py"]

              env {
                name  = "MLFLOW_URL"
                value = "http://${local.mlflow_service}.${local.mlflow_namespace}.svc.cluster.local"
              }
              env {
                name  = "MLFLOW_TOKEN_FILE"
                value = "/var/run/secrets/mlflow/token"
              }
              env {
                name  = "MLFLOW_USER"
                value = local.mlflow_sync_user
              }

              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                run_as_non_root            = true
                capabilities {
                  drop = ["ALL"]
                }
              }

              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { cpu = "200m", memory = "128Mi" }
              }

              volume_mount {
                name       = "config"
                mount_path = "/etc/mlflow-auth-sync"
                read_only  = true
              }
              volume_mount {
                name       = "mlflow-token"
                mount_path = "/var/run/secrets/mlflow"
                read_only  = true
              }
            }
          }
        }
      }
    }
  }
}
