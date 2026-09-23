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
  plugin**, **KubeRay**, **Argo Events**, and the **Argo Workflows CRDs** (the
  controllers themselves are per environment in `modules/workloads`, like
  Dagster and MLflow, so each environment can keep its own workflow archive);
- optional **Tailscale operator** (provides the `tailscale` IngressClass the
  workload module's private Ingresses use).

Application workloads (webapp, JupyterHub, Dagster, MLflow, the Ray
namespace/cluster) live in the portable [modules/workloads](../../modules/workloads)
module; the EKS-bound pieces they need (EFS, the ALB edge, NodePools) in
[aws/compute-adapter](../compute-adapter). Providers (`kubernetes`/`helm`/`kubectl`
+ the `aws.ecr_public_region` alias) are configured by the caller — see
[examples/minimal](../../examples/minimal).

## Teardown is closed-loop

Every network edge this module and its siblings create is a Terraform-owned
Kubernetes Ingress -- the per-environment UIs (Dagster, MLflow, Argo, the
webapp, Ray) in `modules/workloads`. No Helm chart is allowed to ask for a
`Service` of type `LoadBalancer`. The reason is what a `LoadBalancer`
Service does on EKS: the AWS Load Balancer Controller allocates a load
balancer plus a frontend security group and the cluster-wide shared backend
security group (`k8s-traffic-<cluster>-…`), none of which appear in Terraform
state. When the release, the controller and the nodes go in the same
`destroy`, Helm drops the Service without waiting for the controller's
finalizer, the controller is gone before it can delete the AWS objects, and
the orphaned security groups hold the VPC open. With Terraform-owned
Ingresses the destroy order is right by construction: the Ingress (and its
finalizer) is removed while the controller still runs, then the controller,
then the cluster.

If you add a chart, keep its Services `ClusterIP` and expose it the same way.
(The Argo Workflows chart used to be installed here with `serviceType:
LoadBalancer`; that is exactly the leak described above, and why Argo's
server now lives in `workloads` behind a private Ingress.)

## Who can reach the cluster

The cluster authenticates with **EKS access entries** (API mode). The
`kubernetes`/`helm`/`kubectl` providers sign in with `aws eks get-token`, which
uses whatever AWS credentials are ambient — so every identity that runs `tofu`
or `kubectl` against the cluster needs an access entry, and the entry has to be
created by an identity that already has one.

By default the identity that creates the cluster gets cluster-admin
(`enable_cluster_creator_admin_permissions`). Any other identity — an MFA-gated
operator role, a CI deployer, an SSO permission set — goes in `access_entries`:

```hcl
access_entries = {
  operator = {
    principal_arn = module.bootstrap.operator_admin_role_arn
    policy_associations = {
      admin = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = { type = "cluster" }
      }
    }
  }
  ci = {
    principal_arn = module.bootstrap.ci_deployer_role_arn
    policy_associations = {
      edit = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
        access_scope = { type = "namespace", namespaces = ["webapp", "dagster"] }
      }
    }
  }
}
```

Apply that from the creator identity once; from then on the listed identities
can run the stack themselves, and `enable_cluster_creator_admin_permissions`
can be turned off so a bootstrap credential does not keep standing admin. The
operator-role half of this is written up in
[docs/operator-access.md](../../docs/operator-access.md).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_http"></a> [http](#requirement\_http) | >= 3.4 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.12.1 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.1.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_http"></a> [http](#provider\_http) | >= 3.4 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | >= 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 2.12.1 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.1.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_ebs_csi_driver_irsa"></a> [ebs\_csi\_driver\_irsa](#module\_ebs\_csi\_driver\_irsa) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | ~> 6.8 |
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
| [kubectl_manifest.argo_workflows_crd](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tailscale_dnsconfig](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_namespace_v1.tailscale](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_service_v1.tailscale_nameserver](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [random_password.grafana](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [aws_secretsmanager_secret_version.admin_password_version](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/secretsmanager_secret_version) | data source |
| [http_http.argo_workflows_crd](https://registry.terraform.io/providers/hashicorp/http/latest/docs/data-sources/http) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (e.g. dev, prod), used to derive the cluster name | `string` | n/a | yes |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | List of private subnet IDs available to the cluster | `list(string)` | n/a | yes |
| <a name="input_private_subnets_cidr_blocks"></a> [private\_subnets\_cidr\_blocks](#input\_private\_subnets\_cidr\_blocks) | List of private subnet CIDR blocks (same order as private\_subnets) | `list(string)` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS region | `string` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC ID where the EKS cluster will be deployed | `string` | n/a | yes |
| <a name="input_vpc_security_group_id"></a> [vpc\_security\_group\_id](#input\_vpc\_security\_group\_id) | Security group ID allowed to reach the cluster/nodes from within the VPC (e.g. the Tailscale relay SG for private admin access) | `string` | n/a | yes |
| <a name="input_access_entries"></a> [access\_entries](#input\_access\_entries) | Additional EKS access entries, keyed by a stable label. Same shape as the<br/>upstream terraform-aws-modules/eks input: each entry names a principal and<br/>zero or more policy associations. Use it for every non-creator identity<br/>that runs tofu or kubectl here -- an MFA-gated operator role (see<br/>docs/operator-access.md), a CI role that deploys workloads, an SSO<br/>permission set. Policy ARNs are the AWS-managed cluster access policies,<br/>e.g. arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy. | <pre>map(object({<br/>    principal_arn     = string<br/>    type              = optional(string, "STANDARD")<br/>    kubernetes_groups = optional(list(string))<br/>    user_name         = optional(string)<br/>    tags              = optional(map(string), {})<br/>    policy_associations = optional(map(object({<br/>      policy_arn = string<br/>      access_scope = object({<br/>        type       = string<br/>        namespaces = optional(list(string))<br/>      })<br/>    })), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_argo_workflows_version"></a> [argo\_workflows\_version](#input\_argo\_workflows\_version) | Argo Workflows release tag the CRDs are taken from. Keep equal to the appVersion of modules/workloads' argo\_workflows\_chart\_version (chart 2.0.6 -> v4.1.3). | `string` | `"v4.1.3"` | no |
| <a name="input_cluster_endpoint_private_access"></a> [cluster\_endpoint\_private\_access](#input\_cluster\_endpoint\_private\_access) | Whether the EKS cluster endpoint is privately accessible | `bool` | `true` | no |
| <a name="input_cluster_endpoint_public_access"></a> [cluster\_endpoint\_public\_access](#input\_cluster\_endpoint\_public\_access) | Whether the EKS cluster endpoint is publicly accessible | `bool` | `false` | no |
| <a name="input_cluster_suffix"></a> [cluster\_suffix](#input\_cluster\_suffix) | Optional suffix for the cluster name (e.g. 'pr123' -> 'eks-dev-pr123') | `string` | `""` | no |
| <a name="input_core_node_group_desired_size"></a> [core\_node\_group\_desired\_size](#input\_core\_node\_group\_desired\_size) | Desired number of nodes in the core node group | `number` | `2` | no |
| <a name="input_core_node_group_instance_types"></a> [core\_node\_group\_instance\_types](#input\_core\_node\_group\_instance\_types) | Instance types for the core managed node group that hosts the add-ons | `list(string)` | <pre>[<br/>  "t3a.large"<br/>]</pre> | no |
| <a name="input_core_node_group_max_size"></a> [core\_node\_group\_max\_size](#input\_core\_node\_group\_max\_size) | Maximum number of nodes in the core node group | `number` | `2` | no |
| <a name="input_core_node_group_min_size"></a> [core\_node\_group\_min\_size](#input\_core\_node\_group\_min\_size) | Minimum number of nodes in the core node group | `number` | `1` | no |
| <a name="input_eks_cluster_version"></a> [eks\_cluster\_version](#input\_eks\_cluster\_version) | Kubernetes version for the EKS cluster. Hold at 1.35 (or disable cluster-autoscaler) before moving to 1.36: the autoscaler chart has no 1.36 image yet. | `string` | `"1.35"` | no |
| <a name="input_enable_argo_events"></a> [enable\_argo\_events](#input\_enable\_argo\_events) | Enable Argo Events | `bool` | `false` | no |
| <a name="input_enable_argo_workflows"></a> [enable\_argo\_workflows](#input\_enable\_argo\_workflows) | Install the Argo Workflows CRDs (cluster-scoped, from the upstream release at argo\_workflows\_version). The controller, server, UI and optional archive are per environment in modules/workloads (enable\_argo\_workflows there). | `bool` | `false` | no |
| <a name="input_enable_aws_fluentbit"></a> [enable\_aws\_fluentbit](#input\_enable\_aws\_fluentbit) | Enable AWS FluentBit -> CloudWatch logging | `bool` | `false` | no |
| <a name="input_enable_aws_load_balancer_controller"></a> [enable\_aws\_load\_balancer\_controller](#input\_enable\_aws\_load\_balancer\_controller) | Enable AWS Load Balancer Controller | `bool` | `true` | no |
| <a name="input_enable_cluster_autoscaler"></a> [enable\_cluster\_autoscaler](#input\_enable\_cluster\_autoscaler) | Enable Cluster Autoscaler (leave off when using Karpenter for burst) | `bool` | `false` | no |
| <a name="input_enable_cluster_creator_admin_permissions"></a> [enable\_cluster\_creator\_admin\_permissions](#input\_enable\_cluster\_creator\_admin\_permissions) | Give the identity that creates the cluster a cluster-admin access entry.<br/>Leave on for the first apply (otherwise nobody can reach the API to install<br/>the add-ons); turn off once access\_entries carries the identities you<br/>actually operate from, so a bootstrap credential does not keep standing<br/>admin. Turning it off removes the creator's entry -- make sure the identity<br/>running that apply is in access\_entries first. | `bool` | `true` | no |
| <a name="input_enable_external_dns"></a> [enable\_external\_dns](#input\_enable\_external\_dns) | Enable external-dns so public hostnames follow the Ingresses modules/workloads creates (it stamps external-dns.alpha.kubernetes.io/hostname). Requires external\_dns\_route53\_zone\_arns. | `bool` | `false` | no |
| <a name="input_enable_gpu_support"></a> [enable\_gpu\_support](#input\_enable\_gpu\_support) | Enable the NVIDIA GPU Operator | `bool` | `false` | no |
| <a name="input_enable_karpenter"></a> [enable\_karpenter](#input\_enable\_karpenter) | Enable the Karpenter controller + CRDs (NodePools are defined per environment by aws/compute-adapter) | `bool` | `true` | no |
| <a name="input_enable_kube_prometheus"></a> [enable\_kube\_prometheus](#input\_enable\_kube\_prometheus) | Enable the Prometheus + Grafana monitoring stack | `bool` | `false` | no |
| <a name="input_enable_kubecost"></a> [enable\_kubecost](#input\_enable\_kubecost) | Enable Kubecost for cost monitoring | `bool` | `false` | no |
| <a name="input_enable_metrics_server"></a> [enable\_metrics\_server](#input\_enable\_metrics\_server) | Enable Kubernetes Metrics Server | `bool` | `true` | no |
| <a name="input_enable_network_policy"></a> [enable\_network\_policy](#input\_enable\_network\_policy) | Enable the VPC CNI's network policy agent so NetworkPolicies are enforced. modules/workloads creates them to keep its login proxies and the tailnet Ingress the only way into the UIs; without enforcement any pod can reach a UI directly and, in auth mode "headers", assert any identity. On an existing cluster, turning it on makes existing policies bite: check that modules/workloads network\_policies.ingress\_namespaces names this cluster's ingress namespace (the Tailscale operator's is "tailscale") first. | `bool` | `true` | no |
| <a name="input_enable_neuron_support"></a> [enable\_neuron\_support](#input\_enable\_neuron\_support) | Enable the AWS Neuron device plugin (Inferentia/Trainium) | `bool` | `false` | no |
| <a name="input_enable_ray"></a> [enable\_ray](#input\_enable\_ray) | Install the KubeRay operator (the Ray namespace/cluster live in the workloads module) | `bool` | `false` | no |
| <a name="input_enable_tailscale_dnsconfig"></a> [enable\_tailscale\_dnsconfig](#input\_enable\_tailscale\_dnsconfig) | Let pods resolve tailnet names (e.g. a tailnet-only Dex or Keycloak issuer at https://dex.<tailnet>.ts.net) the way browsers do: the Tailscale operator's DNSConfig nameserver, a Service for it at tailscale\_nameserver\_cluster\_ip, and a CoreDNS stub zone for tailscale\_dns\_zone forwarding there. Needs the Tailscale operator. | `bool` | `false` | no |
| <a name="input_enable_tailscale_operator"></a> [enable\_tailscale\_operator](#input\_enable\_tailscale\_operator) | Deploy the Tailscale Kubernetes operator (provides the 'tailscale' IngressClass used by private workload Ingresses) | `bool` | `false` | no |
| <a name="input_external_dns_domain_filters"></a> [external\_dns\_domain\_filters](#input\_external\_dns\_domain\_filters) | Domains external-dns manages records for (e.g. ["example.com"]); empty means every zone it can reach | `list(string)` | `[]` | no |
| <a name="input_external_dns_route53_zone_arns"></a> [external\_dns\_route53\_zone\_arns](#input\_external\_dns\_route53\_zone\_arns) | Route53 hosted zone ARNs external-dns may write to (its IRSA policy is scoped to these) | `list(string)` | `[]` | no |
| <a name="input_karpenter_version"></a> [karpenter\_version](#input\_karpenter\_version) | Version of the Karpenter controller and CRD Helm charts | `string` | `"1.13.0"` | no |
| <a name="input_kube_prometheus_helm_values_override"></a> [kube\_prometheus\_helm\_values\_override](#input\_kube\_prometheus\_helm\_values\_override) | Extra YAML (raw string) deep-merged over the kube-prometheus-stack defaults by Helm (later wins) | `string` | `""` | no |
| <a name="input_kuberay_operator_version"></a> [kuberay\_operator\_version](#input\_kuberay\_operator\_version) | KubeRay operator Helm chart version | `string` | `"1.6.1"` | no |
| <a name="input_node_subnet_ids"></a> [node\_subnet\_ids](#input\_node\_subnet\_ids) | Explicit subnet IDs to place the data plane (nodes) in. Empty derives them<br/>from private\_subnets, excluding any subnet inside a secondary CIDR (pod IP<br/>space). Set this explicitly if your secondary CIDR is not 100.x. | `list(string)` | `[]` | no |
| <a name="input_secondary_vpc_cidr_octet_prefix"></a> [secondary\_vpc\_cidr\_octet\_prefix](#input\_secondary\_vpc\_cidr\_octet\_prefix) | First-octet prefix of the secondary (pod) CIDR used to exclude those subnets from the data plane when node\_subnet\_ids is empty | `string` | `"100."` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_tailscale_dns_zone"></a> [tailscale\_dns\_zone](#input\_tailscale\_dns\_zone) | Zone CoreDNS forwards to the tailnet nameserver | `string` | `"ts.net"` | no |
| <a name="input_tailscale_nameserver_cluster_ip"></a> [tailscale\_nameserver\_cluster\_ip](#input\_tailscale\_nameserver\_cluster\_ip) | A free ClusterIP inside the cluster's service CIDR for the tailnet nameserver (fixed, so CoreDNS's stub zone is known at plan time), e.g. 172.20.0.53 | `string` | `""` | no |
| <a name="input_tailscale_oauth_client_id"></a> [tailscale\_oauth\_client\_id](#input\_tailscale\_oauth\_client\_id) | Tailscale OAuth client ID for the operator (tagged tag:k8s-operator). Required if enable\_tailscale\_operator is true. | `string` | `""` | no |
| <a name="input_tailscale_oauth_client_secret"></a> [tailscale\_oauth\_client\_secret](#input\_tailscale\_oauth\_client\_secret) | Tailscale OAuth client secret paired with tailscale\_oauth\_client\_id | `string` | `""` | no |
| <a name="input_tailscale_operator_chart_version"></a> [tailscale\_operator\_chart\_version](#input\_tailscale\_operator\_chart\_version) | Pinned tailscale-operator Helm chart version (tracks the Tailscale client<br/>release train; see https://pkgs.tailscale.com/helmcharts). This one pin is<br/>the Tailscale version of every container on the tailnet: the operator and<br/>the Ingress proxies it runs for each private UI. Containers never<br/>self-update, so bumping it is how Tailscale CVE fixes reach the cluster;<br/>the operator rolls each proxy to the new image (node identity persists,<br/>expect a pod-restart blip per UI). See docs/upgrades.md. | `string` | `"1.102.3"` | no |
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
| <a name="output_external_dns_enabled"></a> [external\_dns\_enabled](#output\_external\_dns\_enabled) | Whether external-dns runs on this cluster (public Ingress hostnames then resolve without tofu-managed records) |
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
