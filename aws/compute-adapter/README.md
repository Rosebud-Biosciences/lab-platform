# aws/compute-adapter

The **compute axis** of the AWS backend: everything
[`modules/workloads`](../../modules/workloads) needs that is bound to an EKS
cluster and its VPC rather than to the data. It creates:

- the **EFS filesystem** (+ security group + mount targets in the pod-CIDR
  subnets) behind JupyterHub's home directories, guarded by a dynamic
  `prevent_destroy`;
- the **public edge** annotation set for the AWS Load Balancer Controller:
  internet-facing ALB, ACM TLS with an 80->443 redirect, health check,
  optional target-group stickiness, and an optional **WAFv2** web ACL (AWS
  managed common rules + per-IP rate limit) with CloudWatch request logs;
- **Karpenter NodePools** + EC2NodeClasses per workload environment
  (name-prefixed so previews get their own pools that scale to zero), and the
  `node_pool_roles` mapping that turns them into workloads' `scheduling`
  contract.

and emits three workloads inputs: `jupyterhub_shared_storage` (static NFS on
EFS), `webapp_public_ingress_class_name` / `_annotations` (plus the JupyterHub
twins), and `scheduling`.

```hcl
module "compute" {
  source = "github.com/Rosebud-Biosciences/terraform-aws-lab-platform//aws/compute-adapter?ref=v0.2.0"

  providers = { aws = aws, helm = helm }

  cluster_name                 = module.platform.cluster_name
  vpc_name                     = module.platform.vpc_name
  karpenter_node_iam_role_name = module.platform.karpenter_node_iam_role_name

  enable_jupyterhub           = true
  vpc_id                      = module.network.vpc_id
  private_subnets             = module.network.private_subnets
  private_subnets_cidr_blocks = module.network.private_subnets_cidr_blocks
  vpc_secondary_cidr_blocks   = module.network.vpc_secondary_cidr_blocks

  enable_webapp_public_ingress = true
  webapp_acm_certificate_arn   = var.webapp_acm_certificate_arn
  enable_webapp_waf            = true

  karpenter_node_pools = { default = {}, gpu = { instance_families = ["g5"], taints = [{ key = "nvidia.com/gpu", value = "true", effect = "NoSchedule" }] } }
  node_pool_roles      = { default = ["webapp", "dagster", "mlflow"], gpu = ["ray_worker"] }
}

module "workloads" {
  source = "github.com/Rosebud-Biosciences/terraform-aws-lab-platform//modules/workloads?ref=v0.2.0"
  # ...
  jupyterhub_shared_storage         = module.compute.jupyterhub_shared_storage
  webapp_public_ingress_class_name  = module.compute.webapp_public_ingress_class_name
  webapp_public_ingress_annotations = module.compute.webapp_public_ingress_annotations
  scheduling                        = module.compute.scheduling
}
```

Public DNS is not created here: workloads stamps
`external-dns.alpha.kubernetes.io/hostname` on its public Ingresses, and
`aws/eks-platform`'s `enable_external_dns` publishes the Route53 record.
(Before 0.2 the workloads module wrote a Route53 alias itself; see CHANGELOG.)

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.28 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.28 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_log_group.webapp_waf](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_efs_file_system.jupyterhub](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system) | resource |
| [aws_efs_mount_target.jupyterhub](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_mount_target) | resource |
| [aws_security_group.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_wafv2_web_acl.webapp](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl) | resource |
| [aws_wafv2_web_acl_logging_configuration.webapp](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl_logging_configuration) | resource |
| [helm_release.karpenter_node_pools](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name of the EKS cluster (Karpenter discovery tags, resource names) | `string` | n/a | yes |
| <a name="input_efs_subnet_cidr_octet_prefix"></a> [efs\_subnet\_cidr\_octet\_prefix](#input\_efs\_subnet\_cidr\_octet\_prefix) | First-octet prefix selecting which private subnets host the EFS mount targets | `string` | `"100."` | no |
| <a name="input_enable_jupyterhub"></a> [enable\_jupyterhub](#input\_enable\_jupyterhub) | Create the EFS filesystem (+ security group and mount targets) behind JupyterHub's shared volume | `bool` | `false` | no |
| <a name="input_enable_webapp_public_ingress"></a> [enable\_webapp\_public\_ingress](#input\_enable\_webapp\_public\_ingress) | Emit the ALB annotation set for the public webapp Ingress (and, with enable\_webapp\_waf, create the WAF ACL) | `bool` | `false` | no |
| <a name="input_enable_webapp_waf"></a> [enable\_webapp\_waf](#input\_enable\_webapp\_waf) | Attach a WAFv2 web ACL (AWS managed common rules + a per-IP rate limit) to the public webapp ALB | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name, used in the EFS filesystem name | `string` | `"dev"` | no |
| <a name="input_jupyterhub_acm_certificate_arn"></a> [jupyterhub\_acm\_certificate\_arn](#input\_jupyterhub\_acm\_certificate\_arn) | ACM certificate for the JupyterHub ALB. Empty serves plain HTTP on the (internal) ALB, as before. | `string` | `""` | no |
| <a name="input_jupyterhub_efs_prevent_destroy"></a> [jupyterhub\_efs\_prevent\_destroy](#input\_jupyterhub\_efs\_prevent\_destroy) | Protect the JupyterHub EFS filesystem (user home directories) from<br/>`tofu destroy` via lifecycle.prevent\_destroy (dynamic; OpenTofu >= 1.12).<br/>Leave true for durable environments -- destroys then fail until this is<br/>first flipped off, an intentional two-step. Set false for<br/>previews/ephemeral stamps so they can tear down. | `bool` | `true` | no |
| <a name="input_jupyterhub_ingress_scheme"></a> [jupyterhub\_ingress\_scheme](#input\_jupyterhub\_ingress\_scheme) | ALB scheme for the JupyterHub Ingress annotations ('internal' or 'internet-facing') | `string` | `"internal"` | no |
| <a name="input_jupyterhub_storage_size"></a> [jupyterhub\_storage\_size](#input\_jupyterhub\_storage\_size) | Nominal claim size passed through to workloads (EFS is elastic; this only sizes the PersistentVolume object) | `string` | `"100Gi"` | no |
| <a name="input_karpenter_node_iam_role_name"></a> [karpenter\_node\_iam\_role\_name](#input\_karpenter\_node\_iam\_role\_name) | Name of the Karpenter node IAM role (EC2NodeClass role). Empty disables NodePool creation. | `string` | `""` | no |
| <a name="input_karpenter_node_pools"></a> [karpenter\_node\_pools](#input\_karpenter\_node\_pools) | Map of Karpenter NodePool configurations (created only if karpenter\_node\_iam\_role\_name is set). Keys are referenced by node\_pool\_roles. | <pre>map(object({<br/>    name                   = optional(string)<br/>    instance_sizes         = optional(list(string), ["large", "xlarge", "2xlarge", "4xlarge", "8xlarge"])<br/>    instance_families      = optional(list(string), ["t3a", "c5", "m5", "r5", "r6g"])<br/>    instance_architectures = optional(list(string), ["amd64"])<br/>    capacity_types         = optional(list(string), ["spot", "on-demand"])<br/>    ami_family             = optional(string, "AL2023")<br/>    labels                 = optional(map(string), {})<br/>    taints = optional(list(object({<br/>      key    = string<br/>      value  = optional(string)<br/>      effect = string<br/>    })), [])<br/>    limits = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Same name\_prefix as the modules/workloads instance this serves (NodePools, EFS, WAF names are prefixed with it) | `string` | `""` | no |
| <a name="input_node_pool_roles"></a> [node\_pool\_roles](#input\_node\_pool\_roles) | Which workloads pod roles land on which NodePool, e.g.<br/>{ default = ["webapp", "dagster", "mlflow"], gpu = ["ray\_worker"] }.<br/>Keys are karpenter\_node\_pools keys; values are workloads' scheduling<br/>roles (webapp, dagster, mlflow, jupyterhub, jupyterhub\_singleuser,<br/>ray\_head, ray\_worker). Each listed role gets a<br/>karpenter.sh/nodepool nodeSelector and tolerations for the pool's<br/>taints. Roles not listed schedule anywhere. | `map(list(string))` | `{}` | no |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | Private subnet IDs (EFS mount targets) | `list(string)` | `[]` | no |
| <a name="input_private_subnets_cidr_blocks"></a> [private\_subnets\_cidr\_blocks](#input\_private\_subnets\_cidr\_blocks) | Private subnet CIDR blocks, same order as private\_subnets (used to place EFS mount targets in the pod CIDR) | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every AWS resource | `map(string)` | `{}` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC ID (required for the EFS security group when enable\_jupyterhub) | `string` | `""` | no |
| <a name="input_vpc_name"></a> [vpc\_name](#input\_vpc\_name) | VPC name used by Karpenter EC2NodeClasses for subnet/SG discovery (required when karpenter\_node\_pools is non-empty) | `string` | `""` | no |
| <a name="input_vpc_secondary_cidr_blocks"></a> [vpc\_secondary\_cidr\_blocks](#input\_vpc\_secondary\_cidr\_blocks) | Secondary VPC CIDR blocks allowed to reach the EFS (NFS 2049) | `list(string)` | `[]` | no |
| <a name="input_webapp_acm_certificate_arn"></a> [webapp\_acm\_certificate\_arn](#input\_webapp\_acm\_certificate\_arn) | ACM certificate ARN for the webapp ALB HTTPS listener. Required when enable\_webapp\_public\_ingress is true. | `string` | `""` | no |
| <a name="input_webapp_app_name"></a> [webapp\_app\_name](#input\_webapp\_app\_name) | Same webapp\_app\_name as the workloads instance (WAF and log-group names) | `string` | `"webapp"` | no |
| <a name="input_webapp_health_check_path"></a> [webapp\_health\_check\_path](#input\_webapp\_health\_check\_path) | ALB target-group health check path (same as workloads' webapp\_health\_check\_path) | `string` | `"/"` | no |
| <a name="input_webapp_session_affinity_seconds"></a> [webapp\_session\_affinity\_seconds](#input\_webapp\_session\_affinity\_seconds) | Target-group cookie stickiness duration (0 disables); pair with workloads' webapp\_session\_affinity\_seconds | `number` | `0` | no |
| <a name="input_webapp_waf_log_retention_days"></a> [webapp\_waf\_log\_retention\_days](#input\_webapp\_waf\_log\_retention\_days) | Retention of the WAF request logs (CloudWatch). A year by default so an incident can be traced back; shorten for a high-traffic public site where the log volume costs more than the history is worth. | `number` | `365` | no |
| <a name="input_webapp_waf_rate_limit"></a> [webapp\_waf\_rate\_limit](#input\_webapp\_waf\_rate\_limit) | WAF rate-based rule limit: max requests per 5-minute window from a single IP before it is blocked | `number` | `2000` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_jupyterhub_efs_id"></a> [jupyterhub\_efs\_id](#output\_jupyterhub\_efs\_id) | EFS filesystem id holding JupyterHub per-user home and shared directories (null when off) -- the only persistent user data in the workloads layer; point AWS Backup here |
| <a name="output_jupyterhub_public_ingress_annotations"></a> [jupyterhub\_public\_ingress\_annotations](#output\_jupyterhub\_public\_ingress\_annotations) | The jupyterhub\_public\_ingress\_annotations input for modules/workloads (ALB scheme, target type, optional ACM TLS) |
| <a name="output_jupyterhub_public_ingress_class_name"></a> [jupyterhub\_public\_ingress\_class\_name](#output\_jupyterhub\_public\_ingress\_class\_name) | The jupyterhub\_public\_ingress\_class\_name input for modules/workloads |
| <a name="output_jupyterhub_shared_storage"></a> [jupyterhub\_shared\_storage](#output\_jupyterhub\_shared\_storage) | The jupyterhub\_shared\_storage input for modules/workloads: static NFS PersistentVolumes on the EFS filesystem (nfs\_server is null when JupyterHub is off, which workloads accepts while enable\_jupyterhub is false) |
| <a name="output_node_pool_names"></a> [node\_pool\_names](#output\_node\_pool\_names) | Rendered (prefixed) NodePool names by karpenter\_node\_pools key |
| <a name="output_scheduling"></a> [scheduling](#output\_scheduling) | The scheduling input for modules/workloads: karpenter.sh/nodepool selectors and taint tolerations for every role listed in node\_pool\_roles |
| <a name="output_webapp_public_ingress_annotations"></a> [webapp\_public\_ingress\_annotations](#output\_webapp\_public\_ingress\_annotations) | The webapp\_public\_ingress\_annotations input for modules/workloads: internet-facing ALB, ACM TLS with 80->443 redirect, health check, optional stickiness and WAF ACL; {} when the public ingress is off |
| <a name="output_webapp_public_ingress_class_name"></a> [webapp\_public\_ingress\_class\_name](#output\_webapp\_public\_ingress\_class\_name) | The webapp\_public\_ingress\_class\_name input for modules/workloads (the AWS Load Balancer Controller's class) |
| <a name="output_webapp_waf_acl_arn"></a> [webapp\_waf\_acl\_arn](#output\_webapp\_waf\_acl\_arn) | WAFv2 web ACL ARN attached to the public webapp ALB (null when off) |
<!-- END_TF_DOCS -->
