# Toggle-matrix and contract assertions, plan-only against mocked providers so
# no cloud creds or real cluster are needed. Every enable_* = false must yield
# no resources of that family (asserted via the namespace outputs, which are
# null when the service is off); flipping a toggle on must create its
# namespace; and the four contract inputs (identity, scheduling, shared
# storage, public ingress) must land where the pods will see them.
#
# There is deliberately no mock_provider "aws": this module must plan with the
# kubernetes/helm/kubectl providers alone.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "random" {}

run "all_disabled_creates_nothing" {
  command = plan

  assert {
    condition     = output.webapp_namespace == null
    error_message = "webapp namespace should not exist when enable_webapp = false"
  }
  assert {
    condition     = output.dagster_namespace == null
    error_message = "dagster namespace should not exist when enable_dagster = false"
  }
  assert {
    condition     = output.ray_namespace == null
    error_message = "ray namespace should not exist when enable_ray = false"
  }
  assert {
    condition     = output.mlflow_namespace == null
    error_message = "mlflow namespace should not exist when enable_mlflow = false"
  }
  assert {
    condition     = output.jupyterhub_namespace == null
    error_message = "jupyterhub namespace should not exist when enable_jupyterhub = false"
  }
  assert {
    condition     = alltrue([for svc, sa in output.service_accounts : sa == null])
    error_message = "no service account should be published when everything is off"
  }
}

# Webhook identity (IRSA / GKE WI / AKS WI): the annotation lands on the SA and
# nothing is mounted into the pod.
run "webapp_webhook_identity" {
  command = plan

  variables {
    enable_webapp = true
    webapp_image  = "public.ecr.aws/nginx/nginx:latest"
    workload_identity = {
      webapp = {
        service_account_annotations = { "eks.amazonaws.com/role-arn" = "arn:aws:iam::123456789012:role/webapp" }
        env                         = { AWS_REGION = "us-west-2" }
      }
    }
  }

  assert {
    condition     = output.webapp_namespace != null
    error_message = "webapp namespace should exist when enable_webapp = true"
  }
  assert {
    condition     = output.dagster_namespace == null && output.mlflow_namespace == null
    error_message = "enabling only the webapp must not create other namespaces"
  }
  assert {
    condition     = kubernetes_service_account_v1.webapp[0].metadata[0].annotations["eks.amazonaws.com/role-arn"] == "arn:aws:iam::123456789012:role/webapp"
    error_message = "workload_identity.webapp.service_account_annotations must be stamped on the webapp ServiceAccount"
  }
  assert {
    condition     = length(kubernetes_deployment_v1.webapp[0].spec[0].template[0].spec[0].volume) == 0
    error_message = "webhook identity must not mount a projected token"
  }
  assert {
    condition     = contains([for e in kubernetes_deployment_v1.webapp[0].spec[0].template[0].spec[0].container[0].env : e.name], "AWS_REGION")
    error_message = "workload_identity.webapp.env must reach the container"
  }
  assert {
    condition     = output.service_accounts.webapp.name == "webapp" && output.service_accounts.webapp.namespace == "webapp"
    error_message = "service_accounts output must publish the webapp subject"
  }
}

# Web-identity federation from a foreign cluster: projected token volume +
# mount, and the SDK env pointing at it.
run "webapp_projected_token_identity" {
  command = plan

  variables {
    enable_webapp = true
    webapp_image  = "public.ecr.aws/nginx/nginx:latest"
    name_prefix   = "pr7-"
    workload_identity = {
      webapp = {
        env = {
          AWS_ROLE_ARN                = "arn:aws:iam::123456789012:role/pr7-webapp"
          AWS_WEB_IDENTITY_TOKEN_FILE = "/var/run/secrets/workload-identity/token"
        }
        projected_token = { audience = "sts.amazonaws.com" }
      }
    }
    workload_identity_secret_env = {}
  }

  assert {
    condition     = kubernetes_deployment_v1.webapp[0].spec[0].template[0].spec[0].volume[0].projected[0].sources[0].service_account_token[0].audience == "sts.amazonaws.com"
    error_message = "projected_token must become a projected ServiceAccount token volume with the requested audience"
  }
  assert {
    condition     = kubernetes_deployment_v1.webapp[0].spec[0].template[0].spec[0].container[0].volume_mount[0].mount_path == "/var/run/secrets/workload-identity"
    error_message = "the projected token must be mounted at the contract's default mount_path"
  }
  assert {
    condition     = output.service_accounts.webapp.namespace == "pr7-webapp"
    error_message = "name_prefix must prefix the webapp namespace in the published subject"
  }
}

# Static credentials against an S3-compatible store: env carries the endpoint,
# the identity Secret is envFrom'd by the chart, no SA annotations.
run "mlflow_static_credentials_s3_compatible" {
  command = plan

  variables {
    enable_mlflow        = true
    mlflow_artifact_root = "s3://mlflow/artifacts"
    mlflow_db_host       = "db.example.com"
    mlflow_db_name       = "mlflow"
    mlflow_db_user       = "mlflow"
    mlflow_db_password   = "test"
    workload_identity = {
      mlflow = {
        env = {
          AWS_REGION             = "us-east-1"
          MLFLOW_S3_ENDPOINT_URL = "http://seaweedfs.seaweedfs.svc.cluster.local:8333"
        }
      }
    }
    workload_identity_secret_env = {
      mlflow = { AWS_ACCESS_KEY_ID = "seaweedfs", AWS_SECRET_ACCESS_KEY = "seaweedfs123" }
    }
  }

  assert {
    condition     = output.mlflow_namespace != null
    error_message = "mlflow namespace should exist when enable_mlflow = true"
  }
  assert {
    condition     = output.webapp_namespace == null
    error_message = "enabling only mlflow must not create the webapp namespace"
  }
  assert {
    condition     = strcontains(helm_release.mlflow[0].values[0], "seaweedfs.seaweedfs.svc.cluster.local:8333")
    error_message = "workload_identity.mlflow.env must render into the chart's extraEnvVars"
  }
  assert {
    condition     = strcontains(helm_release.mlflow[0].values[0], "- mlflow-identity-env")
    error_message = "the mlflow identity Secret must be listed in extraSecretNamesForEnvFrom"
  }
  assert {
    condition     = strcontains(helm_release.mlflow[0].values[0], "bucket: \"mlflow\"") && strcontains(helm_release.mlflow[0].values[0], "path: \"artifacts\"")
    error_message = "mlflow_artifact_root must split into bucket and path"
  }
  assert {
    condition     = strcontains(helm_release.mlflow[0].values[0], "annotations: {}")
    error_message = "static credentials must not annotate the ServiceAccount"
  }
}

run "mlflow_rejects_non_s3_artifact_root" {
  command = plan

  variables {
    enable_mlflow        = true
    mlflow_artifact_root = "gs://bucket"
  }

  expect_failures = [var.mlflow_artifact_root]
}

# Static NFS mode: the shared-volume chart gets the server, the JupyterHub
# values point at the home claim, and the auth template still renders.
run "jupyterhub_nfs_storage_dummy_auth" {
  command = plan

  variables {
    enable_jupyterhub         = true
    jupyterhub_user_password  = "test-password"
    jupyterhub_shared_storage = { nfs_server = "fs-0123456789abcdef0.efs.us-west-2.amazonaws.com" }
  }

  assert {
    condition     = output.jupyterhub_namespace != null
    error_message = "jupyterhub namespace should exist when enable_jupyterhub = true"
  }
  assert {
    condition     = strcontains(helm_release.jupyterhub_shared_volume["jupyterhub-home"].values[0], "fs-0123456789abcdef0.efs.us-west-2.amazonaws.com")
    error_message = "nfs_server must reach the shared-volume chart"
  }
  assert {
    condition     = length(helm_release.jupyterhub_shared_volume) == 2
    error_message = "one claim for homes and one for the shared directory"
  }
  assert {
    condition     = output.service_accounts.jupyterhub.name == "jupyterhub-single-user"
    error_message = "the single-user ServiceAccount name is part of the identity contract"
  }
}

# Dynamic RWX mode with OIDC auth and a projected token for the notebooks.
run "jupyterhub_storage_class_oidc_auth" {
  command = plan

  variables {
    enable_jupyterhub         = true
    jupyterhub_shared_storage = { storage_class_name = "standard", size = "20Gi" }

    jupyterhub_auth_mechanism     = "oidc"
    jupyterhub_oidc_client_id     = "test-client"
    jupyterhub_oidc_client_secret = "test-secret"
    jupyterhub_oidc_callback_url  = "https://hub.example.ts.net/hub/oauth_callback"
    jupyterhub_oidc_authorize_url = "https://accounts.google.com/o/oauth2/v2/auth"
    jupyterhub_oidc_token_url     = "https://oauth2.googleapis.com/token"
    jupyterhub_oidc_userdata_url  = "https://openidconnect.googleapis.com/v1/userinfo"
    jupyterhub_oidc_login_service = "Google"
    jupyterhub_allowed_users      = ["ada@example.com"]
    jupyterhub_admin_users        = ["ada@example.com"]

    workload_identity = {
      jupyterhub = {
        env             = { AWS_ROLE_ARN = "arn:aws:iam::123456789012:role/jhub" }
        projected_token = { audience = "sts.amazonaws.com" }
      }
    }
  }

  assert {
    condition     = output.jupyterhub_namespace != null
    error_message = "jupyterhub should render with oidc auth"
  }
  assert {
    condition     = strcontains(helm_release.jupyterhub_shared_volume["jupyterhub-home"].values[0], "\"storageClassName\": \"standard\"") && strcontains(helm_release.jupyterhub_shared_volume["jupyterhub-home"].values[0], "\"size\": \"20Gi\"")
    error_message = "storage_class_name and size must reach the shared-volume chart"
  }
}

run "jupyterhub_requires_exactly_one_storage_mode" {
  command = plan

  variables {
    enable_jupyterhub         = true
    jupyterhub_user_password  = "x"
    jupyterhub_shared_storage = {}
  }

  expect_failures = [var.jupyterhub_shared_storage]
}

run "jupyterhub_firstuse_auth_with_overrides" {
  command = plan

  variables {
    enable_jupyterhub         = true
    jupyterhub_shared_storage = { nfs_server = "10.0.0.5", nfs_path = "/export/jhub" }
    jupyterhub_auth_mechanism = "firstuse"
    jupyterhub_admin_users    = ["ada"]
    jupyterhub_allowed_users  = ["ada", "grace"]
    jupyterhub_extra_values   = ["singleuser:\n  startTimeout: 300\n"]
  }

  assert {
    condition     = strcontains(helm_release.jupyterhub_shared_volume["jupyterhub-shared"].values[0], "\"path\": \"/export/jhub\"")
    error_message = "nfs_path must reach the shared-volume chart"
  }
}

# Dagster requires Ray (an explicit precondition, not a silent coupling): with
# both on, both namespaces come up, and the scheduling + identity contracts
# render into the chart values.
run "dagster_requires_ray_and_renders_contracts" {
  command = plan

  variables {
    enable_ray          = true
    enable_dagster      = true
    dagster_db_host     = "db.example.com"
    dagster_db_name     = "dagster"
    dagster_db_user     = "dagster"
    dagster_db_password = "test"
    scheduling = {
      dagster = {
        node_selector = { "karpenter.sh/nodepool" = "default" }
        tolerations   = [{ key = "workload", value = "dagster", effect = "NoSchedule" }]
      }
    }
    workload_identity = {
      dagster = { env = { AWS_REGION = "us-west-2" } }
      ray     = { env = { AWS_REGION = "us-west-2", AWS_ENDPOINT_URL = "http://seaweedfs:8333" } }
    }
  }

  assert {
    condition     = output.ray_namespace != null
    error_message = "ray namespace should exist when enable_ray = true"
  }
  assert {
    condition     = output.dagster_namespace != null
    error_message = "dagster namespace should exist when enable_dagster = true (with ray)"
  }
  assert {
    condition     = strcontains(helm_release.dagster[0].values[0], "\"karpenter.sh/nodepool\":\"default\"")
    error_message = "scheduling.dagster.node_selector must render into the Dagster values"
  }
  assert {
    condition     = strcontains(helm_release.dagster[0].values[0], "\"effect\":\"NoSchedule\"") && !strcontains(helm_release.dagster[0].values[0], "null")
    error_message = "tolerations must render with null attributes dropped"
  }
  assert {
    condition     = strcontains(helm_release.dagster[0].values[0], "- name: dagster-identity-env")
    error_message = "the Dagster identity Secret must be envFrom'd"
  }
  assert {
    condition     = kubernetes_config_map_v1.analytics_config[0].data["AWS_ENDPOINT_URL"] == "http://seaweedfs:8333"
    error_message = "workload_identity.ray.env must land in the analytics-config ConfigMap for user-code RayJobs"
  }
  assert {
    condition     = output.identity_secret_names.ray == "ray-identity-env"
    error_message = "the ray identity Secret name is part of the contract"
  }
}

run "ray_cluster_keeps_log_volume_and_places_head" {
  command = plan

  variables {
    enable_ray         = true
    enable_ray_cluster = true
    scheduling = {
      ray_head   = { node_selector = { "karpenter.sh/nodepool" = "ray-head" } }
      ray_worker = { node_selector = { "karpenter.sh/nodepool" = "ray-worker" } }
    }
    workload_identity = {
      ray = { projected_token = { audience = "sts.amazonaws.com" } }
    }
  }

  assert {
    condition     = strcontains(helm_release.ray_cluster[0].values[0], "log-volume") && strcontains(helm_release.ray_cluster[0].values[0], "workload-identity-token")
    error_message = "the chart's log volume must survive alongside the projected token volume"
  }
  assert {
    condition     = strcontains(helm_release.ray_cluster[0].values[0], "\"karpenter.sh/nodepool\":\"ray-worker\"")
    error_message = "scheduling.ray_worker must render into the worker group"
  }
  assert {
    condition     = strcontains(helm_release.ray_cluster[0].values[0], "fullnameOverride: ray-cluster")
    error_message = "the RayCluster must be named after the release so the dashboard Service selector matches its head"
  }
}

# Public ingress is generic: class + annotations from the caller, external-dns
# hostname stamped, optional cert-manager TLS secret.
run "webapp_public_ingress_generic" {
  command = plan

  variables {
    enable_webapp                        = true
    webapp_image                         = "public.ecr.aws/nginx/nginx:latest"
    enable_webapp_public_ingress         = true
    webapp_public_host                   = "app.example.com"
    webapp_public_ingress_class_name     = "nginx"
    webapp_public_ingress_annotations    = { "cert-manager.io/cluster-issuer" = "letsencrypt" }
    webapp_public_tls_secret_name        = "app-tls"
    webapp_public_wait_for_load_balancer = false
    auth                                 = { mode = "none" }
  }

  assert {
    condition     = kubernetes_ingress_v1.webapp_public[0].spec[0].ingress_class_name == "nginx"
    error_message = "the public IngressClass must be the caller's"
  }
  assert {
    condition     = kubernetes_ingress_v1.webapp_public[0].metadata[0].annotations["external-dns.alpha.kubernetes.io/hostname"] == "app.example.com"
    error_message = "the public host must be stamped for external-dns"
  }
  assert {
    condition     = kubernetes_ingress_v1.webapp_public[0].metadata[0].annotations["cert-manager.io/cluster-issuer"] == "letsencrypt"
    error_message = "caller annotations must be merged onto the public Ingress"
  }
  assert {
    condition     = kubernetes_ingress_v1.webapp_public[0].spec[0].tls[0].secret_name == "app-tls"
    error_message = "webapp_public_tls_secret_name must add a tls block"
  }
  assert {
    condition     = output.webapp_public_url == "https://app.example.com" && output.webapp_public_ingress.name == "webapp-public"
    error_message = "public URL and Ingress identity outputs"
  }
}

run "webapp_public_ingress_requires_class" {
  command = plan

  variables {
    enable_webapp                = true
    webapp_image                 = "public.ecr.aws/nginx/nginx:latest"
    enable_webapp_public_ingress = true
    webapp_public_host           = "app.example.com"
  }

  expect_failures = [var.webapp_public_ingress_class_name]
}

run "identity_rejects_unknown_service" {
  command = plan

  variables {
    workload_identity = { nope = {} }
  }

  expect_failures = [var.workload_identity]
}

# Argo is per environment like Dagster/MLflow: its own namespace, a
# namespace-scoped release that installs no CRDs, the workflow SA as the
# identity subject, an optional archive on the environment's database, and a
# private Ingress on the same class as the other UIs.
run "argo_per_environment_with_archive" {
  command = plan

  variables {
    enable_argo_workflows        = true
    enable_argo_workflow_archive = true
    argo_db_host                 = "db.example.com"
    argo_db_name                 = "argo"
    argo_db_user                 = "argo"
    argo_db_password             = "test"
    name_prefix                  = "pr3-"
    enable_private_ingress       = true
    private_ingress_annotations  = { argo = { "tailscale.com/tags" = "tag:svc-argo" } }
    workload_identity = {
      argo = { service_account_annotations = { "eks.amazonaws.com/role-arn" = "arn:aws:iam::123456789012:role/argo" } }
    }
  }

  assert {
    condition     = output.argo_namespace == "pr3-argo" && output.service_accounts.argo.namespace == "pr3-argo" && output.service_accounts.argo.name == "argo-workflow"
    error_message = "Argo gets its own prefixed namespace and the argo-workflow subject lives there"
  }
  assert {
    condition     = strcontains(helm_release.argo_workflows[0].values[0], "singleNamespace: true") && strcontains(helm_release.argo_workflows[0].values[0], "install: false")
    error_message = "the per-environment release must be namespace-scoped and must not install CRDs"
  }
  assert {
    condition     = strcontains(helm_release.argo_workflows[0].values[0], "archive: true") && strcontains(helm_release.argo_workflows[0].values[0], "host: db.example.com") && strcontains(helm_release.argo_workflows[0].values[0], "sslMode: require")
    error_message = "the workflow archive must point at the environment's database"
  }
  assert {
    condition     = strcontains(helm_release.argo_workflows[0].values[0], "serviceType: ClusterIP")
    error_message = "the Argo server must never be a LoadBalancer Service"
  }
  assert {
    condition     = kubernetes_service_account_v1.argo_workflow[0].metadata[0].annotations["eks.amazonaws.com/role-arn"] == "arn:aws:iam::123456789012:role/argo"
    error_message = "workload_identity.argo must annotate the workflow ServiceAccount"
  }
  assert {
    condition     = kubernetes_ingress_v1.argo_private[0].metadata[0].annotations["tailscale.com/tags"] == "tag:svc-argo" && kubernetes_ingress_v1.argo_private[0].spec[0].default_backend[0].service[0].name == "pr3-argo-server"
    error_message = "the Argo UI Ingress must carry the argo annotations and point at the release's server Service"
  }
  assert {
    condition     = output.argo_private_url == "https://argo.<your-suffix>"
    error_message = "argo_private_url follows the private hostname convention"
  }
}

run "argo_archive_requires_db" {
  command = plan

  variables {
    enable_argo_workflows        = true
    enable_argo_workflow_archive = true
  }

  expect_failures = [var.enable_argo_workflow_archive]
}

run "argo_without_archive_or_ray" {
  command = plan

  variables {
    enable_argo_workflows = true
  }

  assert {
    condition     = output.argo_namespace == "argo" && !strcontains(helm_release.argo_workflows[0].values[0], "persistence:")
    error_message = "Argo stands alone (no Ray, no archive) and renders without a persistence block"
  }
}

# Stamp or share: with a service off, its URL override reaches every pod that
# runs code; with it on, the in-cluster URL does, and the override is refused.
run "app_only_preview_shares_prod_services" {
  command = plan

  variables {
    name_prefix           = "pr9-"
    enable_webapp         = true
    webapp_image          = "public.ecr.aws/nginx/nginx:latest"
    enable_ray            = true
    enable_dagster        = false
    dagster_webserver_url = "http://dagster-dagster-webserver.dagster.svc.cluster.local:80"
    enable_mlflow         = false
    mlflow_tracking_uri   = "http://mlflow.mlflow.svc.cluster.local:80"
  }

  assert {
    condition     = { for e in kubernetes_deployment_v1.webapp[0].spec[0].template[0].spec[0].container[0].env : e.name => e.value }["DAGSTER_WEBSERVER_URL"] == "http://dagster-dagster-webserver.dagster.svc.cluster.local:80"
    error_message = "the webapp must see the shared Dagster URL"
  }
  assert {
    condition     = kubernetes_config_map_v1.analytics_config[0].data["MLFLOW_TRACKING_URI"] == "http://mlflow.mlflow.svc.cluster.local:80"
    error_message = "pipeline pods must see the shared MLflow URL through analytics-config"
  }
  assert {
    condition     = output.in_cluster_urls.dagster_webserver_url == null && output.in_cluster_urls.mlflow_tracking_uri == null && output.dagster_namespace == null
    error_message = "a sharing environment creates nothing for the shared service and publishes no URL of its own"
  }
}

run "stamped_services_publish_their_own_urls" {
  command = plan

  variables {
    name_prefix         = "pr9-"
    enable_ray          = true
    enable_dagster      = true
    dagster_db_host     = "db.example.com"
    dagster_db_name     = "dagster"
    dagster_db_user     = "dagster"
    dagster_db_password = "test"
    enable_mlflow       = true
    mlflow_db_host      = "db.example.com"
    mlflow_db_name      = "mlflow"
    mlflow_db_user      = "mlflow"
    mlflow_db_password  = "test"
  }

  assert {
    condition     = output.in_cluster_urls.dagster_webserver_url == "http://pr9-dagster-dagster-webserver.pr9-dagster.svc.cluster.local:80" && output.in_cluster_urls.mlflow_tracking_uri == "http://pr9-mlflow.pr9-mlflow.svc.cluster.local:80"
    error_message = "in_cluster_urls must name this environment's own, prefixed services"
  }
  assert {
    condition     = kubernetes_config_map_v1.analytics_config[0].data["DAGSTER_WEBSERVER_URL"] == "http://pr9-dagster-dagster-webserver.pr9-dagster.svc.cluster.local:80"
    error_message = "stamped services reach pipeline pods under the same variable names as shared ones"
  }
}

run "override_refused_when_service_is_stamped" {
  command = plan

  variables {
    enable_mlflow       = true
    mlflow_tracking_uri = "http://mlflow.elsewhere.svc.cluster.local:80"
  }

  expect_failures = [var.mlflow_tracking_uri]
}

# ------------------------------------------------------------------------------
# AUTH (var.auth): headers mode deploys nothing; oidc mode registers Dex
# clients, fronts the protected UIs with oauth2-proxy (gated per service),
# turns on Argo's native SSO and hands the webapp its OIDC_* env.
# ------------------------------------------------------------------------------

run "auth_headers_mode_deploys_nothing" {
  command = plan

  variables {
    enable_webapp              = true
    webapp_image               = "nginx"
    enable_ray                 = true
    enable_dagster             = true
    dagster_db_host            = "db.example.com"
    dagster_db_name            = "dagster"
    dagster_db_user            = "dagster"
    dagster_db_password        = "test"
    enable_private_ingress     = true
    private_ingress_dns_suffix = "tail1234.ts.net"
    auth                       = { identity_groups_header = "Tailscale-User-Groups" }
  }

  assert {
    condition     = length(kubernetes_deployment_v1.oauth2_proxy) == 0 && length(kubectl_manifest.dex_client) == 0 && length(random_password.auth_client) == 0
    error_message = "headers mode must deploy no proxies and register no clients"
  }
  assert {
    condition     = kubernetes_ingress_v1.dagster_private[0].spec[0].default_backend[0].service[0].name == "dagster-dagster-webserver"
    error_message = "the private Ingress keeps pointing at the service itself"
  }
  assert {
    condition     = local.webapp_plain_env["AUTH_MODE"] == "headers" && local.webapp_plain_env["IDENTITY_HEADER"] == "Tailscale-User-Login" && local.webapp_plain_env["IDENTITY_GROUPS_HEADER"] == "Tailscale-User-Groups"
    error_message = "the webapp learns the mode and which headers to trust"
  }
  assert {
    condition     = output.auth.mode == "headers" && length(output.auth.clients) == 0
    error_message = "output.auth reports the mode and no clients"
  }
}

run "auth_oidc_with_dex" {
  command = plan

  variables {
    name_prefix                     = "pr7-"
    private_ingress_hostname_prefix = "pr7-"
    enable_webapp                   = true
    webapp_image                    = "nginx"
    enable_ray                      = true
    enable_dagster                  = true
    dagster_db_host                 = "db.example.com"
    dagster_db_name                 = "dagster"
    dagster_db_user                 = "dagster"
    dagster_db_password             = "test"
    enable_mlflow                   = true
    mlflow_db_host                  = "db.example.com"
    mlflow_db_name                  = "mlflow"
    mlflow_db_user                  = "mlflow"
    mlflow_db_password              = "test"
    enable_argo_workflows           = true
    enable_private_ingress          = true
    private_ingress_dns_suffix      = "tail1234.ts.net"
    auth = {
      mode          = "oidc"
      issuer_url    = "http://dex.dex.svc.cluster.local:5556/dex"
      dex_namespace = "dex"
      protect = {
        dagster = { allowed_groups = ["authors"] }
        mlflow  = { allowed_emails = ["a@example.com", "b@example.com"] }
      }
      argo_rbac_rules = {
        admins   = { rule = "'platform' in groups", access = "write", precedence = 10 }
        everyone = { rule = "true", access = "read" }
      }
    }
  }

  # Clients: proxies (one client, both redirect URIs), Argo, the webapp; no
  # JupyterHub since it is off.
  assert {
    condition     = sort(keys(kubectl_manifest.dex_client)) == tolist(["argo", "oauth2-proxy", "webapp"])
    error_message = "one Dex client per relying party this environment runs"
  }
  assert {
    condition     = output.auth.clients["oauth2-proxy"].client_id == "pr7-oauth2-proxy" && output.auth.clients["oauth2-proxy"].dex_object == "obzdollpmf2xi2bsfvyhe33yphf7fhheqqrcgji"
    error_message = "Dex names the OAuth2Client base32(id ++ fnv64 offset basis), lowercase, unpadded (pr7-oauth2-proxy -> obzdollpmf2xi2bsfvyhe33yphf7fhheqqrcgji)"
  }
  assert {
    condition     = output.auth.clients["argo"].dex_object == "obzdollbojtw7s7sttsiiirdeu" && output.auth.clients["webapp"].dex_object == "obzdollxmvrgc4dqzpzjzzeeeirsk"
    error_message = "base32 known vectors for pr7-argo and pr7-webapp"
  }
  assert {
    condition     = output.auth.clients["oauth2-proxy"].redirect_uris == ["https://pr7-dagster.tail1234.ts.net/oauth2/callback", "https://pr7-mlflow.tail1234.ts.net/oauth2/callback"]
    error_message = "the proxy client's redirect URIs are the private hostnames of the protected services"
  }
  assert {
    condition     = output.auth.clients["argo"].redirect_uris == ["https://pr7-argo.tail1234.ts.net/oauth2/callback"] && output.auth.clients["webapp"].redirect_uris == ["https://pr7-webapp.tail1234.ts.net/auth/callback"]
    error_message = "Argo and the webapp get their own redirect URIs"
  }

  # Proxies: only the protected, enabled services; ray is enabled but not in protect.
  assert {
    condition     = sort(keys(kubernetes_deployment_v1.oauth2_proxy)) == tolist(["dagster", "mlflow"]) && output.auth.proxied_services == tolist(["dagster", "mlflow"])
    error_message = "a proxy per protected service, none for services absent from protect"
  }
  assert {
    condition     = contains(kubernetes_deployment_v1.oauth2_proxy["dagster"].spec[0].template[0].spec[0].container[0].args, "--allowed-group=authors") && contains(kubernetes_deployment_v1.oauth2_proxy["dagster"].spec[0].template[0].spec[0].container[0].args, "--oidc-groups-claim=groups")
    error_message = "the Dagster proxy enforces its group gate"
  }
  assert {
    condition     = !anytrue([for a in kubernetes_deployment_v1.oauth2_proxy["mlflow"].spec[0].template[0].spec[0].container[0].args : startswith(a, "--allowed-group=")]) && contains(kubernetes_deployment_v1.oauth2_proxy["mlflow"].spec[0].template[0].spec[0].container[0].args, "--authenticated-emails-file=/etc/oauth2-proxy/emails.txt")
    error_message = "the MLflow proxy gates on the explicit email list, not groups"
  }
  assert {
    condition     = kubernetes_config_map_v1.oauth2_proxy_emails["mlflow"].data["emails.txt"] == "a@example.com\nb@example.com" && length(kubernetes_config_map_v1.oauth2_proxy_emails) == 1
    error_message = "the email list is a ConfigMap only where one is set"
  }
  assert {
    condition     = contains(kubernetes_deployment_v1.oauth2_proxy["dagster"].spec[0].template[0].spec[0].container[0].args, "--upstream=http://pr7-dagster-dagster-webserver.pr7-dagster.svc.cluster.local:80") && contains(kubernetes_deployment_v1.oauth2_proxy["dagster"].spec[0].template[0].spec[0].container[0].args, "--redirect-url=https://pr7-dagster.tail1234.ts.net/oauth2/callback") && !anytrue([for a in kubernetes_deployment_v1.oauth2_proxy["dagster"].spec[0].template[0].spec[0].container[0].args : startswith(a, "--cookie-domain")])
    error_message = "the proxy fronts the service, redirects to the private hostname, and keeps its cookie host-only"
  }
  assert {
    condition     = alltrue([for a in ["--cookie-refresh=1h", "--cookie-expire=24h", "--scope=openid email profile groups offline_access"] : contains(kubernetes_deployment_v1.oauth2_proxy["dagster"].spec[0].template[0].spec[0].container[0].args, a)])
    error_message = "proxy sessions refresh hourly (a refresh token from Dex's offline_access) and end within a day"
  }
  assert {
    condition     = contains(kubernetes_deployment_v1.oauth2_proxy["dagster"].spec[0].template[0].spec[0].container[0].args, "--email-domain=*") && !anytrue([for a in kubernetes_deployment_v1.oauth2_proxy["mlflow"].spec[0].template[0].spec[0].container[0].args : startswith(a, "--email-domain")])
    error_message = "a group gate authenticates any domain and authorizes by group; an email gate authenticates by the list alone"
  }
  assert {
    condition     = kubernetes_ingress_v1.dagster_private[0].spec[0].default_backend[0].service[0].name == "dagster-auth" && kubernetes_ingress_v1.mlflow_private[0].spec[0].default_backend[0].service[0].name == "mlflow-auth" && kubernetes_ingress_v1.ray_dashboard_private[0].spec[0].default_backend[0].service[0].name == "ray-dashboard"
    error_message = "protected Ingresses point at the proxy; unprotected ones at the service"
  }

  # Argo: native SSO + one rbac ServiceAccount per rule.
  assert {
    condition     = strcontains(helm_release.argo_workflows[0].values[0], "- sso") && strcontains(helm_release.argo_workflows[0].values[0], "redirectUrl: \"https://pr7-argo.tail1234.ts.net/oauth2/callback\"") && !strcontains(helm_release.argo_workflows[0].values[0], "- server")
    error_message = "Argo switches to its native SSO"
  }
  assert {
    condition     = kubernetes_service_account_v1.argo_sso["admins"].metadata[0].annotations["workflows.argoproj.io/rbac-rule"] == "'platform' in groups" && kubernetes_service_account_v1.argo_sso["admins"].metadata[0].annotations["workflows.argoproj.io/rbac-rule-precedence"] == "10" && kubernetes_service_account_v1.argo_sso["everyone"].metadata[0].annotations["workflows.argoproj.io/rbac-rule-precedence"] == "0"
    error_message = "each rule's precedence is the one given (Argo tries the highest first), not derived from its name"
  }
  assert {
    condition     = contains(kubernetes_role_v1.argo_sso["write"].rule[0].verbs, "create") && !contains(kubernetes_role_v1.argo_sso["read"].rule[0].verbs, "create") && [for s in kubernetes_role_binding_v1.argo_sso["read"].subject : s.name] == ["argo-ui-everyone"] && [for s in kubernetes_role_binding_v1.argo_sso["write"].subject : s.name] == ["argo-ui-admins"]
    error_message = "read and write are separate Roles and each rule's ServiceAccount is bound to its own level"
  }

  # The webapp runs its own login.
  assert {
    condition     = local.webapp_plain_env["AUTH_MODE"] == "oidc" && local.webapp_plain_env["COOKIE_SECURE"] == "true" && local.webapp_plain_env["OIDC_ISSUER_URL"] == "http://dex.dex.svc.cluster.local:5556/dex" && local.webapp_plain_env["OIDC_CLIENT_ID"] == "pr7-webapp" && local.webapp_plain_env["OIDC_REDIRECT_URL"] == "https://pr7-webapp.tail1234.ts.net/auth/callback" && !contains(keys(local.webapp_plain_env), "IDENTITY_HEADER")
    error_message = "the webapp gets its mode, Secure cookies, OIDC_* env and no header hint"
  }
  assert {
    condition     = contains(keys(kubernetes_secret_v1.webapp_env[0].data), "OIDC_CLIENT_SECRET") && contains(keys(kubernetes_secret_v1.webapp_env[0].data), "SESSION_SECRET")
    error_message = "the webapp's client and session secrets land in its env Secret"
  }
}

run "auth_oidc_without_ingress_uses_cluster_urls" {
  command = plan

  variables {
    enable_ray          = true
    enable_dagster      = true
    dagster_db_host     = "db.example.com"
    dagster_db_name     = "dagster"
    dagster_db_user     = "dagster"
    dagster_db_password = "test"
    auth = {
      mode                  = "oidc"
      issuer_url            = "http://dex.dex.svc.cluster.local:5556/dex"
      dex_namespace         = "dex"
      protect               = { dagster = {}, ray = {} }
      allowed_email_domains = ["*"]
      cookie_secure         = false
      external_scheme       = "http"
    }
  }

  assert {
    condition     = output.auth.clients["oauth2-proxy"].redirect_uris == ["http://dagster-auth.dagster.svc.cluster.local/oauth2/callback", "http://ray-auth.ray.svc.cluster.local/oauth2/callback"]
    error_message = "without a private Ingress the redirect URIs are the in-cluster proxy Services (kind)"
  }
  assert {
    condition     = length(kubernetes_service_v1.ray_dashboard) == 1
    error_message = "the Ray dashboard Service exists as the proxy's upstream even without a private Ingress"
  }
  assert {
    condition     = contains(kubernetes_deployment_v1.oauth2_proxy["dagster"].spec[0].template[0].spec[0].container[0].args, "--cookie-secure=false") && !anytrue([for a in kubernetes_deployment_v1.oauth2_proxy["dagster"].spec[0].template[0].spec[0].container[0].args : startswith(a, "--allowed-group=")])
    error_message = "an explicit [\"*\"] admits any authenticated user; cookie_secure follows the variable"
  }
}

run "auth_oidc_bring_your_own_clients" {
  command = plan

  variables {
    enable_ray          = true
    enable_dagster      = true
    dagster_db_host     = "db.example.com"
    dagster_db_name     = "dagster"
    dagster_db_user     = "dagster"
    dagster_db_password = "test"
    auth = {
      mode                  = "oidc"
      issuer_url            = "https://accounts.google.com"
      protect               = { dagster = {} }
      allowed_email_domains = ["example.com"]
      clients               = { oauth2-proxy = { client_id = "123.apps.googleusercontent.com", client_secret = "shh" } }
      scopes                = ["openid", "email", "profile"]
    }
  }

  assert {
    condition     = length(kubectl_manifest.dex_client) == 0 && length(random_password.auth_client) == 0
    error_message = "no Dex registration when the clients are brought"
  }
  assert {
    condition     = contains(kubernetes_deployment_v1.oauth2_proxy["dagster"].spec[0].template[0].spec[0].container[0].args, "--client-id=123.apps.googleusercontent.com") && kubernetes_secret_v1.oauth2_proxy["dagster"].data["client-secret"] == "shh" && output.auth.clients["oauth2-proxy"].dex_object == null
    error_message = "the brought client feeds the proxy"
  }
  assert {
    condition     = contains(kubernetes_deployment_v1.oauth2_proxy["dagster"].spec[0].template[0].spec[0].container[0].args, "--scope=openid email profile")
    error_message = "scopes follow the variable (no groups scope for issuers that lack it)"
  }
}

run "auth_oidc_missing_brought_client_is_refused" {
  command = plan

  variables {
    enable_ray          = true
    enable_dagster      = true
    dagster_db_host     = "db.example.com"
    dagster_db_name     = "dagster"
    dagster_db_user     = "dagster"
    dagster_db_password = "test"
    auth = {
      mode       = "oidc"
      issuer_url = "https://accounts.google.com"
      protect    = { dagster = {} }
    }
  }

  expect_failures = [kubernetes_secret_v1.oauth2_proxy]
}

run "auth_oidc_requires_issuer" {
  command = plan

  variables {
    auth = { mode = "oidc" }
  }

  expect_failures = [var.auth]
}

# ------------------------------------------------------------------------------
# Default-deny, token-verifying webapp, and the network fence
# ------------------------------------------------------------------------------

run "auth_open_gate_is_refused" {
  command = plan

  variables {
    enable_ray          = true
    enable_dagster      = true
    dagster_db_host     = "db.example.com"
    dagster_db_name     = "dagster"
    dagster_db_user     = "dagster"
    dagster_db_password = "test"
    auth = {
      mode          = "oidc"
      issuer_url    = "http://dex.dex.svc.cluster.local:5556/dex"
      dex_namespace = "dex"
      protect       = { dagster = {} }
    }
  }

  expect_failures = [kubernetes_secret_v1.oauth2_proxy]
}

run "argo_sso_without_rules_is_refused" {
  command = plan

  variables {
    enable_argo_workflows = true
    auth = {
      mode          = "oidc"
      issuer_url    = "http://dex.dex.svc.cluster.local:5556/dex"
      dex_namespace = "dex"
      protect       = {}
    }
  }

  expect_failures = [kubernetes_secret_v1.argo_sso]
}

run "proxied_webapp_verifies_the_proxy_token" {
  command = plan

  variables {
    enable_webapp       = true
    webapp_image        = "nginx"
    enable_ray          = true
    enable_dagster      = true
    dagster_db_host     = "db.example.com"
    dagster_db_name     = "dagster"
    dagster_db_user     = "dagster"
    dagster_db_password = "test"
    auth = {
      mode          = "oidc"
      issuer_url    = "http://dex.dex.svc.cluster.local:5556/dex"
      dex_namespace = "dex"
      protect = {
        webapp  = { allowed_groups = ["lab"] }
        dagster = { allowed_groups = ["lab"] }
      }
    }
  }

  assert {
    condition     = local.webapp_plain_env["AUTH_PROXIED"] == "1" && local.webapp_plain_env["IDENTITY_JWT_ISSUER"] == "http://dex.dex.svc.cluster.local:5556/dex" && local.webapp_plain_env["IDENTITY_JWT_AUDIENCE"] == "oauth2-proxy" && !contains(keys(local.webapp_plain_env), "IDENTITY_HEADER")
    error_message = "a proxied webapp verifies the proxy's ID token (issuer + the proxy client as audience) and trusts no forwarded header"
  }
  assert {
    condition     = contains(kubernetes_deployment_v1.oauth2_proxy["webapp"].spec[0].template[0].spec[0].container[0].args, "--pass-authorization-header=true") && !contains(kubernetes_deployment_v1.oauth2_proxy["dagster"].spec[0].template[0].spec[0].container[0].args, "--pass-authorization-header=true")
    error_message = "only the webapp's proxy forwards the ID token"
  }
  assert {
    condition     = length(kubectl_manifest.dex_client) == 1 && contains(keys(kubectl_manifest.dex_client), "oauth2-proxy")
    error_message = "a proxied webapp needs no client of its own"
  }
}

run "public_webapp_in_headers_mode_is_refused" {
  command = plan

  variables {
    enable_webapp                        = true
    webapp_image                         = "nginx"
    enable_webapp_public_ingress         = true
    webapp_public_host                   = "app.example.com"
    webapp_public_ingress_class_name     = "nginx"
    webapp_public_wait_for_load_balancer = false
  }

  expect_failures = [kubernetes_ingress_v1.webapp_public]
}

run "network_fence_in_headers_mode" {
  command = plan

  variables {
    enable_webapp         = true
    webapp_image          = "nginx"
    enable_ray            = true
    enable_dagster        = true
    dagster_db_host       = "db.example.com"
    dagster_db_name       = "dagster"
    dagster_db_user       = "dagster"
    dagster_db_password   = "test"
    enable_mlflow         = true
    mlflow_db_host        = "db.example.com"
    mlflow_db_name        = "mlflow"
    mlflow_db_user        = "mlflow"
    mlflow_db_password    = "test"
    enable_argo_workflows = true
  }

  assert {
    condition     = sort(keys(kubernetes_network_policy_v1.upstream)) == tolist(["argo", "dagster", "mlflow", "ray", "webapp"]) && length(kubernetes_network_policy_v1.front_door) == 0
    error_message = "every UI service is fenced; with no proxies there is no front-door policy"
  }
  assert {
    # the webapp trusts Tailscale-User-Login: only the tailnet Ingress (and its own namespace) may reach it
    condition     = length(kubernetes_network_policy_v1.upstream["webapp"].spec[0].ingress[0].from) == 2 && kubernetes_network_policy_v1.upstream["webapp"].spec[0].ingress[0].from[1].namespace_selector[0].match_expressions[0].values == toset(["tailscale"])
    error_message = "the header-trusting webapp admits only its namespace and the ingress namespace"
  }
  assert {
    condition     = kubernetes_network_policy_v1.upstream["dagster"].spec[0].ingress[0].from[1].namespace_selector[0].match_expressions[0].key == "lab-platform.io/service" && kubernetes_network_policy_v1.upstream["dagster"].spec[0].ingress[0].from[1].namespace_selector[0].match_expressions[0].values == toset(["webapp"])
    error_message = "Dagster admits the webapp (it triggers runs), by service label so any environment's webapp qualifies"
  }
  assert {
    condition     = kubernetes_network_policy_v1.upstream["ray"].spec[0].ingress[0].from[2].namespace_selector[0].match_expressions[0].values == toset(["kuberay-system"])
    error_message = "the KubeRay operator reaches the Ray head"
  }
  assert {
    condition     = kubernetes_namespace_v1.dagster[0].metadata[0].labels["lab-platform.io/service"] == "dagster"
    error_message = "namespaces carry the service label policies select on"
  }
}

run "network_fence_in_oidc_mode" {
  command = plan

  variables {
    enable_ray          = true
    enable_dagster      = true
    dagster_db_host     = "db.example.com"
    dagster_db_name     = "dagster"
    dagster_db_user     = "dagster"
    dagster_db_password = "test"
    network_policies    = { ingress_namespaces = ["ingress-nginx"] }
    auth = {
      mode          = "oidc"
      issuer_url    = "http://dex.dex.svc.cluster.local:5556/dex"
      dex_namespace = "dex"
      protect       = { dagster = { allowed_groups = ["lab"] } }
    }
  }

  assert {
    condition     = !anytrue([for f in kubernetes_network_policy_v1.upstream["dagster"].spec[0].ingress[0].from : length(f.namespace_selector) > 0 && contains(tolist(f.namespace_selector[0].match_expressions[0].values), "ingress-nginx")])
    error_message = "a proxied service's own pods are not reachable from the ingress: only its proxy is"
  }
  assert {
    condition     = kubernetes_network_policy_v1.front_door["dagster"].spec[0].pod_selector[0].match_labels["app"] == "dagster-auth" && kubernetes_network_policy_v1.front_door["dagster"].spec[0].ingress[0].from[0].namespace_selector[0].match_expressions[0].values == toset(["ingress-nginx"])
    error_message = "the proxy admits only the ingress namespace"
  }
}

run "network_fence_can_be_disabled" {
  command = plan

  variables {
    enable_webapp    = true
    webapp_image     = "nginx"
    network_policies = { enabled = false }
  }

  assert {
    condition     = length(kubernetes_network_policy_v1.upstream) == 0
    error_message = "network_policies.enabled = false creates no policies"
  }
}

run "jupyterhub_follows_the_auth_mode" {
  command = plan

  variables {
    enable_jupyterhub         = true
    jupyterhub_shared_storage = { storage_class_name = "standard" }
    jupyterhub_allowed_users  = ["ann@lab.org"]
    auth = {
      mode          = "oidc"
      issuer_url    = "http://dex.dex.svc.cluster.local:5556/dex"
      dex_namespace = "dex"
      protect       = {}
    }
  }

  assert {
    condition     = strcontains(helm_release.jupyterhub[0].values[0], "generic-oauth") && contains(keys(kubectl_manifest.dex_client), "jupyterhub")
    error_message = "with auth.mode = oidc JupyterHub logs in through the same issuer, with a Dex client registered for it"
  }
  assert {
    condition     = !strcontains(helm_release.jupyterhub[0].values[0], "allow_all: true")
    error_message = "a named user list, not allow_all"
  }
}

run "jupyterhub_oidc_admitting_nobody_is_refused" {
  command = plan

  variables {
    enable_jupyterhub         = true
    jupyterhub_shared_storage = { storage_class_name = "standard" }
    auth = {
      mode          = "oidc"
      issuer_url    = "http://dex.dex.svc.cluster.local:5556/dex"
      dex_namespace = "dex"
      protect       = {}
    }
  }

  expect_failures = [helm_release.jupyterhub]
}
