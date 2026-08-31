# bootstrap

One-time, per-account setup that everything else depends on:

- an **S3 state bucket** (versioned, SSE-S3, public access blocked, old versions
  expired) and a **DynamoDB lock table** for the Terraform backend;
- the **GitHub Actions OIDC provider** (optional — reuse an existing one) plus
  two least-privilege roles:
  - a **CI deployer** role (ECR push + `eks:DescribeCluster`), and
  - a **preview deployer** role whose permissions are scoped to exactly what the
    [preview stack](../../examples/preview) touches: its own Terraform state
    (writes limited to `preview/*`), name-pattern-scoped IAM, the ephemeral
    bucket, and its KMS key (destructive KMS actions gated on the preview tag).

Apply this first with a **local backend**, then migrate state into the bucket it
creates.

```hcl
module "bootstrap" {
  source = "your-org/lab-platform/aws//modules/bootstrap"

  state_bucket_name = "my-org-terraform-state"
  github_owner      = "my-org"
  ci_repos          = ["app"]
  preview_repos     = ["app"]
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.40 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.62.0 |

## Resources

| Name | Type |
|------|------|
| [aws_dynamodb_table.locks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table) | resource |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.ci_deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.preview_deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.ci_deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.preview_deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_s3_bucket.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_acl.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_acl) | resource |
| [aws_s3_bucket_lifecycle_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.prevent_destroy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.ci_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.ci_deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.preview_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.preview_deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_state_bucket_name"></a> [state\_bucket\_name](#input\_state\_bucket\_name) | Name of the S3 bucket that stores Terraform state (globally unique) | `string` | n/a | yes |
| <a name="input_ci_deployer_role_name"></a> [ci\_deployer\_role\_name](#input\_ci\_deployer\_role\_name) | Name for the CI deployer IAM role | `string` | `"github-actions-ci-deployer"` | no |
| <a name="input_ci_ecr_repositories"></a> [ci\_ecr\_repositories](#input\_ci\_ecr\_repositories) | ECR repository names the CI deployer may push to | `list(string)` | `[]` | no |
| <a name="input_ci_repos"></a> [ci\_repos](#input\_ci\_repos) | GitHub repositories (name only) whose Actions may assume the CI deployer role | `list(string)` | `[]` | no |
| <a name="input_cluster_name_pattern"></a> [cluster\_name\_pattern](#input\_cluster\_name\_pattern) | EKS cluster name pattern the roles may eks:DescribeCluster (e.g. eks-*) | `string` | `"eks-*"` | no |
| <a name="input_create_github_oidc_provider"></a> [create\_github\_oidc\_provider](#input\_create\_github\_oidc\_provider) | Create the GitHub Actions OIDC identity provider. Set false to reuse an existing one via github\_oidc\_provider\_arn. | `bool` | `true` | no |
| <a name="input_enable_ci_deployer_role"></a> [enable\_ci\_deployer\_role](#input\_enable\_ci\_deployer\_role) | Create the GitHub Actions CI role (ECR push + eks:DescribeCluster) | `bool` | `true` | no |
| <a name="input_enable_preview_deployer_role"></a> [enable\_preview\_deployer\_role](#input\_enable\_preview\_deployer\_role) | Create the least-privilege GitHub Actions preview role that runs the preview Terraform stack | `bool` | `true` | no |
| <a name="input_github_oidc_provider_arn"></a> [github\_oidc\_provider\_arn](#input\_github\_oidc\_provider\_arn) | ARN of an existing GitHub Actions OIDC provider (used when create\_github\_oidc\_provider is false) | `string` | `""` | no |
| <a name="input_github_owner"></a> [github\_owner](#input\_github\_owner) | GitHub org/user that owns the CI and preview repositories | `string` | `""` | no |
| <a name="input_lock_table_deletion_protection"></a> [lock\_table\_deletion\_protection](#input\_lock\_table\_deletion\_protection) | Enable DynamoDB deletion protection on the lock table | `bool` | `true` | no |
| <a name="input_lock_table_name"></a> [lock\_table\_name](#input\_lock\_table\_name) | Name of the DynamoDB table used for state locking | `string` | `"terraform-locks"` | no |
| <a name="input_preview_deployer_role_name"></a> [preview\_deployer\_role\_name](#input\_preview\_deployer\_role\_name) | Name for the preview deployer IAM role | `string` | `"github-actions-preview-deployer"` | no |
| <a name="input_preview_ecr_repositories"></a> [preview\_ecr\_repositories](#input\_preview\_ecr\_repositories) | ECR repository names whose preview-tagged images the preview role may prune on teardown | `list(string)` | `[]` | no |
| <a name="input_preview_ephemeral_bucket_pattern"></a> [preview\_ephemeral\_bucket\_pattern](#input\_preview\_ephemeral\_bucket\_pattern) | S3 bucket name pattern for per-preview ephemeral buckets the role may create/destroy | `string` | `"preview-processeddata-*"` | no |
| <a name="input_preview_iceberg_namespace_pattern"></a> [preview\_iceberg\_namespace\_pattern](#input\_preview\_iceberg\_namespace\_pattern) | Namespace pattern (s3tables:namespace condition) scoping which tables the preview role may drop during teardown — must match your preview names (e.g. pr*) and never prod namespaces | `string` | `"pr*"` | no |
| <a name="input_preview_managed_policy_patterns"></a> [preview\_managed\_policy\_patterns](#input\_preview\_managed\_policy\_patterns) | IAM policy name patterns the preview stack creates and the role may manage (e.g. eks-*, bucket-preview-processeddata-*, iceberg-*) | `list(string)` | <pre>[<br/>  "eks-*",<br/>  "bucket-preview-processeddata-*",<br/>  "iceberg-*"<br/>]</pre> | no |
| <a name="input_preview_managed_role_pattern"></a> [preview\_managed\_role\_pattern](#input\_preview\_managed\_role\_pattern) | IAM role name pattern the preview stack (workloads module) creates and the role may manage | `string` | `"eks-*"` | no |
| <a name="input_preview_repos"></a> [preview\_repos](#input\_preview\_repos) | GitHub repositories (name only) whose Actions may assume the preview deployer role | `list(string)` | `[]` | no |
| <a name="input_preview_resource_tag_key"></a> [preview\_resource\_tag\_key](#input\_preview\_resource\_tag\_key) | Tag key gating the preview role's KMS key mutations (defence-in-depth) | `string` | `"Environment"` | no |
| <a name="input_preview_resource_tag_value"></a> [preview\_resource\_tag\_value](#input\_preview\_resource\_tag\_value) | Tag value gating the preview role's KMS key mutations | `string` | `"preview"` | no |
| <a name="input_preview_state_key_prefix"></a> [preview\_state\_key\_prefix](#input\_preview\_state\_key\_prefix) | State object key prefix the preview role may write (least-privilege state scoping) | `string` | `"preview/*"` | no |
| <a name="input_preview_table_bucket_arns"></a> [preview\_table\_bucket\_arns](#input\_preview\_table\_bucket\_arns) | S3 Tables table-bucket ARNs in which the preview role may create/destroy per-preview Iceberg namespaces (modules/iceberg-branches). Empty skips the s3tables statements. | `list(string)` | `[]` | no |
| <a name="input_state_bucket_prevent_destroy"></a> [state\_bucket\_prevent\_destroy](#input\_state\_bucket\_prevent\_destroy) | Attach a Deny s3:DeleteBucket policy to the state bucket so no principal can delete it without first removing the policy | `bool` | `true` | no |
| <a name="input_state_noncurrent_expiration_days"></a> [state\_noncurrent\_expiration\_days](#input\_state\_noncurrent\_expiration\_days) | Days after which noncurrent state versions are expired | `number` | `180` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to created resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_ci_deployer_role_arn"></a> [ci\_deployer\_role\_arn](#output\_ci\_deployer\_role\_arn) | ARN of the CI deployer role (null when disabled) |
| <a name="output_github_oidc_provider_arn"></a> [github\_oidc\_provider\_arn](#output\_github\_oidc\_provider\_arn) | ARN of the GitHub Actions OIDC provider (created or reused) |
| <a name="output_lock_table_name"></a> [lock\_table\_name](#output\_lock\_table\_name) | Name of the DynamoDB state lock table |
| <a name="output_preview_deployer_role_arn"></a> [preview\_deployer\_role\_arn](#output\_preview\_deployer\_role\_arn) | ARN of the preview deployer role (null when disabled) |
| <a name="output_state_bucket_arn"></a> [state\_bucket\_arn](#output\_state\_bucket\_arn) | ARN of the Terraform state bucket |
| <a name="output_state_bucket_name"></a> [state\_bucket\_name](#output\_state\_bucket\_name) | Name of the Terraform state bucket |
<!-- END_TF_DOCS -->
