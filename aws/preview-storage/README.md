# preview-storage

A single ephemeral, KMS-encrypted S3 bucket for one preview environment, named
`<bucket_base_name>-<name_prefix>` so it never collides with prod. Wraps the
[s3-bucket](../s3-bucket) module with `force_destroy = true` and
`prevent_destroy = false`, so `tofu destroy` (or the nightly sweep) removes it
cleanly along with the rest of the preview. Exposes the bucket name/ARN and
read-only / read-write IAM policy ARNs for the workloads to consume.

```hcl
module "storage" {
  source = "github.com/Rosebud-Biosciences/terraform-aws-lab-platform//aws/preview-storage?ref=main"

  name_prefix = "pr123"
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

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_processeddata"></a> [processeddata](#module\_processeddata) | ../s3-bucket | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Unique per-preview prefix (e.g. the PR/preview name). Used to name the ephemeral bucket so it never collides with prod. | `string` | n/a | yes |
| <a name="input_bucket_base_name"></a> [bucket\_base\_name](#input\_bucket\_base\_name) | Base name for the ephemeral bucket; the final name is "<bucket\_base\_name>-<name\_prefix>" | `string` | `"preview-processeddata"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to the created resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_bucket_arn"></a> [bucket\_arn](#output\_bucket\_arn) | ARN of the ephemeral processed-data bucket |
| <a name="output_bucket_name"></a> [bucket\_name](#output\_bucket\_name) | Name of the ephemeral processed-data bucket |
| <a name="output_bucket_uri"></a> [bucket\_uri](#output\_bucket\_uri) | s3:// base URI for the ephemeral bucket (e.g. to set a per-preview output base) |
| <a name="output_get_policy_arn"></a> [get\_policy\_arn](#output\_get\_policy\_arn) | IAM policy ARN granting read-only on the ephemeral bucket (webapp/readers) |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | ARN of the bucket's KMS key |
| <a name="output_putget_policy_arn"></a> [putget\_policy\_arn](#output\_putget\_policy\_arn) | IAM policy ARN granting read/write on the ephemeral bucket (pipeline writers) |
<!-- END_TF_DOCS -->
