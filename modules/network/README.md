# network

A VPC sized for EKS: primary CIDR for nodes/services plus a **secondary CIDR**
(default `100.64.0.0/16`) that gives pods their own IP space (VPC-CNI custom
networking). Public, private, intra (control-plane), and database subnets are
laid out across the requested number of AZs, with a single shared NAT gateway by
default (cheap) or one-per-AZ for production. Interface/gateway VPC endpoints
keep AWS-bound traffic off the NAT gateway.

Optionally deploys a **Tailscale subnet router** (an EC2 instance advertising the
VPC routes into your tailnet) — the private-access path used to reach a private
EKS API endpoint without a bastion. Off by default; bring your own
`ts_relay_client_id`/`ts_relay_client_secret` to enable it.

```hcl
module "network" {
  source = "your-org/lab-platform/aws//modules/network"

  name        = "vpc-dev"
  environment = "dev"
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0.0 |
| <a name="requirement_tailscale"></a> [tailscale](#requirement\_tailscale) | >= 0.18 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.62.0 |
| <a name="provider_tailscale"></a> [tailscale](#provider\_tailscale) | 0.29.2 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 6.0 |
| <a name="module_vpc_endpoints"></a> [vpc\_endpoints](#module\_vpc\_endpoints) | terraform-aws-modules/vpc/aws//modules/vpc-endpoints | ~> 6.0 |

## Resources

| Name | Type |
|------|------|
| [aws_iam_instance_profile.tailscale](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.tailscale](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.tailscale_ssm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.tailscale](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_network_interface.tailscale](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/network_interface) | resource |
| [aws_security_group.tailscale](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.tailscale_all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.tailscale_icmp](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.tailscale_wireguard](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [tailscale_tailnet_key.relay](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs/resources/tailnet_key) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_iam_policy_document.tailscale_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_ssm_parameter.ubuntu](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name"></a> [name](#input\_name) | VPC name | `string` | n/a | yes |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | EKS cluster name tagged on private subnets for Karpenter subnet discovery. Empty derives "eks-<environment>". | `string` | `""` | no |
| <a name="input_enable_tailscale_subnet_router"></a> [enable\_tailscale\_subnet\_router](#input\_enable\_tailscale\_subnet\_router) | Deploy a Tailscale subnet-router EC2 instance that advertises the private/intra subnet routes into your tailnet (the private-access path used for a private EKS API endpoint) | `bool` | `false` | no |
| <a name="input_enable_vpc_endpoints"></a> [enable\_vpc\_endpoints](#input\_enable\_vpc\_endpoints) | Create interface/gateway VPC endpoints (S3, ECR, STS, logs, EC2, ELB) to keep AWS traffic off the NAT gateway | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name, used to name the Tailscale relay and (by default) derive the Karpenter/EKS discovery tag | `string` | `"dev"` | no |
| <a name="input_num_availability_zones"></a> [num\_availability\_zones](#input\_num\_availability\_zones) | Number of availability zones to spread subnets across | `number` | `3` | no |
| <a name="input_secondary_vpc_cidr"></a> [secondary\_vpc\_cidr](#input\_secondary\_vpc\_cidr) | Secondary CIDR block for the VPC (extra pod IP space for EKS/VPC-CNI) | `string` | `"100.64.0.0/16"` | no |
| <a name="input_single_nat_gateway"></a> [single\_nat\_gateway](#input\_single\_nat\_gateway) | Use a single shared NAT gateway instead of one per AZ. Cheaper for dev/OSS defaults; set false for HA production. | `bool` | `true` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of tags to add to all resources | `map(string)` | `{}` | no |
| <a name="input_ts_relay_client_id"></a> [ts\_relay\_client\_id](#input\_ts\_relay\_client\_id) | Tailscale OAuth client ID used to mint the relay's pre-auth key. Must be a<br/>client that OWNS tag:subnet-router (auth keys inherit only their client's<br/>tags). Required when enable\_tailscale\_subnet\_router = true. | `string` | `""` | no |
| <a name="input_ts_relay_client_secret"></a> [ts\_relay\_client\_secret](#input\_ts\_relay\_client\_secret) | Tailscale subnet-router OAuth client secret. Required when enable\_tailscale\_subnet\_router = true. | `string` | `""` | no |
| <a name="input_ts_relay_instance_type"></a> [ts\_relay\_instance\_type](#input\_ts\_relay\_instance\_type) | EC2 instance type for the Tailscale relay | `string` | `"t3a.micro"` | no |
| <a name="input_ts_relay_tag"></a> [ts\_relay\_tag](#input\_ts\_relay\_tag) | Tailscale ACL tag applied to the relay's pre-auth key (its autoApprovers should cover the advertised routes) | `string` | `"tag:subnet-router"` | no |
| <a name="input_ts_tailnet"></a> [ts\_tailnet](#input\_ts\_tailnet) | Tailscale tailnet; "-" resolves to the OAuth client's default tailnet. | `string` | `"-"` | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | The primary CIDR block for the VPC | `string` | `"10.0.0.0/16"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_database_subnet_group_name"></a> [database\_subnet\_group\_name](#output\_database\_subnet\_group\_name) | Name of the database subnet group |
| <a name="output_database_subnets"></a> [database\_subnets](#output\_database\_subnets) | List of IDs of database subnets |
| <a name="output_default_security_group_id"></a> [default\_security\_group\_id](#output\_default\_security\_group\_id) | The ID of the security group created by default on VPC creation |
| <a name="output_intra_subnets"></a> [intra\_subnets](#output\_intra\_subnets) | List of IDs of intra (control-plane) subnets |
| <a name="output_private_route_table_ids"></a> [private\_route\_table\_ids](#output\_private\_route\_table\_ids) | List of IDs of private route tables |
| <a name="output_private_subnets"></a> [private\_subnets](#output\_private\_subnets) | List of IDs of private subnets |
| <a name="output_private_subnets_cidr_blocks"></a> [private\_subnets\_cidr\_blocks](#output\_private\_subnets\_cidr\_blocks) | List of CIDR blocks of private subnets |
| <a name="output_public_subnets"></a> [public\_subnets](#output\_public\_subnets) | List of IDs of public subnets |
| <a name="output_tailscale_instance_id"></a> [tailscale\_instance\_id](#output\_tailscale\_instance\_id) | The ID of the Tailscale relay instance (empty when disabled) |
| <a name="output_tailscale_ip"></a> [tailscale\_ip](#output\_tailscale\_ip) | The private IP address of the Tailscale relay (empty when disabled) |
| <a name="output_tailscale_security_group_id"></a> [tailscale\_security\_group\_id](#output\_tailscale\_security\_group\_id) | The dedicated Tailscale relay security group (empty when disabled). All<br/>tailnet traffic into the VPC is SNAT'd to the relay, so this is the source<br/>SG that in-VPC services (e.g. the private EKS API) should trust for admin<br/>access. |
| <a name="output_vpc_cidr_block"></a> [vpc\_cidr\_block](#output\_vpc\_cidr\_block) | The primary CIDR block of the VPC |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | The ID of the VPC |
| <a name="output_vpc_name"></a> [vpc\_name](#output\_vpc\_name) | The name of the VPC |
| <a name="output_vpc_secondary_cidr_blocks"></a> [vpc\_secondary\_cidr\_blocks](#output\_vpc\_secondary\_cidr\_blocks) | List of secondary CIDR blocks of the VPC |
<!-- END_TF_DOCS -->
