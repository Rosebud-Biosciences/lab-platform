# workloads

The application layer, deployed onto an **existing** cluster and designed to be
instantiated **multiple times** against the same cluster with a distinct
`name_prefix` — this is what lets prod and any number of preview environments
coexist without namespace/release/hostname collisions.

Per-service `enable_*` toggles:

- **webapp** — a generic Deployment + Service + IRSA, with an optional
  internet-facing ALB Ingress (+ HPA, PodDisruptionBudget, WAF, Route53 alias)
  or a private Ingress;
- **JupyterHub** — namespace, EFS shared volume, IRSA, Helm release, optional
  ALB ingress;
- **Dagster** — requires `enable_ray` (an explicit precondition, not a silent
  coupling);
- **MLflow** — tracking server backed by external Postgres + an S3 artifact
  bucket;
- **Ray** — the Ray namespace/IRSA and an optional persistent Ray cluster;
- **Karpenter NodePools** — name-prefixed per environment.

`name_prefix` is validated against the tightest downstream AWS/Kubernetes name
limits. Providers point at the target cluster and are configured by the caller.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.28 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.12.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.62.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | 3.2.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 3.2.1 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_argo_workflow_irsa"></a> [argo\_workflow\_irsa](#module\_argo\_workflow\_irsa) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | ~> 6.8 |
| <a name="module_dagster_irsa"></a> [dagster\_irsa](#module\_dagster\_irsa) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | ~> 6.8 |
| <a name="module_jupyterhub_single_user_irsa"></a> [jupyterhub\_single\_user\_irsa](#module\_jupyterhub\_single\_user\_irsa) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | ~> 6.8 |
| <a name="module_mlflow_irsa"></a> [mlflow\_irsa](#module\_mlflow\_irsa) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | ~> 6.8 |
| <a name="module_ray_cluster_irsa"></a> [ray\_cluster\_irsa](#module\_ray\_cluster\_irsa) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | ~> 6.8 |
| <a name="module_webapp_irsa"></a> [webapp\_irsa](#module\_webapp\_irsa) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | ~> 6.8 |

## Resources

| Name | Type |
|------|------|
| [aws_efs_file_system.jupyterhub](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system) | resource |
| [aws_efs_mount_target.jupyterhub](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_mount_target) | resource |
| [aws_iam_policy.ecr_read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.mlflow_s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_route53_record.jupyterhub](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.webapp_public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_security_group.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_wafv2_web_acl.webapp](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl) | resource |
| [helm_release.dagster](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.efs_persist](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.jupyterhub](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.karpenter_node_pools](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.mlflow](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.ray_cluster](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_cluster_role_binding_v1.argo_workflow](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding_v1) | resource |
| [kubernetes_cluster_role_binding_v1.dagster_ray_ops](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding_v1) | resource |
| [kubernetes_cluster_role_v1.argo_workflow](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_v1) | resource |
| [kubernetes_cluster_role_v1.dagster_ray_ops](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_v1) | resource |
| [kubernetes_config_map_v1.analytics_config](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1) | resource |
| [kubernetes_deployment_v1.webapp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_deployment_v1.webapp_pinned](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_horizontal_pod_autoscaler_v2.webapp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/horizontal_pod_autoscaler_v2) | resource |
| [kubernetes_ingress_v1.dagster_private](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.jupyterhub](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.mlflow_private](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.ray_dashboard_private](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.webapp_private](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.webapp_public](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_namespace_v1.dagster](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_namespace_v1.jupyterhub](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_namespace_v1.mlflow](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_namespace_v1.ray](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_namespace_v1.webapp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_pod_disruption_budget_v1.webapp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/pod_disruption_budget_v1) | resource |
| [kubernetes_secret_v1.dagster_db_password](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.database_url](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.mlflow_db](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.webapp_env](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_account_v1.argo_workflow](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_account_v1.dagster](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_account_v1.jupyterhub_single_user](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_account_v1.ray_cluster_sa](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_account_v1.webapp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_v1.ray_dashboard](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_service_v1.webapp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [aws_lb.jupyterhub](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/lb) | data source |
| [aws_lb.webapp_public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/lb) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name of the existing EKS cluster to deploy the workloads onto | `string` | n/a | yes |
| <a name="input_oidc_provider_arn"></a> [oidc\_provider\_arn](#input\_oidc\_provider\_arn) | IRSA OIDC provider ARN of the target cluster | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS region | `string` | n/a | yes |
| <a name="input_vpc_name"></a> [vpc\_name](#input\_vpc\_name) | VPC name used by Karpenter NodePools for subnet/SG discovery | `string` | n/a | yes |
| <a name="input_dagster_bucket_policies"></a> [dagster\_bucket\_policies](#input\_dagster\_bucket\_policies) | Map of IAM policy ARNs attached to the Dagster service account | `map(string)` | `{}` | no |
| <a name="input_dagster_chart_version"></a> [dagster\_chart\_version](#input\_dagster\_chart\_version) | Version of the official dagster/dagster Helm chart. Must be >= 1.12.8. | `string` | `"1.13.14"` | no |
| <a name="input_dagster_db_host"></a> [dagster\_db\_host](#input\_dagster\_db\_host) | Dagster metadata Postgres host | `string` | `""` | no |
| <a name="input_dagster_db_name"></a> [dagster\_db\_name](#input\_dagster\_db\_name) | Dagster metadata Postgres database name | `string` | `""` | no |
| <a name="input_dagster_db_password"></a> [dagster\_db\_password](#input\_dagster\_db\_password) | Dagster metadata Postgres password | `string` | `""` | no |
| <a name="input_dagster_db_user"></a> [dagster\_db\_user](#input\_dagster\_db\_user) | Dagster metadata Postgres user | `string` | `""` | no |
| <a name="input_dagster_repository"></a> [dagster\_repository](#input\_dagster\_repository) | Helm repository for the Dagster chart | `string` | `"https://dagster-io.github.io/helm"` | no |
| <a name="input_dagster_user_code_image"></a> [dagster\_user\_code\_image](#input\_dagster\_user\_code\_image) | User-code (code location) image for Dagster, repository:tag. Empty deploys the chart with the example user code. | `string` | `""` | no |
| <a name="input_database_url"></a> [database\_url](#input\_database\_url) | Application database URL, published as the DATABASE\_URL secret key for services that use it | `string` | `""` | no |
| <a name="input_efs_subnet_cidr_octet_prefix"></a> [efs\_subnet\_cidr\_octet\_prefix](#input\_efs\_subnet\_cidr\_octet\_prefix) | First-octet prefix selecting which private subnets host the JupyterHub EFS mount targets | `string` | `"100."` | no |
| <a name="input_enable_argo_workflows"></a> [enable\_argo\_workflows](#input\_enable\_argo\_workflows) | Create the Argo Workflows service account + RBAC in the Ray namespace | `bool` | `false` | no |
| <a name="input_enable_dagster"></a> [enable\_dagster](#input\_enable\_dagster) | Deploy Dagster (requires enable\_ray = true) | `bool` | `false` | no |
| <a name="input_enable_jupyterhub"></a> [enable\_jupyterhub](#input\_enable\_jupyterhub) | Deploy JupyterHub (namespace, EFS shared volume, IRSA, Helm release, optional ALB ingress) | `bool` | `false` | no |
| <a name="input_enable_mlflow"></a> [enable\_mlflow](#input\_enable\_mlflow) | Deploy the MLflow tracking server | `bool` | `false` | no |
| <a name="input_enable_private_ingress"></a> [enable\_private\_ingress](#input\_enable\_private\_ingress) | Create private Ingresses for the workload UIs (e.g. via the Tailscale operator's IngressClass) | `bool` | `false` | no |
| <a name="input_enable_ray"></a> [enable\_ray](#input\_enable\_ray) | Deploy the Ray namespace + IRSA (the KubeRay operator lives in the platform module) | `bool` | `false` | no |
| <a name="input_enable_ray_cluster"></a> [enable\_ray\_cluster](#input\_enable\_ray\_cluster) | Deploy a persistent Ray cluster (previews often want their own dedicated cluster) | `bool` | `false` | no |
| <a name="input_enable_webapp"></a> [enable\_webapp](#input\_enable\_webapp) | Deploy the generic web application (Deployment + Service + IRSA) | `bool` | `false` | no |
| <a name="input_enable_webapp_public_ingress"></a> [enable\_webapp\_public\_ingress](#input\_enable\_webapp\_public\_ingress) | Create an internet-facing ALB Ingress for the webapp (plus HPA, PodDisruptionBudget, and optional Route53 alias). Requires the AWS Load Balancer Controller. | `bool` | `false` | no |
| <a name="input_enable_webapp_waf"></a> [enable\_webapp\_waf](#input\_enable\_webapp\_waf) | Attach a WAFv2 web ACL (AWS managed common rules + a per-IP rate limit) to the public ALB | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (prod / dev / preview) | `string` | `"dev"` | no |
| <a name="input_jupyterhub_admin_users"></a> [jupyterhub\_admin\_users](#input\_jupyterhub\_admin\_users) | JupyterHub usernames granted admin rights | `list(string)` | `[]` | no |
| <a name="input_jupyterhub_allowed_users"></a> [jupyterhub\_allowed\_users](#input\_jupyterhub\_allowed\_users) | JupyterHub usernames allowed to log in. Empty allows any authenticated username (allow\_all). | `list(string)` | `[]` | no |
| <a name="input_jupyterhub_auth_mechanism"></a> [jupyterhub\_auth\_mechanism](#input\_jupyterhub\_auth\_mechanism) | JupyterHub authentication: 'dummy' (shared password), 'firstuse' (each user sets their own password at first login), or 'cognito' (generic OIDC) | `string` | `"dummy"` | no |
| <a name="input_jupyterhub_chart_version"></a> [jupyterhub\_chart\_version](#input\_jupyterhub\_chart\_version) | JupyterHub Helm chart version | `string` | `"3.3.8"` | no |
| <a name="input_jupyterhub_efs_prevent_destroy"></a> [jupyterhub\_efs\_prevent\_destroy](#input\_jupyterhub\_efs\_prevent\_destroy) | Protect the JupyterHub EFS filesystem (user home directories) from<br/>`tofu destroy` via lifecycle.prevent\_destroy (dynamic; OpenTofu >= 1.12).<br/>Leave true for durable environments — destroys then fail until this is<br/>first flipped off, an intentional two-step. Set false for<br/>previews/ephemeral stamps so they can tear down. | `bool` | `true` | no |
| <a name="input_jupyterhub_extra_values"></a> [jupyterhub\_extra\_values](#input\_jupyterhub\_extra\_values) | Additional YAML documents merged into the JupyterHub Helm values after the built-in template (highest precedence). Use for profiles, lifecycle hooks, resource limits, etc. | `list(string)` | `[]` | no |
| <a name="input_jupyterhub_ingress_scheme"></a> [jupyterhub\_ingress\_scheme](#input\_jupyterhub\_ingress\_scheme) | ALB scheme for the JupyterHub ingress ('internal' or 'internet-facing') | `string` | `"internal"` | no |
| <a name="input_jupyterhub_public_host"></a> [jupyterhub\_public\_host](#input\_jupyterhub\_public\_host) | Hostname for the JupyterHub ALB ingress. Empty skips the ingress/DNS. | `string` | `""` | no |
| <a name="input_jupyterhub_route53_zone_id"></a> [jupyterhub\_route53\_zone\_id](#input\_jupyterhub\_route53\_zone\_id) | Route53 hosted zone id for jupyterhub\_public\_host. Empty skips the alias record. | `string` | `""` | no |
| <a name="input_jupyterhub_singleuser_image"></a> [jupyterhub\_singleuser\_image](#input\_jupyterhub\_singleuser\_image) | Container image (repository:tag) for JupyterHub single-user servers. Empty uses the chart default. | `string` | `""` | no |
| <a name="input_jupyterhub_user_password"></a> [jupyterhub\_user\_password](#input\_jupyterhub\_user\_password) | Shared password for JupyterHub users (dummy auth) | `string` | `""` | no |
| <a name="input_karpenter_node_iam_role_name"></a> [karpenter\_node\_iam\_role\_name](#input\_karpenter\_node\_iam\_role\_name) | Name of the Karpenter node IAM role (used by NodePool nodeRole). Empty disables NodePool creation. | `string` | `""` | no |
| <a name="input_karpenter_node_pools"></a> [karpenter\_node\_pools](#input\_karpenter\_node\_pools) | Map of Karpenter NodePool configurations (created only if karpenter\_node\_iam\_role\_name is set) | <pre>map(object({<br/>    name                   = optional(string)<br/>    instance_sizes         = optional(list(string), ["large", "xlarge", "2xlarge", "4xlarge", "8xlarge"])<br/>    instance_families      = optional(list(string), ["t3a", "c5", "m5", "r5", "r6g"])<br/>    instance_architectures = optional(list(string), ["amd64"])<br/>    capacity_types         = optional(list(string), ["spot", "on-demand"])<br/>    ami_family             = optional(string, "AL2023")<br/>    labels                 = optional(map(string), {})<br/>    taints = optional(list(object({<br/>      key    = string<br/>      value  = optional(string)<br/>      effect = string<br/>    })), [])<br/>    limits = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_mlflow_artifact_bucket"></a> [mlflow\_artifact\_bucket](#input\_mlflow\_artifact\_bucket) | S3 bucket name for MLflow artifacts | `string` | `""` | no |
| <a name="input_mlflow_artifact_bucket_arn"></a> [mlflow\_artifact\_bucket\_arn](#input\_mlflow\_artifact\_bucket\_arn) | S3 bucket ARN for MLflow artifacts (grants the tracking server access) | `string` | `""` | no |
| <a name="input_mlflow_chart_version"></a> [mlflow\_chart\_version](#input\_mlflow\_chart\_version) | Version of the community-charts/mlflow Helm chart | `string` | `"0.7.19"` | no |
| <a name="input_mlflow_db_host"></a> [mlflow\_db\_host](#input\_mlflow\_db\_host) | MLflow tracking Postgres host | `string` | `""` | no |
| <a name="input_mlflow_db_name"></a> [mlflow\_db\_name](#input\_mlflow\_db\_name) | MLflow tracking Postgres database name | `string` | `""` | no |
| <a name="input_mlflow_db_password"></a> [mlflow\_db\_password](#input\_mlflow\_db\_password) | MLflow tracking Postgres password | `string` | `""` | no |
| <a name="input_mlflow_db_user"></a> [mlflow\_db\_user](#input\_mlflow\_db\_user) | MLflow tracking Postgres user | `string` | `""` | no |
| <a name="input_mlflow_repository"></a> [mlflow\_repository](#input\_mlflow\_repository) | Helm repository for the MLflow chart | `string` | `"https://community-charts.github.io/helm-charts"` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix applied to every namespace, Helm release, IAM role, NodePool, and<br/>private hostname so multiple workload environments can share one cluster.<br/>Empty ("") reproduces the base names. A preview uses e.g. "pr123-".<br/><br/>Validated against the tightest downstream AWS/Kubernetes limits so a long<br/>prefix cannot silently produce an invalid namespace (63), IAM role name<br/>(64), or ALB name (32). | `string` | `""` | no |
| <a name="input_private_ingress_class_name"></a> [private\_ingress\_class\_name](#input\_private\_ingress\_class\_name) | IngressClass backing the private workload Ingresses. 'tailscale' uses the operator from the platform module; set to your own private ingress controller to bring your own. | `string` | `"tailscale"` | no |
| <a name="input_private_ingress_dns_suffix"></a> [private\_ingress\_dns\_suffix](#input\_private\_ingress\_dns\_suffix) | DNS suffix for the private hostnames (e.g. your MagicDNS tailnet suffix <tailnet>.ts.net). Used only to build output URLs. | `string` | `""` | no |
| <a name="input_private_ingress_hostname_prefix"></a> [private\_ingress\_hostname\_prefix](#input\_private\_ingress\_hostname\_prefix) | Prefix for the private hostnames (keeps names unique per env). Usually equal to name\_prefix. | `string` | `""` | no |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | Private subnet IDs (JupyterHub EFS mount targets) | `list(string)` | `[]` | no |
| <a name="input_private_subnets_cidr_blocks"></a> [private\_subnets\_cidr\_blocks](#input\_private\_subnets\_cidr\_blocks) | Private subnet CIDR blocks, same order as private\_subnets (used to place EFS mount targets in the pod CIDR) | `list(string)` | `[]` | no |
| <a name="input_ray_cluster_chart_version"></a> [ray\_cluster\_chart\_version](#input\_ray\_cluster\_chart\_version) | Version of the kuberay ray-cluster Helm chart | `string` | `"1.6.0"` | no |
| <a name="input_ray_cluster_release_name"></a> [ray\_cluster\_release\_name](#input\_ray\_cluster\_release\_name) | Helm release name for the persistent Ray cluster (auto-prefixed) | `string` | `"ray-cluster"` | no |
| <a name="input_ray_cluster_repository"></a> [ray\_cluster\_repository](#input\_ray\_cluster\_repository) | Helm repository for the kuberay ray-cluster chart | `string` | `"https://ray-project.github.io/kuberay-helm/"` | no |
| <a name="input_ray_dashboard_cluster_name"></a> [ray\_dashboard\_cluster\_name](#input\_ray\_dashboard\_cluster\_name) | RayCluster whose head Pod backs the private ray Ingress. Empty follows the persistent cluster ('<name\_prefix><ray\_cluster\_release\_name>'). | `string` | `""` | no |
| <a name="input_ray_gpu_image_repository"></a> [ray\_gpu\_image\_repository](#input\_ray\_gpu\_image\_repository) | Container image repository for Ray GPU workers. Empty uses the public rayproject/ray image. | `string` | `"rayproject/ray"` | no |
| <a name="input_ray_gpu_image_tag"></a> [ray\_gpu\_image\_tag](#input\_ray\_gpu\_image\_tag) | Image tag for Ray GPU workers. Empty derives '<ray\_version>-gpu'. | `string` | `""` | no |
| <a name="input_ray_image_repository"></a> [ray\_image\_repository](#input\_ray\_image\_repository) | Container image repository for Ray head/worker (CPU). Empty uses the public rayproject/ray image. | `string` | `"rayproject/ray"` | no |
| <a name="input_ray_image_tag"></a> [ray\_image\_tag](#input\_ray\_image\_tag) | Image tag for Ray head/worker (CPU). Empty derives '<ray\_version>'. | `string` | `""` | no |
| <a name="input_ray_storage_bucket_policies"></a> [ray\_storage\_bucket\_policies](#input\_ray\_storage\_bucket\_policies) | Map of IAM policy ARNs attached to the Ray/Argo/Dagster service accounts | `map(string)` | `{}` | no |
| <a name="input_ray_version"></a> [ray\_version](#input\_ray\_version) | Ray version used for the cluster image tags and the RayCluster spec.<br/>Anything connecting via Ray client (`ray://`, e.g. Dagster user code) must<br/>match the cluster on BOTH the Ray version and the Python minor version;<br/>the robust pattern is building those images FROM the same base<br/>(`rayproject/ray:<ray_version>-pyXXX`) so they match by construction. | `string` | `"2.55.1"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to AWS resources | `map(string)` | `{}` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC ID (required for the JupyterHub EFS security group) | `string` | `""` | no |
| <a name="input_vpc_secondary_cidr_blocks"></a> [vpc\_secondary\_cidr\_blocks](#input\_vpc\_secondary\_cidr\_blocks) | Secondary VPC CIDR blocks allowed to reach the JupyterHub EFS (NFS 2049) | `list(string)` | `[]` | no |
| <a name="input_webapp_acm_certificate_arn"></a> [webapp\_acm\_certificate\_arn](#input\_webapp\_acm\_certificate\_arn) | ACM certificate ARN for the ALB HTTPS listener. Required when enable\_webapp\_public\_ingress is true. | `string` | `""` | no |
| <a name="input_webapp_app_name"></a> [webapp\_app\_name](#input\_webapp\_app\_name) | Name used for the webapp namespace/Service/Deployment (auto-prefixed) | `string` | `"webapp"` | no |
| <a name="input_webapp_bucket_policies"></a> [webapp\_bucket\_policies](#input\_webapp\_bucket\_policies) | Map of IAM policy ARNs attached to the webapp service account (e.g. read-only S3 access) | `map(string)` | `{}` | no |
| <a name="input_webapp_container_port"></a> [webapp\_container\_port](#input\_webapp\_container\_port) | Container port the webapp listens on | `number` | `8080` | no |
| <a name="input_webapp_cpu_request"></a> [webapp\_cpu\_request](#input\_webapp\_cpu\_request) | CPU request for the webapp container (also the HPA scaling baseline) | `string` | `"100m"` | no |
| <a name="input_webapp_env"></a> [webapp\_env](#input\_webapp\_env) | Plain (non-secret) environment variables for the webapp container | `map(string)` | `{}` | no |
| <a name="input_webapp_health_check_path"></a> [webapp\_health\_check\_path](#input\_webapp\_health\_check\_path) | HTTP path used for the webapp readiness/liveness probes and ALB health check | `string` | `"/"` | no |
| <a name="input_webapp_hpa_cpu_target"></a> [webapp\_hpa\_cpu\_target](#input\_webapp\_hpa\_cpu\_target) | Target average CPU utilisation (percent of the request) the HPA holds the webapp at | `number` | `70` | no |
| <a name="input_webapp_hpa_max_replicas"></a> [webapp\_hpa\_max\_replicas](#input\_webapp\_hpa\_max\_replicas) | HPA ceiling for the webapp | `number` | `10` | no |
| <a name="input_webapp_hpa_min_replicas"></a> [webapp\_hpa\_min\_replicas](#input\_webapp\_hpa\_min\_replicas) | HPA floor for the webapp (only used with the public ingress) | `number` | `2` | no |
| <a name="input_webapp_ignore_image_changes"></a> [webapp\_ignore\_image\_changes](#input\_webapp\_ignore\_image\_changes) | Ignore changes to the webapp image so an external CI (kubectl set image) owns the running tag. Also ignores replica count so it does not fight the HPA. | `bool` | `false` | no |
| <a name="input_webapp_image"></a> [webapp\_image](#input\_webapp\_image) | Full container image reference for the webapp (required when enable\_webapp is true) | `string` | `""` | no |
| <a name="input_webapp_memory_limit"></a> [webapp\_memory\_limit](#input\_webapp\_memory\_limit) | Memory limit for the webapp container | `string` | `"1Gi"` | no |
| <a name="input_webapp_memory_request"></a> [webapp\_memory\_request](#input\_webapp\_memory\_request) | Memory request for the webapp container | `string` | `"512Mi"` | no |
| <a name="input_webapp_public_host"></a> [webapp\_public\_host](#input\_webapp\_public\_host) | Public hostname the ALB serves and the Route53 alias points at | `string` | `""` | no |
| <a name="input_webapp_replicas"></a> [webapp\_replicas](#input\_webapp\_replicas) | Replica count for the webapp Deployment (ignored once the public HPA is enabled) | `number` | `1` | no |
| <a name="input_webapp_route53_zone_id"></a> [webapp\_route53\_zone\_id](#input\_webapp\_route53\_zone\_id) | Route53 hosted zone id for webapp\_public\_host. Empty skips the alias record. | `string` | `""` | no |
| <a name="input_webapp_secret_env"></a> [webapp\_secret\_env](#input\_webapp\_secret\_env) | Secret environment variables for the webapp container (stored in a Kubernetes Secret and injected via envFrom) | `map(string)` | `{}` | no |
| <a name="input_webapp_session_affinity_seconds"></a> [webapp\_session\_affinity\_seconds](#input\_webapp\_session\_affinity\_seconds) | ClientIP session affinity timeout on the webapp Service (0 disables). Needed for stateful single-pod sessions routed through the Service (e.g. private ingress). | `number` | `0` | no |
| <a name="input_webapp_waf_rate_limit"></a> [webapp\_waf\_rate\_limit](#input\_webapp\_waf\_rate\_limit) | WAF rate-based rule limit: max requests per 5-minute window from a single IP before it is blocked | `number` | `2000` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_dagster_namespace"></a> [dagster\_namespace](#output\_dagster\_namespace) | Dagster namespace (if enabled) |
| <a name="output_dagster_private_url"></a> [dagster\_private\_url](#output\_dagster\_private\_url) | Private URL for Dagit (if the private ingress + DNS suffix are set) |
| <a name="output_jupyterhub_efs_id"></a> [jupyterhub\_efs\_id](#output\_jupyterhub\_efs\_id) | EFS filesystem id holding JupyterHub per-user home and shared directories (if enabled) — the module's only persistent user data; point AWS Backup here |
| <a name="output_jupyterhub_namespace"></a> [jupyterhub\_namespace](#output\_jupyterhub\_namespace) | JupyterHub namespace (if enabled) |
| <a name="output_mlflow_namespace"></a> [mlflow\_namespace](#output\_mlflow\_namespace) | MLflow namespace (if enabled) |
| <a name="output_mlflow_private_url"></a> [mlflow\_private\_url](#output\_mlflow\_private\_url) | Private URL for the MLflow UI |
| <a name="output_ray_dashboard_private_url"></a> [ray\_dashboard\_private\_url](#output\_ray\_dashboard\_private\_url) | Private URL for the Ray dashboard (502s while no Ray cluster is running) |
| <a name="output_ray_namespace"></a> [ray\_namespace](#output\_ray\_namespace) | Ray namespace (if enabled) |
| <a name="output_webapp_namespace"></a> [webapp\_namespace](#output\_webapp\_namespace) | Webapp namespace (if enabled) |
| <a name="output_webapp_private_url"></a> [webapp\_private\_url](#output\_webapp\_private\_url) | Private URL for the webapp |
| <a name="output_webapp_public_url"></a> [webapp\_public\_url](#output\_webapp\_public\_url) | Public HTTPS URL for the webapp (null unless the public ingress is enabled) |
<!-- END_TF_DOCS -->
