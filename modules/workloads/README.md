# workloads

The application layer, deployed onto an **existing Kubernetes cluster** -- any
cluster: EKS, GKE, AKS, k3s on a GPU box, kind on a laptop -- and designed to
be instantiated **multiple times** against the same cluster with a distinct
`name_prefix`, which is what lets prod and any number of preview environments
coexist without namespace/release/hostname collisions.

Nothing in this module knows which cloud it runs on or where the data lives.
It requires only the `kubernetes`, `helm` and `kubectl` providers; everything
cloud-specific arrives through four **contract inputs**, produced by a backend
adapter or written by hand:

| Contract input | What it carries | AWS producer |
| --- | --- | --- |
| `workload_identity` (+ `workload_identity_secret_env`) | how each service's pods get data-backend credentials | [`aws/data-adapter`](../../aws/data-adapter) |
| `scheduling` | nodeSelector + tolerations per pod role | [`aws/compute-adapter`](../../aws/compute-adapter) |
| `jupyterhub_shared_storage` | the RWX volume behind home directories (NFS server or StorageClass) | `aws/compute-adapter` (EFS) |
| `webapp_public_ingress_class_name` / `_annotations` (and the JupyterHub twins) | the public edge | `aws/compute-adapter` (ALB + ACM + WAF) |

Per-service `enable_*` toggles:

- **webapp** -- a generic Deployment + Service + ServiceAccount, with an
  optional internet-facing Ingress (+ HPA, PodDisruptionBudget) or a private
  Ingress;
- **JupyterHub** -- namespace, shared RWX volume (two claims: homes, shared),
  ServiceAccount, Helm release, optional public Ingress;
- **Dagster** -- requires `enable_ray` (an explicit precondition, not a silent
  coupling);
- **MLflow** -- tracking server backed by external Postgres + an S3-compatible
  artifact root;
- **Argo Workflows** -- a namespace-scoped controller + server per
  environment with an optional workflow archive on external Postgres
  (`enable_argo_workflow_archive` + `argo_db_*`); the CRDs are a cluster
  prerequisite. Workflows run as `argo-workflow` and may drive RayJobs in the
  Ray namespace;
- **Ray** -- the Ray namespace/ServiceAccount and an optional persistent Ray
  cluster.

## Stamp or share

Kubernetes decides what *can* be per environment; you decide what *should*.

| Kind | Examples | Placement |
| --- | --- | --- |
| Operators and CRDs | KubeRay operator, Argo CRDs, Tailscale operator, LB controller | Always one per cluster (a CRD has one owner; two operators fight). Installed by the platform module. |
| The app under test | webapp, Dagster with the app's code location | Per environment: a preview exists to run *its* code. |
| Stateful services | MLflow, Dagster, Argo, JupyterHub | **Your call, per environment**: stamp one (`enable_x = true`) or share another environment's (`enable_x = false` + that environment's URL). |

Sharing is one input per service, fed from the other environment's
`in_cluster_urls` output:

```hcl
# prod stack
output "service_urls" { value = module.workloads.in_cluster_urls }

# preview stack: an app-only preview -- its own webapp and database branch,
# prod's Dagster/MLflow/Argo
module "workloads" {
  # ...
  enable_dagster        = false
  dagster_webserver_url = data.terraform_remote_state.prod.outputs.service_urls.dagster_webserver_url
  enable_mlflow         = false
  mlflow_tracking_uri   = data.terraform_remote_state.prod.outputs.service_urls.mlflow_tracking_uri
}
```

Either way the pods see the same variables -- `MLFLOW_TRACKING_URI`,
`DAGSTER_WEBSERVER_URL`, `ARGO_SERVER_URL` -- so application code never
knows which it got. What sharing costs you:

| Shared service | The preview gets | The preview gives up |
| --- | --- | --- |
| **MLflow** | prod's tracking UI and history; nothing to spin up | Isolation of tracking data: its experiments and artifacts land in prod's store and bucket (namespace them by experiment name). |
| **Dagster** | An app-only preview in ~2 minutes: no code-location image build, no Ray, no run pods | Any pipeline change goes untested. Runs the preview's app triggers execute **prod's code location against prod's database and data**; the preview's own `DATABASE_URL` (its Neon branch) is what the *webapp* reads, not what those runs write. Only use it when the change is confined to the app. |
| **Argo** | prod's workflow UI and archive | Workflows submitted through the shared server run in prod's namespace, as prod's `argo-workflow` identity, on prod's data. |
| **JupyterHub** | (share by simply not enabling it; notebooks live on the shared hub) | Nothing preview-specific to test in a hub anyway. |

The mixed state to be aware of is the Dagster one: an app-only preview is
"new frontend, prod backend". That is exactly right for a CSS change and
exactly wrong for a schema migration -- `examples/preview` exposes it as
`preview_profile = "app"`, and the template app maps it to a
`preview:app-only` PR label so the choice is visible on the PR.

## Cluster prerequisites

What the cluster must already provide, whoever built it:

| Need | Why | On EKS (`aws/eks-platform`) | Elsewhere |
| --- | --- | --- | --- |
| KubeRay operator | `enable_ray`, `enable_dagster` create RayCluster/RayJob objects | `enable_ray` | `helm install kuberay-operator kuberay/kuberay-operator` |
| Argo Workflows CRDs | `enable_argo_workflows` installs a namespace-scoped controller, never the cluster-scoped CRDs | `enable_argo_workflows` (installs the CRDs only) | `kubectl apply` the `manifests/base/crds/minimal` files of the matching Argo release (see `examples/kind/scripts/prereqs.sh`) |
| metrics-server | the public webapp HPA | on by default | most distros ship it; `kind` needs it installed |
| a private IngressClass | `enable_private_ingress` (default class `tailscale`) | Tailscale operator | Tailscale operator works anywhere; or any controller via `private_ingress_class_name` |
| a public IngressClass | `enable_webapp_public_ingress`, `jupyterhub_public_host` | AWS Load Balancer Controller (`alb`) | ingress-nginx + cert-manager; set the class/annotations/TLS secret inputs |
| RWX storage or an NFS server | JupyterHub home directories | EFS via `aws/compute-adapter` | Filestore, Azure Files, an NFS box, or a RWX StorageClass; kind's `standard` works on one node |
| a GPU device plugin | GPU pod roles in `scheduling` | NVIDIA GPU Operator toggle | NVIDIA GPU Operator / device plugin |
| registry pull access | your images | node role ECR pull | imagePullSecrets or a public registry |
| external-dns (optional) | public hostnames follow the Ingress | `enable_external_dns` | external-dns with your DNS provider |

## Identity contract

Pods run as fixed ServiceAccounts; a data-backend adapter trusts exactly these
subjects (`output.service_accounts` publishes them, `name_prefix` included):

| Service | Namespace | ServiceAccount | Pods |
| --- | --- | --- | --- |
| webapp | `<prefix><webapp_app_name>` | `<webapp_app_name>` | the webapp Deployment |
| dagster | `<prefix>dagster` | `dagster` | webserver, daemon, user code, launched runs |
| ray | `<prefix>ray` | `ray-s3-sa` | persistent Ray head/workers; RayJobs that user code launches with this SA |
| argo | `<prefix>argo` | `argo-workflow` | workflow pods (the controller/server run as chart-owned SAs) |
| mlflow | `<prefix>mlflow` | `mlflow` | the tracking server |
| jupyterhub | `<prefix>jupyterhub` | `jupyterhub-single-user` | every notebook server |

Three ways to bind credentials to those subjects, all through the same input:

- **Webhook identity** (compute and data in the same cloud): put the cloud's
  annotation in `service_account_annotations` -- `eks.amazonaws.com/role-arn`
  (IRSA), `iam.gke.io/gcp-service-account`, `azure.workload.identity/client-id`.
  Nothing changes in the pod spec.
- **Web-identity federation** (compute anywhere, data in a cloud that trusts
  the cluster's OIDC issuer): set `projected_token = { audience = "sts.amazonaws.com" }`
  and put `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE` in `env`. The module
  mounts the token itself, so no mutating webhook is needed. `aws/oidc-provider`
  registers the issuer.
- **Static credentials** (MinIO, an IAM user): `workload_identity_secret_env`
  becomes the `<service>-identity-env` Secret in the service's namespace,
  `envFrom`'d by every pod of that service. Put the endpoint
  (`AWS_ENDPOINT_URL`, `MLFLOW_S3_ENDPOINT_URL`) in `env`.

RayJobs built by user code (Dagster assets, Argo templates) define their own
pod specs: run them as `ray-s3-sa`, `envFrom` the `analytics-config` ConfigMap
(carries `workload_identity["ray"].env`) and the `ray-identity-env` Secret, and
add the projected token volume if you use federation.

`name_prefix` is validated against the tightest downstream name limits (a
namespace, an AWS IAM role, an ALB) so adapters deriving names from it cannot
overflow. Providers point at the target cluster and are configured by the
caller.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.12.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 2.12.1 |

## Resources

| Name | Type |
|------|------|
| [helm_release.argo_workflows](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.dagster](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.jupyterhub](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.jupyterhub_shared_volume](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.mlflow](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.ray_cluster](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_cluster_role_binding_v1.argo_workflow](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding_v1) | resource |
| [kubernetes_cluster_role_binding_v1.dagster_ray_ops](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding_v1) | resource |
| [kubernetes_cluster_role_v1.argo_workflow](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_v1) | resource |
| [kubernetes_cluster_role_v1.dagster_ray_ops](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_v1) | resource |
| [kubernetes_config_map_v1.analytics_config](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1) | resource |
| [kubernetes_config_map_v1.dagster_hello_code](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1) | resource |
| [kubernetes_deployment_v1.webapp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_deployment_v1.webapp_pinned](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_horizontal_pod_autoscaler_v2.webapp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/horizontal_pod_autoscaler_v2) | resource |
| [kubernetes_ingress_v1.argo_private](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.dagster_private](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.jupyterhub](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.mlflow_private](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.ray_dashboard_private](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.webapp_private](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.webapp_public](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_namespace_v1.argo](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_namespace_v1.dagster](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_namespace_v1.jupyterhub](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_namespace_v1.mlflow](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_namespace_v1.ray](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_namespace_v1.webapp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_pod_disruption_budget_v1.webapp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/pod_disruption_budget_v1) | resource |
| [kubernetes_secret_v1.argo_db](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.argo_identity_env](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.dagster_db_password](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.dagster_identity_env](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.dagster_user_code_env](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.database_url](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.jupyterhub_identity_env](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.mlflow_identity_env](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.ray_identity_env](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.webapp_env](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_account_v1.argo_workflow](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_account_v1.dagster](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_account_v1.jupyterhub_single_user](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_account_v1.ray_cluster_sa](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_account_v1.webapp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_v1.ray_dashboard](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_service_v1.webapp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_argo_db_host"></a> [argo\_db\_host](#input\_argo\_db\_host) | Argo workflow-archive Postgres host | `string` | `""` | no |
| <a name="input_argo_db_name"></a> [argo\_db\_name](#input\_argo\_db\_name) | Argo workflow-archive Postgres database name | `string` | `""` | no |
| <a name="input_argo_db_password"></a> [argo\_db\_password](#input\_argo\_db\_password) | Argo workflow-archive Postgres password | `string` | `""` | no |
| <a name="input_argo_db_port"></a> [argo\_db\_port](#input\_argo\_db\_port) | Argo workflow-archive Postgres port | `number` | `5432` | no |
| <a name="input_argo_db_ssl_mode"></a> [argo\_db\_ssl\_mode](#input\_argo\_db\_ssl\_mode) | libpq sslmode for the archive connection: require (Neon, RDS) or disable (an in-cluster Postgres) | `string` | `"require"` | no |
| <a name="input_argo_db_user"></a> [argo\_db\_user](#input\_argo\_db\_user) | Argo workflow-archive Postgres user | `string` | `""` | no |
| <a name="input_argo_server_url"></a> [argo\_server\_url](#input\_argo\_server\_url) | Use another environment's Argo server instead of running one here (enable\_argo\_workflows = false): its in-cluster URL. Workflows submitted through it run in THAT environment's namespace with its identity and data. | `string` | `""` | no |
| <a name="input_argo_workflows_chart_version"></a> [argo\_workflows\_chart\_version](#input\_argo\_workflows\_chart\_version) | Version of the argo/argo-workflows Helm chart. Its appVersion must match the CRDs the platform installed (aws/eks-platform argo\_workflows\_version; 2.0.6 -> v4.1.3). | `string` | `"2.0.6"` | no |
| <a name="input_argo_workflows_repository"></a> [argo\_workflows\_repository](#input\_argo\_workflows\_repository) | Helm repository for the Argo Workflows chart | `string` | `"https://argoproj.github.io/argo-helm"` | no |
| <a name="input_dagster_chart_version"></a> [dagster\_chart\_version](#input\_dagster\_chart\_version) | Version of the official dagster/dagster Helm chart. Must be >= 1.13.23: earlier images are amd64-only, and an arm64 cluster (kind on Apple Silicon, Graviton nodes) cannot pull them. | `string` | `"1.13.23"` | no |
| <a name="input_dagster_db_host"></a> [dagster\_db\_host](#input\_dagster\_db\_host) | Dagster metadata Postgres host | `string` | `""` | no |
| <a name="input_dagster_db_name"></a> [dagster\_db\_name](#input\_dagster\_db\_name) | Dagster metadata Postgres database name | `string` | `""` | no |
| <a name="input_dagster_db_password"></a> [dagster\_db\_password](#input\_dagster\_db\_password) | Dagster metadata Postgres password | `string` | `""` | no |
| <a name="input_dagster_db_user"></a> [dagster\_db\_user](#input\_dagster\_db\_user) | Dagster metadata Postgres user | `string` | `""` | no |
| <a name="input_dagster_repository"></a> [dagster\_repository](#input\_dagster\_repository) | Helm repository for the Dagster chart | `string` | `"https://dagster-io.github.io/helm"` | no |
| <a name="input_dagster_user_code_env"></a> [dagster\_user\_code\_env](#input\_dagster\_user\_code\_env) | Plain environment variables for the Dagster user-code deployment and, through<br/>includeConfigInLaunchedRuns, every run it launches -- how assets learn where<br/>their data lives (e.g. DATA\_REFS, ICEBERG\_CATALOG; see<br/>docs/preview-environments.md). Ignored when dagster\_user\_code\_image is empty. | `map(string)` | `{}` | no |
| <a name="input_dagster_user_code_image"></a> [dagster\_user\_code\_image](#input\_dagster\_user\_code\_image) | User-code (code location) image for Dagster, repository:tag, exposing /opt/dagster/app/repo.py. Empty deploys the module's own hello-world code location (helm-defaults/dagster/hello\_repo.py) in the stock dagster-k8s image. | `string` | `""` | no |
| <a name="input_dagster_user_code_secret_env"></a> [dagster\_user\_code\_secret\_env](#input\_dagster\_user\_code\_secret\_env) | Secret environment variables for the Dagster user-code deployment and its<br/>runs, delivered through a Kubernetes Secret. database\_url is added as<br/>DATABASE\_URL automatically, mirroring the webapp, so assets and the webapp<br/>read the same database without extra wiring. | `map(string)` | `{}` | no |
| <a name="input_dagster_webserver_url"></a> [dagster\_webserver\_url](#input\_dagster\_webserver\_url) | Use another environment's Dagster instead of running one here (enable\_dagster = false): its in-cluster webserver URL. Runs the app triggers there use THAT environment's code location, database and data -- an app-only preview, not a pipeline one. | `string` | `""` | no |
| <a name="input_database_url"></a> [database\_url](#input\_database\_url) | Application database URL, published as the DATABASE\_URL secret key for services that use it | `string` | `""` | no |
| <a name="input_enable_argo_workflow_archive"></a> [enable\_argo\_workflow\_archive](#input\_enable\_argo\_workflow\_archive) | Persist completed workflows to Postgres (the workflow archive), so they outlive their etcd objects and the UI keeps history. Requires argo\_db\_*. | `bool` | `false` | no |
| <a name="input_enable_argo_workflows"></a> [enable\_argo\_workflows](#input\_enable\_argo\_workflows) | Deploy Argo Workflows for this environment: namespace, workflow ServiceAccount + RBAC (may manage RayJobs in the Ray namespace), a namespace-scoped controller + server, optional workflow archive. The CRDs are a cluster prerequisite (aws/eks-platform enable\_argo\_workflows). | `bool` | `false` | no |
| <a name="input_enable_dagster"></a> [enable\_dagster](#input\_enable\_dagster) | Deploy Dagster (requires enable\_ray = true) | `bool` | `false` | no |
| <a name="input_enable_jupyterhub"></a> [enable\_jupyterhub](#input\_enable\_jupyterhub) | Deploy JupyterHub (namespace, shared RWX volume, ServiceAccount, Helm release, optional public ingress). Requires jupyterhub\_shared\_storage. | `bool` | `false` | no |
| <a name="input_enable_mlflow"></a> [enable\_mlflow](#input\_enable\_mlflow) | Deploy the MLflow tracking server | `bool` | `false` | no |
| <a name="input_enable_private_ingress"></a> [enable\_private\_ingress](#input\_enable\_private\_ingress) | Create private Ingresses for the workload UIs (e.g. via the Tailscale operator's IngressClass) | `bool` | `false` | no |
| <a name="input_enable_ray"></a> [enable\_ray](#input\_enable\_ray) | Deploy the Ray namespace + ServiceAccount (the KubeRay operator is a cluster prerequisite, see README) | `bool` | `false` | no |
| <a name="input_enable_ray_cluster"></a> [enable\_ray\_cluster](#input\_enable\_ray\_cluster) | Deploy a persistent Ray cluster (previews often want their own dedicated cluster) | `bool` | `false` | no |
| <a name="input_enable_webapp"></a> [enable\_webapp](#input\_enable\_webapp) | Deploy the generic web application (Deployment + Service + ServiceAccount) | `bool` | `false` | no |
| <a name="input_enable_webapp_public_ingress"></a> [enable\_webapp\_public\_ingress](#input\_enable\_webapp\_public\_ingress) | Create an internet-facing Ingress for the webapp (plus HPA and PodDisruptionBudget). Requires webapp\_public\_ingress\_class\_name. | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (prod / dev / preview), published to pipelines as PIPELINE\_ENV | `string` | `"dev"` | no |
| <a name="input_jupyterhub_admin_users"></a> [jupyterhub\_admin\_users](#input\_jupyterhub\_admin\_users) | JupyterHub usernames granted admin rights | `list(string)` | `[]` | no |
| <a name="input_jupyterhub_allowed_users"></a> [jupyterhub\_allowed\_users](#input\_jupyterhub\_allowed\_users) | JupyterHub usernames allowed to log in. Empty allows any authenticated username (allow\_all). | `list(string)` | `[]` | no |
| <a name="input_jupyterhub_auth_mechanism"></a> [jupyterhub\_auth\_mechanism](#input\_jupyterhub\_auth\_mechanism) | JupyterHub authentication: 'dummy' (shared password), 'firstuse' (each user sets their own password at first login), or 'oidc' (any OIDC provider — Google, Cognito, Okta, Keycloak — via the jupyterhub\_oidc\_* variables) | `string` | `"dummy"` | no |
| <a name="input_jupyterhub_chart_version"></a> [jupyterhub\_chart\_version](#input\_jupyterhub\_chart\_version) | JupyterHub Helm chart version | `string` | `"3.3.8"` | no |
| <a name="input_jupyterhub_extra_values"></a> [jupyterhub\_extra\_values](#input\_jupyterhub\_extra\_values) | Additional YAML documents merged into the JupyterHub Helm values after the built-in template (highest precedence). Use for profiles, lifecycle hooks, resource limits, etc. | `list(string)` | `[]` | no |
| <a name="input_jupyterhub_oidc_authorize_url"></a> [jupyterhub\_oidc\_authorize\_url](#input\_jupyterhub\_oidc\_authorize\_url) | OIDC authorization endpoint, e.g. https://accounts.google.com/o/oauth2/v2/auth | `string` | `""` | no |
| <a name="input_jupyterhub_oidc_callback_url"></a> [jupyterhub\_oidc\_callback\_url](#input\_jupyterhub\_oidc\_callback\_url) | OAuth callback: https://<jupyterhub host>/hub/oauth\_callback (the host may be a tailnet ts.net name — the IdP only needs the browser to reach it, so private hubs work) | `string` | `""` | no |
| <a name="input_jupyterhub_oidc_client_id"></a> [jupyterhub\_oidc\_client\_id](#input\_jupyterhub\_oidc\_client\_id) | OIDC client id (auth mechanism 'oidc') | `string` | `""` | no |
| <a name="input_jupyterhub_oidc_client_secret"></a> [jupyterhub\_oidc\_client\_secret](#input\_jupyterhub\_oidc\_client\_secret) | OIDC client secret (auth mechanism 'oidc') | `string` | `""` | no |
| <a name="input_jupyterhub_oidc_login_service"></a> [jupyterhub\_oidc\_login\_service](#input\_jupyterhub\_oidc\_login\_service) | Label on the JupyterHub login button, e.g. 'Google' | `string` | `"OIDC"` | no |
| <a name="input_jupyterhub_oidc_scopes"></a> [jupyterhub\_oidc\_scopes](#input\_jupyterhub\_oidc\_scopes) | OAuth scopes to request | `list(string)` | <pre>[<br/>  "openid",<br/>  "email"<br/>]</pre> | no |
| <a name="input_jupyterhub_oidc_token_url"></a> [jupyterhub\_oidc\_token\_url](#input\_jupyterhub\_oidc\_token\_url) | OIDC token endpoint, e.g. https://oauth2.googleapis.com/token | `string` | `""` | no |
| <a name="input_jupyterhub_oidc_userdata_url"></a> [jupyterhub\_oidc\_userdata\_url](#input\_jupyterhub\_oidc\_userdata\_url) | OIDC userinfo endpoint, e.g. https://openidconnect.googleapis.com/v1/userinfo | `string` | `""` | no |
| <a name="input_jupyterhub_oidc_username_claim"></a> [jupyterhub\_oidc\_username\_claim](#input\_jupyterhub\_oidc\_username\_claim) | Claim used as the JupyterHub username (also the {username} home sub-path on the shared volume, and what jupyterhub\_admin\_users/jupyterhub\_allowed\_users match against) | `string` | `"email"` | no |
| <a name="input_jupyterhub_public_host"></a> [jupyterhub\_public\_host](#input\_jupyterhub\_public\_host) | Hostname for a JupyterHub Ingress on jupyterhub\_public\_ingress\_class\_name (also stamped for external-dns). Empty skips the Ingress. | `string` | `""` | no |
| <a name="input_jupyterhub_public_ingress_annotations"></a> [jupyterhub\_public\_ingress\_annotations](#input\_jupyterhub\_public\_ingress\_annotations) | Annotations for the JupyterHub Ingress (aws/compute-adapter emits the alb.ingress.kubernetes.io/* set). | `map(string)` | `{}` | no |
| <a name="input_jupyterhub_public_ingress_class_name"></a> [jupyterhub\_public\_ingress\_class\_name](#input\_jupyterhub\_public\_ingress\_class\_name) | IngressClass for the JupyterHub Ingress. Required when jupyterhub\_public\_host is set. | `string` | `""` | no |
| <a name="input_jupyterhub_public_tls_secret_name"></a> [jupyterhub\_public\_tls\_secret\_name](#input\_jupyterhub\_public\_tls\_secret\_name) | TLS Secret for the JupyterHub Ingress (e.g. cert-manager). Empty adds no tls block. | `string` | `""` | no |
| <a name="input_jupyterhub_shared_storage"></a> [jupyterhub\_shared\_storage](#input\_jupyterhub\_shared\_storage) | The ReadWriteMany volume holding every user's home directory and the<br/>shared directory -- the only persistent user data in this module. Exactly<br/>one of:<br/>  nfs\_server          static NFS PersistentVolumes pointing at an existing<br/>                      server: an EFS filesystem's DNS name<br/>                      (aws/compute-adapter), a Filestore IP, any NFS box.<br/>  storage\_class\_name  dynamic RWX PersistentVolumeClaims from a<br/>                      StorageClass (efs-sc, standard-rwx, azurefile,<br/>                      nfs-client; kind's local-path works on one node).<br/>`size` is the claim size (nominal for NFS). Required when<br/>enable\_jupyterhub is true. | <pre>object({<br/>    nfs_server         = optional(string)<br/>    nfs_path           = optional(string, "/")<br/>    storage_class_name = optional(string)<br/>    size               = optional(string, "100Gi")<br/>  })</pre> | `{}` | no |
| <a name="input_jupyterhub_singleuser_image"></a> [jupyterhub\_singleuser\_image](#input\_jupyterhub\_singleuser\_image) | Container image (repository:tag) for JupyterHub single-user servers. Empty uses the chart default. | `string` | `""` | no |
| <a name="input_jupyterhub_user_password"></a> [jupyterhub\_user\_password](#input\_jupyterhub\_user\_password) | Shared password for JupyterHub users (dummy auth) | `string` | `""` | no |
| <a name="input_mlflow_artifact_root"></a> [mlflow\_artifact\_root](#input\_mlflow\_artifact\_root) | Artifact store URI for the tracking server, e.g. s3://my-bucket/mlflow.<br/>Any S3-compatible store works: point AWS\_ENDPOINT\_URL /<br/>MLFLOW\_S3\_ENDPOINT\_URL at MinIO through workload\_identity["mlflow"].env.<br/>Empty uses the chart's default local artifact root (fine for kind). | `string` | `""` | no |
| <a name="input_mlflow_chart_version"></a> [mlflow\_chart\_version](#input\_mlflow\_chart\_version) | Version of the community-charts/mlflow Helm chart. Must be >= 1.x: the 0.7 chart's image bundles a libpq too old for SCRAM authentication, which Postgres 14+ and Neon default to. | `string` | `"1.11.7"` | no |
| <a name="input_mlflow_db_host"></a> [mlflow\_db\_host](#input\_mlflow\_db\_host) | MLflow tracking Postgres host | `string` | `""` | no |
| <a name="input_mlflow_db_name"></a> [mlflow\_db\_name](#input\_mlflow\_db\_name) | MLflow tracking Postgres database name | `string` | `""` | no |
| <a name="input_mlflow_db_password"></a> [mlflow\_db\_password](#input\_mlflow\_db\_password) | MLflow tracking Postgres password | `string` | `""` | no |
| <a name="input_mlflow_db_user"></a> [mlflow\_db\_user](#input\_mlflow\_db\_user) | MLflow tracking Postgres user | `string` | `""` | no |
| <a name="input_mlflow_repository"></a> [mlflow\_repository](#input\_mlflow\_repository) | Helm repository for the MLflow chart | `string` | `"https://community-charts.github.io/helm-charts"` | no |
| <a name="input_mlflow_tracking_uri"></a> [mlflow\_tracking\_uri](#input\_mlflow\_tracking\_uri) | Use another environment's MLflow instead of running one here (enable\_mlflow = false): its in-cluster URL, e.g. http://mlflow.mlflow.svc.cluster.local:80. Experiments and artifacts then land in THAT environment's store. | `string` | `""` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix applied to every namespace, Helm release, and private hostname so<br/>multiple workload environments can share one cluster. Empty ("")<br/>reproduces the base names. A preview uses e.g. "pr123-".<br/><br/>Backend adapters derive their own resource names (IAM roles, NodePools,<br/>filesystems) from the same prefix, so it is validated against the tightest<br/>downstream limits -- a Kubernetes namespace (63), an AWS IAM role name<br/>(64), an ALB name (32) -- rather than only what this module creates. | `string` | `""` | no |
| <a name="input_private_ingress_annotations"></a> [private\_ingress\_annotations](#input\_private\_ingress\_annotations) | Annotations for the private Ingresses, keyed by service ("dagster",<br/>"mlflow", "webapp", "ray", "argo"); the special key "*" applies to every service,<br/>with per-service entries winning on conflict.<br/><br/>The flagship use is Tailscale ACL scoping. The operator tags every proxy<br/>device tag:k8s by default, so one grant governs all UIs; per-service<br/>device tags let the tailnet policy grant them individually -- ops UIs to<br/>the platform group, the webapp (which authenticates users itself) to<br/>every member:<br/><br/>  private\_ingress\_annotations = {<br/>    dagster = { "tailscale.com/tags" = "tag:svc-dagster" }<br/>    mlflow  = { "tailscale.com/tags" = "tag:svc-mlflow" }<br/>    ray     = { "tailscale.com/tags" = "tag:svc-ray" }<br/>    webapp  = { "tailscale.com/tags" = "tag:svc-webapp" }<br/>  }<br/><br/>A preview stack instead collapses to one tag, so a single grant covers<br/>the whole environment:<br/><br/>  private\_ingress\_annotations = { "*" = { "tailscale.com/tags" = "tag:svc-preview" } }<br/><br/>Each tag needs the operator's tag as an owner in the policy's tagOwners<br/>("tag:svc-preview": ["tag:k8s-operator"]), applied BEFORE any Ingress<br/>uses it, or the operator cannot mint the device.<br/><br/>Tags apply only at provisioning. The operator reads tailscale.com/tags<br/>when it first creates a proxy device and never again, so editing the<br/>annotation on a live Ingress changes nothing on the tailnet -- and since<br/>the ACL grants by tag, that device silently falls out of the new grant.<br/>Whenever a tag changes (including the first time you set one on an<br/>existing environment), recreate the Ingress so a fresh device is minted:<br/><br/>  tofu apply -replace='module.workloads.kubernetes\_ingress\_v1.webapp\_private[0]'<br/><br/>The hostname is unaffected; the service blips while the new proxy pod<br/>starts. Only ProxyGroup-mode Ingresses reconcile tag changes in place. | `map(map(string))` | `{}` | no |
| <a name="input_private_ingress_class_name"></a> [private\_ingress\_class\_name](#input\_private\_ingress\_class\_name) | IngressClass backing the private workload Ingresses. 'tailscale' uses the operator (a cluster prerequisite); set to your own private ingress controller to bring your own. | `string` | `"tailscale"` | no |
| <a name="input_private_ingress_dns_suffix"></a> [private\_ingress\_dns\_suffix](#input\_private\_ingress\_dns\_suffix) | DNS suffix for the private hostnames (e.g. your MagicDNS tailnet suffix <tailnet>.ts.net). Used only to build output URLs. | `string` | `""` | no |
| <a name="input_private_ingress_hostname_prefix"></a> [private\_ingress\_hostname\_prefix](#input\_private\_ingress\_hostname\_prefix) | Prefix for the private hostnames (keeps names unique per env). Usually equal to name\_prefix. | `string` | `""` | no |
| <a name="input_ray_cluster_chart_version"></a> [ray\_cluster\_chart\_version](#input\_ray\_cluster\_chart\_version) | Version of the kuberay ray-cluster Helm chart | `string` | `"1.6.0"` | no |
| <a name="input_ray_cluster_release_name"></a> [ray\_cluster\_release\_name](#input\_ray\_cluster\_release\_name) | Helm release name for the persistent Ray cluster (auto-prefixed) | `string` | `"ray-cluster"` | no |
| <a name="input_ray_cluster_repository"></a> [ray\_cluster\_repository](#input\_ray\_cluster\_repository) | Helm repository for the kuberay ray-cluster chart | `string` | `"https://ray-project.github.io/kuberay-helm/"` | no |
| <a name="input_ray_dashboard_cluster_name"></a> [ray\_dashboard\_cluster\_name](#input\_ray\_dashboard\_cluster\_name) | RayCluster whose head Pod backs the private ray Ingress. Empty follows the persistent cluster ('<name\_prefix><ray\_cluster\_release\_name>'). | `string` | `""` | no |
| <a name="input_ray_gpu_image_repository"></a> [ray\_gpu\_image\_repository](#input\_ray\_gpu\_image\_repository) | Container image repository for Ray GPU workers. Empty uses the public rayproject/ray image. | `string` | `"rayproject/ray"` | no |
| <a name="input_ray_gpu_image_tag"></a> [ray\_gpu\_image\_tag](#input\_ray\_gpu\_image\_tag) | Image tag for Ray GPU workers. Empty derives '<ray\_version>-gpu'. | `string` | `""` | no |
| <a name="input_ray_head_resources"></a> [ray\_head\_resources](#input\_ray\_head\_resources) | Resource requests/limits for the persistent Ray head container | <pre>object({<br/>    requests = optional(map(string), { cpu = "1", memory = "2Gi" })<br/>    limits   = optional(map(string), { cpu = "2", memory = "4Gi" })<br/>  })</pre> | `{}` | no |
| <a name="input_ray_image_repository"></a> [ray\_image\_repository](#input\_ray\_image\_repository) | Container image repository for Ray head/worker (CPU). Empty uses the public rayproject/ray image. | `string` | `"rayproject/ray"` | no |
| <a name="input_ray_image_tag"></a> [ray\_image\_tag](#input\_ray\_image\_tag) | Image tag for Ray head/worker (CPU). Empty derives '<ray\_version>'. | `string` | `""` | no |
| <a name="input_ray_version"></a> [ray\_version](#input\_ray\_version) | Ray version used for the cluster image tags and the RayCluster spec.<br/>Anything connecting via Ray client (`ray://`, e.g. Dagster user code) must<br/>match the cluster on BOTH the Ray version and the Python minor version;<br/>the robust pattern is building those images FROM the same base<br/>(`rayproject/ray:<ray_version>-pyXXX`) so they match by construction. | `string` | `"2.55.1"` | no |
| <a name="input_ray_worker_max_replicas"></a> [ray\_worker\_max\_replicas](#input\_ray\_worker\_max\_replicas) | Autoscaling ceiling for the persistent Ray CPU worker group (min is 0) | `number` | `10` | no |
| <a name="input_ray_worker_resources"></a> [ray\_worker\_resources](#input\_ray\_worker\_resources) | Resource requests/limits for the persistent Ray CPU worker containers | <pre>object({<br/>    requests = optional(map(string), { cpu = "1", memory = "2Gi" })<br/>    limits   = optional(map(string), { cpu = "2", memory = "4Gi" })<br/>  })</pre> | `{}` | no |
| <a name="input_scheduling"></a> [scheduling](#input\_scheduling) | Node placement per pod role: webapp, dagster (webserver, daemon, user code,<br/>run pods), mlflow, argo (controller + server), jupyterhub (hub + proxy),<br/>jupyterhub\_singleuser, ray\_head, ray\_worker. Each gives a nodeSelector and tolerations. Empty<br/>(the default) schedules anywhere, which is what a laptop kind cluster<br/>wants; aws/compute-adapter emits `karpenter.sh/nodepool` selectors and the<br/>matching tolerations for the NodePools it creates. Unknown keys are ignored. | <pre>map(object({<br/>    node_selector = optional(map(string), {})<br/>    tolerations = optional(list(object({<br/>      key      = optional(string)<br/>      operator = optional(string, "Equal")<br/>      value    = optional(string)<br/>      effect   = optional(string)<br/>    })), [])<br/>  }))</pre> | `{}` | no |
| <a name="input_webapp_app_name"></a> [webapp\_app\_name](#input\_webapp\_app\_name) | Name used for the webapp namespace/Service/Deployment (auto-prefixed) | `string` | `"webapp"` | no |
| <a name="input_webapp_container_port"></a> [webapp\_container\_port](#input\_webapp\_container\_port) | Container port the webapp listens on | `number` | `8080` | no |
| <a name="input_webapp_cpu_request"></a> [webapp\_cpu\_request](#input\_webapp\_cpu\_request) | CPU request for the webapp container (also the HPA scaling baseline) | `string` | `"100m"` | no |
| <a name="input_webapp_env"></a> [webapp\_env](#input\_webapp\_env) | Plain (non-secret) environment variables for the webapp container | `map(string)` | `{}` | no |
| <a name="input_webapp_health_check_path"></a> [webapp\_health\_check\_path](#input\_webapp\_health\_check\_path) | HTTP path used for the webapp readiness/liveness probes (adapters reuse it for load-balancer health checks) | `string` | `"/"` | no |
| <a name="input_webapp_hpa_cpu_target"></a> [webapp\_hpa\_cpu\_target](#input\_webapp\_hpa\_cpu\_target) | Target average CPU utilisation (percent of the request) the HPA holds the webapp at | `number` | `70` | no |
| <a name="input_webapp_hpa_max_replicas"></a> [webapp\_hpa\_max\_replicas](#input\_webapp\_hpa\_max\_replicas) | HPA ceiling for the webapp | `number` | `10` | no |
| <a name="input_webapp_hpa_min_replicas"></a> [webapp\_hpa\_min\_replicas](#input\_webapp\_hpa\_min\_replicas) | HPA floor for the webapp (only used with the public ingress) | `number` | `2` | no |
| <a name="input_webapp_ignore_image_changes"></a> [webapp\_ignore\_image\_changes](#input\_webapp\_ignore\_image\_changes) | Ignore changes to the webapp image so an external CI (kubectl set image) owns the running tag. Also ignores replica count so it does not fight the HPA. | `bool` | `false` | no |
| <a name="input_webapp_image"></a> [webapp\_image](#input\_webapp\_image) | Full container image reference for the webapp (required when enable\_webapp is true) | `string` | `""` | no |
| <a name="input_webapp_memory_limit"></a> [webapp\_memory\_limit](#input\_webapp\_memory\_limit) | Memory limit for the webapp container | `string` | `"1Gi"` | no |
| <a name="input_webapp_memory_request"></a> [webapp\_memory\_request](#input\_webapp\_memory\_request) | Memory request for the webapp container | `string` | `"512Mi"` | no |
| <a name="input_webapp_public_host"></a> [webapp\_public\_host](#input\_webapp\_public\_host) | Public hostname the Ingress serves. Also stamped as external-dns.alpha.kubernetes.io/hostname so external-dns (if installed) publishes the record. | `string` | `""` | no |
| <a name="input_webapp_public_ingress_annotations"></a> [webapp\_public\_ingress\_annotations](#input\_webapp\_public\_ingress\_annotations) | Annotations for the public webapp Ingress (aws/compute-adapter emits the alb.ingress.kubernetes.io/* set; cert-manager users add cert-manager.io/cluster-issuer). | `map(string)` | `{}` | no |
| <a name="input_webapp_public_ingress_class_name"></a> [webapp\_public\_ingress\_class\_name](#input\_webapp\_public\_ingress\_class\_name) | IngressClass for the public webapp Ingress ('alb' from aws/compute-adapter, 'nginx', ...). Required when enable\_webapp\_public\_ingress is true. | `string` | `""` | no |
| <a name="input_webapp_public_tls_secret_name"></a> [webapp\_public\_tls\_secret\_name](#input\_webapp\_public\_tls\_secret\_name) | TLS Secret for the public webapp Ingress (e.g. issued by cert-manager). Empty adds no tls block, which is right for TLS terminated at a cloud load balancer via annotations. | `string` | `""` | no |
| <a name="input_webapp_public_wait_for_load_balancer"></a> [webapp\_public\_wait\_for\_load\_balancer](#input\_webapp\_public\_wait\_for\_load\_balancer) | Block the apply until the Ingress reports a load-balancer address, surfacing controller errors at apply time. Set false on clusters whose ingress controller never populates the status (kind). | `bool` | `true` | no |
| <a name="input_webapp_replicas"></a> [webapp\_replicas](#input\_webapp\_replicas) | Replica count for the webapp Deployment (ignored once the public HPA is enabled) | `number` | `1` | no |
| <a name="input_webapp_secret_env"></a> [webapp\_secret\_env](#input\_webapp\_secret\_env) | Secret environment variables for the webapp container (stored in a Kubernetes Secret and injected via envFrom) | `map(string)` | `{}` | no |
| <a name="input_webapp_session_affinity_seconds"></a> [webapp\_session\_affinity\_seconds](#input\_webapp\_session\_affinity\_seconds) | ClientIP session affinity timeout on the webapp Service (0 disables). Needed for stateful single-pod sessions routed through the Service (e.g. private ingress). | `number` | `0` | no |
| <a name="input_workload_identity"></a> [workload\_identity](#input\_workload\_identity) | Per-service identity (non-secret part). Keys: webapp, dagster, ray, argo,<br/>mlflow, jupyterhub. For each: `service_account_annotations` stamped on the<br/>service's ServiceAccount; `env` plain variables the pods receive (e.g.<br/>AWS\_REGION, AWS\_ROLE\_ARN, AWS\_WEB\_IDENTITY\_TOKEN\_FILE, AWS\_ENDPOINT\_URL);<br/>`projected_token` mounts a projected ServiceAccount token at<br/><mount\_path>/<file\_name> with the given audience for web-identity<br/>federation. Produced by a backend adapter (aws/data-adapter) or written by<br/>hand. For "ray", `env` also lands in the analytics-config ConfigMap so<br/>RayJobs launched by user code can envFrom it. | <pre>map(object({<br/>    service_account_annotations = optional(map(string), {})<br/>    env                         = optional(map(string), {})<br/>    projected_token = optional(object({<br/>      audience           = string<br/>      mount_path         = optional(string, "/var/run/secrets/workload-identity")<br/>      file_name          = optional(string, "token")<br/>      expiration_seconds = optional(number, 3600)<br/>    }))<br/>  }))</pre> | `{}` | no |
| <a name="input_workload_identity_secret_env"></a> [workload\_identity\_secret\_env](#input\_workload\_identity\_secret\_env) | Per-service SECRET environment variables (same keys as workload\_identity),<br/>delivered through a Kubernetes Secret named <service>-identity-env in the<br/>service's namespace and injected with envFrom. This is the static-credential<br/>path (AWS\_ACCESS\_KEY\_ID / AWS\_SECRET\_ACCESS\_KEY for MinIO or an IAM user).<br/>Keys must be known at plan time. The Secret exists for every enabled<br/>service, empty when nothing is set, so charts can reference it<br/>unconditionally. | `map(map(string))` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_argo_namespace"></a> [argo\_namespace](#output\_argo\_namespace) | Argo Workflows namespace (if enabled) |
| <a name="output_argo_private_url"></a> [argo\_private\_url](#output\_argo\_private\_url) | Private URL for the Argo Workflows UI |
| <a name="output_dagster_namespace"></a> [dagster\_namespace](#output\_dagster\_namespace) | Dagster namespace (if enabled) |
| <a name="output_dagster_private_url"></a> [dagster\_private\_url](#output\_dagster\_private\_url) | Private URL for Dagit (if the private ingress + DNS suffix are set) |
| <a name="output_identity_secret_names"></a> [identity\_secret\_names](#output\_identity\_secret\_names) | Per-service name of the <service>-identity-env Secret (in that service's namespace) carrying workload\_identity\_secret\_env; RayJobs launched by user code can envFrom the ray one. |
| <a name="output_in_cluster_urls"></a> [in\_cluster\_urls](#output\_in\_cluster\_urls) | In-cluster URLs of the services THIS environment runs (null when a service is off). Another environment shares them by passing them as its mlflow\_tracking\_uri / dagster\_webserver\_url / argo\_server\_url with the matching enable\_* off -- see README "Stamp or share". |
| <a name="output_jupyterhub_namespace"></a> [jupyterhub\_namespace](#output\_jupyterhub\_namespace) | JupyterHub namespace (if enabled) |
| <a name="output_mlflow_namespace"></a> [mlflow\_namespace](#output\_mlflow\_namespace) | MLflow namespace (if enabled) |
| <a name="output_mlflow_private_url"></a> [mlflow\_private\_url](#output\_mlflow\_private\_url) | Private URL for the MLflow UI |
| <a name="output_ray_dashboard_private_url"></a> [ray\_dashboard\_private\_url](#output\_ray\_dashboard\_private\_url) | Private URL for the Ray dashboard (502s while no Ray cluster is running) |
| <a name="output_ray_namespace"></a> [ray\_namespace](#output\_ray\_namespace) | Ray namespace (if enabled) |
| <a name="output_service_accounts"></a> [service\_accounts](#output\_service\_accounts) | Per-service {namespace, name} of the ServiceAccounts pods run as (null when the service is off). Backend adapters trust exactly these subjects. |
| <a name="output_webapp_namespace"></a> [webapp\_namespace](#output\_webapp\_namespace) | Webapp namespace (if enabled) |
| <a name="output_webapp_private_url"></a> [webapp\_private\_url](#output\_webapp\_private\_url) | Private URL for the webapp |
| <a name="output_webapp_public_ingress"></a> [webapp\_public\_ingress](#output\_webapp\_public\_ingress) | {namespace, name} of the public webapp Ingress (null unless enabled), for adapters that look up the load balancer it produced |
| <a name="output_webapp_public_url"></a> [webapp\_public\_url](#output\_webapp\_public\_url) | Public HTTPS URL for the webapp (null unless the public ingress is enabled) |
<!-- END_TF_DOCS -->
