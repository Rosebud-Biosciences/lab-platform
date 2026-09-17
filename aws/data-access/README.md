# data-access

Least-privilege data-plane access to **production** data stores for a preview
whose data is forked by a dataset tool rather than copied by Terraform — the
IAM half of "tether mode" in
[`docs/preview-environments.md`](../../docs/preview-environments.md). A fork is
a ref inside the same store (an Icechunk branch, a Lance branch, an Iceberg
table branch), so the preview's pods must be able to write into prod's bucket
and commit to prod's tables. This module is the smallest grant that allows it:

- **S3**: get / put / list on the listed prefixes, **never delete**. Branch
  writes only add objects; deletion is garbage collection, run by an operator,
  not a preview. A buggy preview can waste space, not lose data.
- **S3 Tables**: read and commit metadata on the listed tables. Iceberg
  branches live in one metadata file, so IAM cannot scope a grant to a branch;
  a preview that writes to `main` instead of its fork is a code bug the dataset
  tool's operation log and `verify` catch, not one IAM prevents.

```hcl
module "data_access" {
  source = "github.com/Rosebud-Biosciences/terraform-aws-lab-platform//aws/data-access?ref=main"

  name       = "pr123-data-access"
  bucket_arn = "arn:aws:s3:::prod-data"
  prefixes   = ["tether/greetings.icechunk/", "tether/greetings.lance/", "tether/greetings_log.delta/"]
  table_arns = ["arn:aws:s3tables:us-west-2:111122223333:bucket/lakehouse/table/0f3e..."]
}

# Attach to the preview's service accounts through the workloads module:
#   dagster_bucket_policies     = { data = module.data_access.policy_arn }
#   ray_storage_bucket_policies = { data = module.data_access.policy_arn }
```

The identity that *forks* the data in CI (runs `tether new`) needs the same
policy: forking creates refs and tags in the same stores.

The tofu-mode counterparts, [`preview-storage`](../preview-storage) and
[`iceberg-branches`](../iceberg-branches), give a preview its own empty bucket
and namespace instead and need none of this.

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
| [aws_iam_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy_document.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name"></a> [name](#input\_name) | IAM policy name (e.g. pr123-data-access); one policy per preview keeps attachments and teardown simple | `string` | n/a | yes |
| <a name="input_bucket_arn"></a> [bucket\_arn](#input\_bucket\_arn) | ARN of the production data bucket holding the store prefixes. Required when prefixes is non-empty. | `string` | `""` | no |
| <a name="input_prefixes"></a> [prefixes](#input\_prefixes) | Key prefixes inside bucket\_arn the pods may read and write (no delete), e.g.<br/>["tether/greetings.icechunk/", "tether/greetings.lance/"] -- the roots of the<br/>Icechunk / Lance / Delta stores whose branches a preview writes to. A prefix<br/>without a trailing slash is treated as one. | `list(string)` | `[]` | no |
| <a name="input_table_arns"></a> [table\_arns](#input\_table\_arns) | S3 Tables table ARNs (arn:aws:s3tables:...:bucket/<name>/table/<uuid>) the<br/>pods may read and commit metadata to -- required to write an Iceberg branch,<br/>and NOT scopable to that branch: IAM sees the table, not the ref. Grant it<br/>only to code you trust with the table's main branch. | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to the IAM policy | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_policy_arn"></a> [policy\_arn](#output\_policy\_arn) | ARN of the data-access policy; attach it to the preview's Dagster / Ray / webapp service accounts (the workloads module's *\_bucket\_policies maps) and to the CI identity that forks the data |
| <a name="output_policy_name"></a> [policy\_name](#output\_policy\_name) | Name of the data-access policy |
| <a name="output_prefixes"></a> [prefixes](#output\_prefixes) | The normalised (trailing-slash) prefixes the policy grants read/write on |
<!-- END_TF_DOCS -->
