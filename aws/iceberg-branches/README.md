# iceberg-branches

Ephemeral [Apache Iceberg](https://iceberg.apache.org) isolation for one
preview environment, built on
[Amazon S3 Tables](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables.html)
— the lakehouse side of "branch prod for testing, off prod." The preview gets
its own **namespace** in the shared table bucket plus IAM policies that keep its
pods inside that namespace (read/write) and optionally allow read-only access to
listed prod namespaces. On `tofu destroy` the namespace disappears with the rest
of the stamp; prod tables are untouched (and unwritable) the whole time.

```hcl
module "iceberg" {
  source = "github.com/Rosebud-Biosciences/lab-platform//aws/iceberg-branches?ref=v0.2.0"

  name_prefix      = "pr123"
  table_bucket_arn = "arn:aws:s3tables:us-west-2:111122223333:bucket/lakehouse"
  read_namespaces  = ["analytics"] # prod data the preview may read
}
```

## Namespace vs. true Iceberg branches

Two isolation levels compose here; only the first is Terraform's job:

1. **Namespace-per-preview (this module).** A disposable schema-space — the
   app's migrations create whatever tables the preview needs, isolated by IAM.
   This mirrors how the preview's Neon branches and ephemeral S3 bucket work.
2. **Table-level Iceberg branch refs** (copy-on-write *reads* of prod data).
   Branch refs are catalog **data-plane** operations created by an engine, not
   by IaC. If a preview needs to run against a prod table's data, have CI cut a
   branch ref after apply (readable via `read_namespaces` + the branch name):

```python
from pyiceberg.catalog import load_catalog

catalog = load_catalog(
    "s3tables",
    **{"type": "rest",
       "uri": "https://s3tables.us-west-2.amazonaws.com/iceberg",
       "warehouse": "arn:aws:s3tables:us-west-2:111122223333:bucket/lakehouse",
       "rest.sigv4-enabled": "true",
       "rest.signing-name": "s3tables",
       "rest.signing-region": "us-west-2"},
)
table = catalog.load_table("analytics.events")
table.manage_snapshots().create_branch(
    table.current_snapshot().snapshot_id, "pr123"
).commit()
```

## Teardown

`DeleteNamespace` requires the namespace to be empty, and the preview's
migrations create its tables outside tofu. So `tofu destroy` first drops every
table in the namespace (`drop_tables_on_destroy`, on by default), with the AWS
CLI (v2 with `s3tables`, as on GitHub's runners) and the destroying identity's
credentials -- the preview role, which `aws/bootstrap` lets drop tables in
preview namespaces (`preview_iceberg_namespace_pattern`) only.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.0 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_iam_policy.read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.readwrite](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_s3tables_namespace.preview](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3tables_namespace) | resource |
| [terraform_data.drop_tables](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_iam_policy_document.read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.readwrite](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Per-preview identity (e.g. pr123). Becomes the namespace name after sanitising to S3 Tables rules ([a-z0-9\_]). | `string` | n/a | yes |
| <a name="input_table_bucket_arn"></a> [table\_bucket\_arn](#input\_table\_bucket\_arn) | ARN of the existing shared S3 Tables (Iceberg) table bucket the preview namespace is created in | `string` | n/a | yes |
| <a name="input_drop_tables_on_destroy"></a> [drop\_tables\_on\_destroy](#input\_drop\_tables\_on\_destroy) | On destroy, drop the tables in the namespace first (the preview's migrations made them; a namespace is only deleted empty). Needs the AWS CLI v2 where tofu runs. Turning it off on a live namespace destroys the drop step, which drops the tables then. | `bool` | `true` | no |
| <a name="input_iam_path"></a> [iam\_path](#input\_iam\_path) | IAM path of the namespace's policies: aws/bootstrap's preview\_iam\_path, which the preview role is confined to | `string` | `"/preview/"` | no |
| <a name="input_read_namespaces"></a> [read\_namespaces](#input\_read\_namespaces) | Existing (prod) Iceberg namespaces in the same table bucket this preview may READ. Empty skips the read policy. | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to the IAM policies (S3 Tables namespaces do not support tags) | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_namespace"></a> [namespace](#output\_namespace) | The preview's Iceberg namespace in the shared table bucket |
| <a name="output_read_policy_arn"></a> [read\_policy\_arn](#output\_read\_policy\_arn) | IAM policy granting read-only access to the listed prod namespaces (null when read\_namespaces is empty) |
| <a name="output_readwrite_policy_arn"></a> [readwrite\_policy\_arn](#output\_readwrite\_policy\_arn) | IAM policy granting read/write scoped to the preview namespace |
| <a name="output_table_bucket_arn"></a> [table\_bucket\_arn](#output\_table\_bucket\_arn) | The shared table bucket the namespace lives in (passthrough) |
<!-- END_TF_DOCS -->
