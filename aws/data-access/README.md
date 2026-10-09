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
  source = "github.com/Rosebud-Biosciences/lab-platform//aws/data-access?ref=v0.3.0"

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
| <a name="input_allow_delete"></a> [allow\_delete](#input\_allow\_delete) | Let the holder delete anything under the prefixes (the stores a PR created at their real locations). Only for a role that default-branch runs alone can assume (aws/bootstrap's teardown role); never for a role a pull\_request run or a pod holds. | `bool` | `false` | no |
| <a name="input_bucket_arn"></a> [bucket\_arn](#input\_bucket\_arn) | ARN of the production data bucket holding the store prefixes. Required when prefixes is non-empty. | `string` | `""` | no |
| <a name="input_iam_path"></a> [iam\_path](#input\_iam\_path) | IAM path of the policy; a preview's goes under aws/bootstrap's preview\_iam\_path | `string` | `"/"` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | The customer-managed KMS key encrypting bucket\_arn (aws/s3-bucket creates one), if any: objects in an SSE-KMS bucket cannot be read or written without kms:Decrypt / kms:GenerateDataKey on it. Empty for SSE-S3. | `string` | `""` | no |
| <a name="input_prefixes"></a> [prefixes](#input\_prefixes) | Key prefixes inside bucket\_arn the pods may read and write (no delete), e.g.<br/>["tether/greetings.icechunk/", "tether/greetings.lance/"] -- the roots of the<br/>Icechunk / Lance / Delta stores whose branches a preview writes to. A prefix<br/>without a trailing slash is treated as one. | `list(string)` | `[]` | no |
| <a name="input_protect_trunk"></a> [protect\_trunk](#input\_protect\_trunk) | Deny writes and deletes to each store's trunk and the pins on it, for a holder a pull request controls (a preview's pods, the CI role its workflow assumes): Lance's root versions, manifest and tags (stores named *.lance), Icechunk 1.x's main ref and tags (*.icechunk), Delta's log (*.delta). Its own working branches stay writable. The pins come from default-branch runs (data-pull) under a role without it. Iceberg and Icechunk 2.x are not covered: each keeps every ref in one object (a table's metadata file, the repository's repo) that creating a branch rewrites. | `bool` | `false` | no |
| <a name="input_table_arns"></a> [table\_arns](#input\_table\_arns) | S3 Tables table ARNs (arn:aws:s3tables:...:bucket/<name>/table/<uuid>) the<br/>pods may read and commit metadata to -- required to write an Iceberg branch,<br/>and NOT scopable to that branch: IAM sees the table, not the ref. Grant it<br/>only to code you trust with the table's main branch. | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to the IAM policy | `map(string)` | `{}` | no |
| <a name="input_working_branch_prefix"></a> [working\_branch\_prefix](#input\_working\_branch\_prefix) | Also let the holder delete the Lance working branches inside the prefixes<br/>whose name starts with this: each one's `_refs/branches/<name>.json` and<br/>`tree/<name>/`, nothing else. tether names working branches<br/>`tether.ws.<dataset>.<bookmark>`, so "tether.ws." reaches no main, pinned or<br/>other ref. For the CI role that retires previews; leave empty (no delete)<br/>for pods. | `string` | `""` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_policy_arn"></a> [policy\_arn](#output\_policy\_arn) | ARN of the data-access policy; attach it to the preview's Dagster / Ray / webapp service accounts (the workloads module's *\_bucket\_policies maps) and to the CI identity that forks the data |
| <a name="output_policy_name"></a> [policy\_name](#output\_policy\_name) | Name of the data-access policy |
| <a name="output_prefixes"></a> [prefixes](#output\_prefixes) | The normalised (trailing-slash) prefixes the policy grants read/write on |
<!-- END_TF_DOCS -->
