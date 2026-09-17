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
run "mlflow_static_credentials_minio" {
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
          MLFLOW_S3_ENDPOINT_URL = "http://minio.minio.svc.cluster.local:9000"
        }
      }
    }
    workload_identity_secret_env = {
      mlflow = { AWS_ACCESS_KEY_ID = "minio", AWS_SECRET_ACCESS_KEY = "minio123" }
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
    condition     = strcontains(helm_release.mlflow[0].values[0], "minio.minio.svc.cluster.local:9000")
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
      ray     = { env = { AWS_REGION = "us-west-2", AWS_ENDPOINT_URL = "http://minio:9000" } }
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
    condition     = kubernetes_config_map_v1.analytics_config[0].data["AWS_ENDPOINT_URL"] == "http://minio:9000"
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
