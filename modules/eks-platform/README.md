# eks-platform

The cluster and its **cluster-wide operators** — the shared substrate that any
number of workload environments (prod + previews) run on top of.

Creates the EKS cluster (API access-entry auth, private endpoint by default) and
a core managed node group, then layers on toggleable add-ons:

- always-on essentials: **Karpenter**, the **AWS Load Balancer Controller**,
  **metrics-server**;
- optional cost-drivers (off by default): **Prometheus/Grafana**, **Kubecost**,
  **FluentBit**;
- optional accelerators/operators: **NVIDIA GPU operator**, **Neuron device
  plugin**, **KubeRay**, **Argo Workflows/Events**;
- optional **Tailscale operator** (provides the `tailscale` IngressClass the
  workload module's private Ingresses use).

Application workloads (webapp, JupyterHub, Dagster, MLflow, the Ray
namespace/cluster, NodePools) live in the sibling [workloads](../workloads)
module. Providers (`kubernetes`/`helm`/`kubectl` + the `aws.ecr_public_region`
alias) are configured by the caller — see [examples/minimal](../../examples/minimal).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.12.1 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.1.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.62.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | 3.2.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 3.2.1 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.9.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_ebs_csi_driver_irsa"></a> [ebs\_csi\_driver\_irsa](#module\_ebs\_csi\_driver\_irsa) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | ~> 5.20 |
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | ~> 21.0 |
| <a name="module_eks_blueprints_addons"></a> [eks\_blueprints\_addons](#module\_eks\_blueprints\_addons) | aws-ia/eks-blueprints-addons/aws | ~> 1.24.3 |
| <a name="module_eks_blueprints_addons_core"></a> [eks\_blueprints\_addons\_core](#module\_eks\_blueprints\_addons\_core) | aws-ia/eks-blueprints-addons/aws | ~> 1.24.3 |

## Resources

| Name | Type |
|------|------|
| [aws_eks_access_entry.karpenter_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_secretsmanager_secret.grafana](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.grafana](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [helm_release.aws_neuron_device_plugin](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.karpenter_crd](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.kubecost](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.kuberay_operator](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.nvidia_gpu_operator](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.tailscale_operator](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_namespace_v1.tailscale](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [random_password.grafana](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [aws_secretsmanager_secret_version.admin_password_version](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/secretsmanager_secret_version) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (e.g. dev, prod), used to derive the cluster name | `string` | n/a | yes |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | List of private subnet IDs available to the cluster | `list(string)` | n/a | yes |
| <a name="input_private_subnets_cidr_blocks"></a> [private\_subnets\_cidr\_blocks](#input\_private\_subnets\_cidr\_blocks) | List of private subnet CIDR blocks (same order as private\_subnets) | `list(string)` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS region | `string` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC ID where the EKS cluster will be deployed | `string` | n/a | yes |
| <a name="input_vpc_security_group_id"></a> [vpc\_security\_group\_id](#input\_vpc\_security\_group\_id) | Security group ID allowed to reach the cluster/nodes from within the VPC (e.g. the Tailscale relay SG for private admin access) | `string` | n/a | yes |
| <a name="input_cluster_endpoint_private_access"></a> [cluster\_endpoint\_private\_access](#input\_cluster\_endpoint\_private\_access) | Whether the EKS cluster endpoint is privately accessible | `bool` | `true` | no |
| <a name="input_cluster_endpoint_public_access"></a> [cluster\_endpoint\_public\_access](#input\_cluster\_endpoint\_public\_access) | Whether the EKS cluster endpoint is publicly accessible | `bool` | `false` | no |
| <a name="input_cluster_suffix"></a> [cluster\_suffix](#input\_cluster\_suffix) | Optional suffix for the cluster name (e.g. 'pr123' -> 'eks-dev-pr123') | `string` | `""` | no |
| <a name="input_core_node_group_desired_size"></a> [core\_node\_group\_desired\_size](#input\_core\_node\_group\_desired\_size) | Desired number of nodes in the core node group | `number` | `2` | no |
| <a name="input_core_node_group_instance_types"></a> [core\_node\_group\_instance\_types](#input\_core\_node\_group\_instance\_types) | Instance types for the core managed node group that hosts the add-ons | `list(string)` | <pre>[<br/>  "t3a.large"<br/>]</pre> | no |
| <a name="input_core_node_group_max_size"></a> [core\_node\_group\_max\_size](#input\_core\_node\_group\_max\_size) | Maximum number of nodes in the core node group | `number` | `2` | no |
| <a name="input_core_node_group_min_size"></a> [core\_node\_group\_min\_size](#input\_core\_node\_group\_min\_size) | Minimum number of nodes in the core node group | `number` | `1` | no |
| <a name="input_eks_cluster_version"></a> [eks\_cluster\_version](#input\_eks\_cluster\_version) | Kubernetes version for the EKS cluster. Hold at 1.35 (or disable cluster-autoscaler) before moving to 1.36: the autoscaler chart has no 1.36 image yet. | `string` | `"1.35"` | no |
| <a name="input_enable_argo_events"></a> [enable\_argo\_events](#input\_enable\_argo\_events) | Enable Argo Events | `bool` | `false` | no |
| <a name="input_enable_argo_workflows"></a> [enable\_argo\_workflows](#input\_enable\_argo\_workflows) | Install the Argo Workflows controller (workflow templates/RBAC live in the workloads module) | `bool` | `false` | no |
| <a name="input_enable_aws_fluentbit"></a> [enable\_aws\_fluentbit](#input\_enable\_aws\_fluentbit) | Enable AWS FluentBit -> CloudWatch logging | `bool` | `false` | no |
| <a name="input_enable_aws_load_balancer_controller"></a> [enable\_aws\_load\_balancer\_controller](#input\_enable\_aws\_load\_balancer\_controller) | Enable AWS Load Balancer Controller | `bool` | `true` | no |
| <a name="input_enable_cluster_autoscaler"></a> [enable\_cluster\_autoscaler](#input\_enable\_cluster\_autoscaler) | Enable Cluster Autoscaler (leave off when using Karpenter for burst) | `bool` | `false` | no |
| <a name="input_enable_gpu_support"></a> [enable\_gpu\_support](#input\_enable\_gpu\_support) | Enable the NVIDIA GPU Operator | `bool` | `false` | no |
| <a name="input_enable_karpenter"></a> [enable\_karpenter](#input\_enable\_karpenter) | Enable the Karpenter controller + CRDs (NodePools are defined in the workloads module) | `bool` | `true` | no |
| <a name="input_enable_kube_prometheus"></a> [enable\_kube\_prometheus](#input\_enable\_kube\_prometheus) | Enable the Prometheus + Grafana monitoring stack | `bool` | `false` | no |
| <a name="input_enable_kubecost"></a> [enable\_kubecost](#input\_enable\_kubecost) | Enable Kubecost for cost monitoring | `bool` | `false` | no |
| <a name="input_enable_metrics_server"></a> [enable\_metrics\_server](#input\_enable\_metrics\_server) | Enable Kubernetes Metrics Server | `bool` | `true` | no |
| <a name="input_enable_neuron_support"></a> [enable\_neuron\_support](#input\_enable\_neuron\_support) | Enable the AWS Neuron device plugin (Inferentia/Trainium) | `bool` | `false` | no |
| <a name="input_enable_ray"></a> [enable\_ray](#input\_enable\_ray) | Install the KubeRay operator (the Ray namespace/cluster live in the workloads module) | `bool` | `false` | no |
| <a name="input_enable_tailscale_operator"></a> [enable\_tailscale\_operator](#input\_enable\_tailscale\_operator) | Deploy the Tailscale Kubernetes operator (provides the 'tailscale' IngressClass used by private workload Ingresses) | `bool` | `false` | no |
| <a name="input_karpenter_version"></a> [karpenter\_version](#input\_karpenter\_version) | Version of the Karpenter controller and CRD Helm charts | `string` | `"1.13.0"` | no |
| <a name="input_kube_prometheus_helm_values_override"></a> [kube\_prometheus\_helm\_values\_override](#input\_kube\_prometheus\_helm\_values\_override) | Extra YAML (raw string) deep-merged over the kube-prometheus-stack defaults by Helm (later wins) | `string` | `""` | no |
| <a name="input_kuberay_operator_version"></a> [kuberay\_operator\_version](#input\_kuberay\_operator\_version) | KubeRay operator Helm chart version | `string` | `"1.6.1"` | no |
| <a name="input_node_subnet_ids"></a> [node\_subnet\_ids](#input\_node\_subnet\_ids) | Explicit subnet IDs to place the data plane (nodes) in. Empty derives them<br/>from private\_subnets, excluding any subnet inside a secondary CIDR (pod IP<br/>space). Set this explicitly if your secondary CIDR is not 100.x. | `list(string)` | `[]` | no |
| <a name="input_secondary_vpc_cidr_octet_prefix"></a> [secondary\_vpc\_cidr\_octet\_prefix](#input\_secondary\_vpc\_cidr\_octet\_prefix) | First-octet prefix of the secondary (pod) CIDR used to exclude those subnets from the data plane when node\_subnet\_ids is empty | `string` | `"100."` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_tailscale_oauth_client_id"></a> [tailscale\_oauth\_client\_id](#input\_tailscale\_oauth\_client\_id) | Tailscale OAuth client ID for the operator (tagged tag:k8s-operator). Required if enable\_tailscale\_operator is true. | `string` | `""` | no |
| <a name="input_tailscale_oauth_client_secret"></a> [tailscale\_oauth\_client\_secret](#input\_tailscale\_oauth\_client\_secret) | Tailscale OAuth client secret paired with tailscale\_oauth\_client\_id | `string` | `""` | no |
| <a name="input_tailscale_operator_chart_version"></a> [tailscale\_operator\_chart\_version](#input\_tailscale\_operator\_chart\_version) | Pinned tailscale-operator Helm chart version (see https://pkgs.tailscale.com/helmcharts) | `string` | `"1.98.9"` | no |
| <a name="input_vpc_name"></a> [vpc\_name](#input\_vpc\_name) | VPC name used by Karpenter node templates for subnet discovery. Empty derives 'vpc-{environment}'. | `string` | `""` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_cluster_arn"></a> [cluster\_arn](#output\_cluster\_arn) | The ARN of the EKS cluster |
| <a name="output_cluster_certificate_authority_data"></a> [cluster\_certificate\_authority\_data](#output\_cluster\_certificate\_authority\_data) | Base64 encoded certificate data required to communicate with the cluster |
| <a name="output_cluster_endpoint"></a> [cluster\_endpoint](#output\_cluster\_endpoint) | The endpoint for the EKS cluster API server |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | The name of the EKS cluster |
| <a name="output_cluster_primary_security_group_id"></a> [cluster\_primary\_security\_group\_id](#output\_cluster\_primary\_security\_group\_id) | ID of the cluster primary security group |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | ID of the cluster security group |
| <a name="output_cluster_version"></a> [cluster\_version](#output\_cluster\_version) | The Kubernetes version for the EKS cluster |
| <a name="output_eks_managed_node_groups"></a> [eks\_managed\_node\_groups](#output\_eks\_managed\_node\_groups) | Map of EKS managed node groups created |
| <a name="output_environment"></a> [environment](#output\_environment) | Environment name |
| <a name="output_grafana_secret_name"></a> [grafana\_secret\_name](#output\_grafana\_secret\_name) | Name of the Grafana admin password secret in Secrets Manager (when monitoring is enabled) |
| <a name="output_karpenter_node_iam_role_arn"></a> [karpenter\_node\_iam\_role\_arn](#output\_karpenter\_node\_iam\_role\_arn) | ARN of the Karpenter node IAM role (consumed by the workloads module NodePools) |
| <a name="output_karpenter_node_iam_role_name"></a> [karpenter\_node\_iam\_role\_name](#output\_karpenter\_node\_iam\_role\_name) | Name of the Karpenter node IAM role (used by NodePool nodeRole) |
| <a name="output_node_security_group_id"></a> [node\_security\_group\_id](#output\_node\_security\_group\_id) | ID of the node security group |
| <a name="output_oidc_provider"></a> [oidc\_provider](#output\_oidc\_provider) | The OIDC provider URL (without protocol) |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | The ARN of the IRSA OIDC provider |
| <a name="output_region"></a> [region](#output\_region) | AWS region |
| <a name="output_tailscale_operator_enabled"></a> [tailscale\_operator\_enabled](#output\_tailscale\_operator\_enabled) | Whether the Tailscale operator (and its 'tailscale' IngressClass) is installed |
| <a name="output_vpc_name"></a> [vpc\_name](#output\_vpc\_name) | VPC name used for Karpenter subnet/SG discovery |
<!-- END_TF_DOCS -->
