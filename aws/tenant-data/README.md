# tenant-data

One tenant's identity and slice of data on AWS, instantiated once per tenant:

- an IAM role only the tenant's own ServiceAccounts can assume (its stamps'
  workloads, its JupyterHub group profiles, its Dagster code location);
- storage: `shared_prefix` confines it to `s3://<shared>/tenants/<tenant>/`
  (list, read, write, delete there and nowhere else of that bucket), `own`
  gives it a bucket and KMS key of its own ([`aws/s3-bucket`](../s3-bucket));
- `own_database`: a database and owner role on the caller's Postgres for its
  stamps.

`service_account_annotations` feeds [`modules/tenancy`](../../modules/tenancy)'s
`tenant_identity`. The postgresql provider must be configured even when no
tenant has its own database.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.40 |
| <a name="requirement_postgresql"></a> [postgresql](#requirement\_postgresql) | >= 1.25 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.6 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.40 |
| <a name="provider_postgresql"></a> [postgresql](#provider\_postgresql) | >= 1.25 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.6 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_bucket"></a> [bucket](#module\_bucket) | ../s3-bucket | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_iam_role.tenant](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [postgresql_database.tenant](https://registry.terraform.io/providers/cyrilgdn/postgresql/latest/docs/resources/database) | resource |
| [postgresql_role.owner](https://registry.terraform.io/providers/cyrilgdn/postgresql/latest/docs/resources/role) | resource |
| [random_password.database](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [aws_iam_policy_document.assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_oidc_issuer"></a> [oidc\_issuer](#input\_oidc\_issuer) | The cluster's OIDC issuer URL (with or without https://) | `string` | n/a | yes |
| <a name="input_oidc_provider_arn"></a> [oidc\_provider\_arn](#input\_oidc\_provider\_arn) | The cluster's IAM OIDC provider ARN (aws/eks-platform or aws/oidc-provider) | `string` | n/a | yes |
| <a name="input_service_accounts"></a> [service\_accounts](#input\_service\_accounts) | The tenant's Kubernetes ServiceAccounts, as namespace/name (its stamps' workloads, its JupyterHub group profiles jupyterhub/jh-<tenant>-<group>, its Dagster code location dagster/dagster-<tenant>) | `list(string)` | n/a | yes |
| <a name="input_tenant"></a> [tenant](#input\_tenant) | Tenant slug (modules/tenancy) | `string` | n/a | yes |
| <a name="input_bucket"></a> [bucket](#input\_bucket) | "shared\_prefix": the tenant gets s3://<shared\_bucket>/tenants/<tenant>/ and nothing else of that bucket. "own": a bucket of its own (aws/s3-bucket, its own KMS key). | `string` | `"shared_prefix"` | no |
| <a name="input_database"></a> [database](#input\_database) | "shared": the tenant reads the app database through row-level security (modules/postgres-group-roles). "own\_database": a database and owner role of its own on the caller's Postgres (its stamps' Dagster and data). | `string` | `"shared"` | no |
| <a name="input_database_connection"></a> [database\_connection](#input\_database\_connection) | Where an own database lives, for the URL output (host, port, sslmode) | <pre>object({<br/>    host    = string<br/>    port    = optional(number, 5432)<br/>    sslmode = optional(string, "require")<br/>  })</pre> | `null` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix for AWS resource names (role, bucket, policy) | `string` | `""` | no |
| <a name="input_own_bucket_prevent_destroy"></a> [own\_bucket\_prevent\_destroy](#input\_own\_bucket\_prevent\_destroy) | Guard the tenant's own bucket against tofu destroy | `bool` | `true` | no |
| <a name="input_shared_bucket_arn"></a> [shared\_bucket\_arn](#input\_shared\_bucket\_arn) | ARN of the shared data bucket (bucket = "shared\_prefix") | `string` | `""` | no |
| <a name="input_shared_bucket_kms_key_arn"></a> [shared\_bucket\_kms\_key\_arn](#input\_shared\_bucket\_kms\_key\_arn) | KMS key of the shared bucket, if it is SSE-KMS encrypted | `string` | `""` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags for AWS resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_bucket_arn"></a> [bucket\_arn](#output\_bucket\_arn) | ARN of the bucket holding the tenant's data |
| <a name="output_database"></a> [database](#output\_database) | The tenant's own database (database = "own\_database"): name, username, password, url |
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | The tenant's IAM role |
| <a name="output_service_account_annotations"></a> [service\_account\_annotations](#output\_service\_account\_annotations) | Annotations for the tenant's ServiceAccounts (modules/tenancy tenant\_identity) |
| <a name="output_storage_url"></a> [storage\_url](#output\_storage\_url) | The tenant's slice of object storage (s3://bucket/[tenants/<tenant>/]) |
<!-- END_TF_DOCS -->
