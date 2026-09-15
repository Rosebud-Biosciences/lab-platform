# s3-bucket

A hardened S3 bucket with sensible, safe defaults: KMS encryption (generates a
dedicated key by default, or bring your own), versioning, all public access
blocked, and a set of ready-made IAM policies (`get`/`put`/`putget`) you can
attach to service accounts or users. Optional lifecycle tiering
(Glacier/Deep Archive/Intelligent-Tiering) and an optional `prevent_destroy`
policy that denies both bucket and key deletion.

```hcl
module "artifacts" {
  source = "github.com/Rosebud-Biosciences/terraform-aws-lab-platform//modules/s3-bucket?ref=main"

  name = "my-org-mlflow-artifacts"
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.40 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.40 |

## Resources

| Name | Type |
|------|------|
| [aws_iam_policy.get](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.put](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.putget](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_user_policy_attachment.get](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user_policy_attachment) | resource |
| [aws_iam_user_policy_attachment.put](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user_policy_attachment) | resource |
| [aws_iam_user_policy_attachment.putget](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user_policy_attachment) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_intelligent_tiering_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_intelligent_tiering_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.prevent_destroy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.putget](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name"></a> [name](#input\_name) | The name of the bucket (must be globally unique) | `string` | n/a | yes |
| <a name="input_abort_incomplete_multipart_upload_days"></a> [abort\_incomplete\_multipart\_upload\_days](#input\_abort\_incomplete\_multipart\_upload\_days) | Days after which incomplete multipart uploads are aborted | `number` | `7` | no |
| <a name="input_archive_tag_transition"></a> [archive\_tag\_transition](#input\_archive\_tag\_transition) | Transition objects tagged archived=true to DEEP\_ARCHIVE (explicit per-project archival) | `bool` | `false` | no |
| <a name="input_aws_kms_key_arn"></a> [aws\_kms\_key\_arn](#input\_aws\_kms\_key\_arn) | Existing KMS key ARN to encrypt with. Empty string generates a dedicated key for this bucket. | `string` | `""` | no |
| <a name="input_deep_archive_transition_days"></a> [deep\_archive\_transition\_days](#input\_deep\_archive\_transition\_days) | Days after creation to transition current objects to DEEP\_ARCHIVE (0 = disabled) | `number` | `0` | no |
| <a name="input_deployment_user_arn"></a> [deployment\_user\_arn](#input\_deployment\_user\_arn) | Principal ARN granted full control over a generated KMS key (only used when aws\_kms\_key\_arn is empty). Defaults to the account root. | `string` | `""` | no |
| <a name="input_force_destroy"></a> [force\_destroy](#input\_force\_destroy) | Allow `tofu destroy` to delete the bucket even when it still contains objects (for ephemeral/preview buckets) | `bool` | `false` | no |
| <a name="input_get_users"></a> [get\_users](#input\_get\_users) | Existing IAM user names to attach the get policy to | `list(string)` | `[]` | no |
| <a name="input_intelligent_tiering_deep_archive_days"></a> [intelligent\_tiering\_deep\_archive\_days](#input\_intelligent\_tiering\_deep\_archive\_days) | Days of no access before Intelligent-Tiering moves objects to the Deep Archive Access tier (0 = disabled, min 180) | `number` | `0` | no |
| <a name="input_intelligent_tiering_prefix"></a> [intelligent\_tiering\_prefix](#input\_intelligent\_tiering\_prefix) | Prefix filter for the Intelligent-Tiering deep-archive configuration (empty = whole bucket) | `string` | `""` | no |
| <a name="input_noncurrent_transition_days"></a> [noncurrent\_transition\_days](#input\_noncurrent\_transition\_days) | Days after becoming noncurrent to transition old versions to a cheaper storage class (0 = disabled) | `number` | `0` | no |
| <a name="input_noncurrent_transition_storage_class"></a> [noncurrent\_transition\_storage\_class](#input\_noncurrent\_transition\_storage\_class) | Storage class for transitioned noncurrent object versions | `string` | `"GLACIER_IR"` | no |
| <a name="input_prevent_destroy"></a> [prevent\_destroy](#input\_prevent\_destroy) | Attach a bucket policy that denies s3:DeleteBucket and a KMS policy that denies key deletion | `bool` | `true` | no |
| <a name="input_put_users"></a> [put\_users](#input\_put\_users) | Existing IAM user names to attach the put policy to | `list(string)` | `[]` | no |
| <a name="input_putget_users"></a> [putget\_users](#input\_putget\_users) | Existing IAM user names to attach the putget policy to | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_transition_days"></a> [transition\_days](#input\_transition\_days) | Days after creation to transition current objects to a cheaper storage class (0 = disabled) | `number` | `0` | no |
| <a name="input_transition_storage_class"></a> [transition\_storage\_class](#input\_transition\_storage\_class) | Storage class for transitioned current objects | `string` | `"GLACIER_IR"` | no |
| <a name="input_versioning"></a> [versioning](#input\_versioning) | Whether to enable object versioning | `bool` | `true` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_aws_iam_policies"></a> [aws\_iam\_policies](#output\_aws\_iam\_policies) | The ARNs of the generated S3 bucket access policies |
| <a name="output_aws_kms_key_arn"></a> [aws\_kms\_key\_arn](#output\_aws\_kms\_key\_arn) | The ARN of the KMS key encrypting the bucket |
| <a name="output_aws_s3_bucket"></a> [aws\_s3\_bucket](#output\_aws\_s3\_bucket) | The generated bucket (name + ARN) |
<!-- END_TF_DOCS -->
