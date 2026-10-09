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
    bucket, and its KMS key (destructive KMS actions gated on the preview tag);
- optionally, the **human operator's** identity: an **MFA-gated admin role** that
  the person running `tofu apply` steps up into, plus a **guardrail** Deny policy
  protecting state history, the lock table, the audit trail, and the role
  itself from a leaked long-lived key. Off by default because it needs your
  principal ARNs. Read [docs/operator-access.md](../../docs/operator-access.md)
  before turning it on — it also explains how to actually run tofu through an
  MFA role, which is less obvious than it should be.

Apply this first with a **local backend**, then migrate state into the bucket it
creates.

**Repositories created, renamed or transferred since 2026-07-15** (and older
ones opted in) get Actions tokens with GitHub's immutable subject,
`repo:my-org@123/app@456:…`, which names the owner and repository by ID too.
The roles match only the name-only subject unless you give those IDs; the
symptom is `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
`gh api repos/my-org/app/actions/oidc/customization/sub` shows which format a
repository uses (`use_immutable_subject`) and its prefix.

```hcl
  github_owner_id       = "123"           # gh api repos/my-org/app --jq .owner.id
  github_repository_ids = { app = "456" } # gh api repos/my-org/app --jq .id
```

```hcl
module "bootstrap" {
  source = "github.com/Rosebud-Biosciences/lab-platform//aws/bootstrap?ref=v0.3.0"

  state_bucket_name = "my-org-terraform-state"
  github_owner      = "my-org"
  ci_repos          = ["app"]
  preview_repos     = ["app"]

  enable_operator_admin_role = true
  operator_principal_arns    = ["arn:aws:iam::123456789012:user/alice"]
}

# Attach the guardrail to the static identity as well, so a leaked key cannot
# undo the arrangement. From here on, changes to the guarded objects run as
# the role (or a GetSessionToken MFA session) -- see the doc.
resource "aws_iam_user_policy_attachment" "alice_guardrails" {
  user       = "alice"
  policy_arn = module.bootstrap.operator_guardrails_policy_arn
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
| [aws_dynamodb_table.locks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table) | resource |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_policy.operator_guardrails](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.preview_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.ci_deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.operator_admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.preview_deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.teardown](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.ci_deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.preview_deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.operator_admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.operator_guardrails](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_s3_bucket.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.prevent_destroy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.ci_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.ci_deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.operator_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.operator_guardrails](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.preview_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.preview_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.preview_deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.teardown_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
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
| <a name="input_enable_operator_admin_role"></a> [enable\_operator\_admin\_role](#input\_enable\_operator\_admin\_role) | Create the MFA-gated operator role and its guardrail policy. Requires operator\_principal\_arns. See docs/operator-access.md. | `bool` | `false` | no |
| <a name="input_enable_preview_deployer_role"></a> [enable\_preview\_deployer\_role](#input\_enable\_preview\_deployer\_role) | Create the least-privilege GitHub Actions preview role that runs the preview Terraform stack | `bool` | `true` | no |
| <a name="input_enable_teardown_role"></a> [enable\_teardown\_role](#input\_enable\_teardown\_role) | Create a role only teardown\_repos' runs on teardown\_ref may assume -- the nightly preview sweep, and the data jobs that write prod's trunk and pins (data-pull, tether-matrix) -- for what a pull\_request run must not hold: e.g. deleting the stores a PR created, or pinning prod's data once data-access's protect\_trunk fences the pull-request roles. It has no permissions of its own; the stack that owns the data attaches them. | `bool` | `false` | no |
| <a name="input_github_oidc_provider_arn"></a> [github\_oidc\_provider\_arn](#input\_github\_oidc\_provider\_arn) | ARN of an existing GitHub Actions OIDC provider (used when create\_github\_oidc\_provider is false) | `string` | `""` | no |
| <a name="input_github_owner"></a> [github\_owner](#input\_github\_owner) | GitHub org/user that owns the CI and preview repositories | `string` | `""` | no |
| <a name="input_github_owner_id"></a> [github\_owner\_id](#input\_github\_owner\_id) | Numeric ID of github\_owner (`gh api repos/<owner>/<repo> --jq .owner.id`); needed with github\_repository\_ids | `string` | `""` | no |
| <a name="input_github_repository_ids"></a> [github\_repository\_ids](#input\_github\_repository\_ids) | Numeric IDs, by name, of the ci\_repos / preview\_repos whose Actions tokens carry GitHub's immutable subject (repo:OWNER@OWNER\_ID/REPO@REPO\_ID:...): every repository created, renamed or transferred since 2026-07-15, and older ones opted in (`gh api repos/<owner>/<repo>/actions/oidc/customization/sub` shows which). A listed repository is trusted under that subject only; an unlisted one under the name-only subject, which matches no immutable-format token. | `map(string)` | `{}` | no |
| <a name="input_lock_table_deletion_protection"></a> [lock\_table\_deletion\_protection](#input\_lock\_table\_deletion\_protection) | Enable DynamoDB deletion protection on the lock table | `bool` | `true` | no |
| <a name="input_lock_table_name"></a> [lock\_table\_name](#input\_lock\_table\_name) | Name of the DynamoDB table used for state locking | `string` | `"terraform-locks"` | no |
| <a name="input_operator_admin_policy_arns"></a> [operator\_admin\_policy\_arns](#input\_operator\_admin\_policy\_arns) | Managed policy ARNs attached to the operator role. AdministratorAccess by default; scope down once you know what your stacks call. The guardrail Deny policy is attached regardless. | `list(string)` | <pre>[<br/>  "arn:aws:iam::aws:policy/AdministratorAccess"<br/>]</pre> | no |
| <a name="input_operator_admin_role_name"></a> [operator\_admin\_role\_name](#input\_operator\_admin\_role\_name) | Name for the operator admin IAM role; the guardrail policy is named <role>-guardrails | `string` | `"operator-admin"` | no |
| <a name="input_operator_admin_session_duration"></a> [operator\_admin\_session\_duration](#input\_operator\_admin\_session\_duration) | Maximum operator role session length in seconds (3600-43200). Long enough for a full cluster apply, because credentials expiring mid-apply is how state drifts from reality. | `number` | `14400` | no |
| <a name="input_operator_mfa_max_age"></a> [operator\_mfa\_max\_age](#input\_operator\_mfa\_max\_age) | Seconds since the MFA challenge within which the operator role may be assumed. Bounds how long an MFA'd session stays useful for stepping up. | `number` | `3600` | no |
| <a name="input_operator_principal_arns"></a> [operator\_principal\_arns](#input\_operator\_principal\_arns) | IAM user/role ARNs allowed to assume the operator role (with a recent MFA challenge). The module does not manage these identities. | `list(string)` | `[]` | no |
| <a name="input_preview_attachable_policy_arns"></a> [preview\_attachable\_policy\_arns](#input\_preview\_attachable\_policy\_arns) | Policies outside preview\_iam\_path that the preview role may also attach to preview roles (e.g. a shared read-only policy on prod data). The permissions boundary still caps what they grant. | `list(string)` | `[]` | no |
| <a name="input_preview_boundary_access"></a> [preview\_boundary\_access](#input\_preview\_boundary\_access) | What preview roles may reach beyond what a preview owns. The boundary already allows each preview its ephemeral bucket (preview\_ephemeral\_bucket\_pattern, in this account) and the KMS keys tagged preview\_resource\_tag\_key = preview\_resource\_tag\_value, reads in preview\_table\_bucket\_arns and writes in its own Iceberg namespaces (preview\_iceberg\_namespace\_pattern), and image pulls from preview\_ecr\_repositories (all of this account's repositories when that is empty). Everything else is listed here as ARNs -- S3 as bucket or bucket/prefix*, S3 Tables as bucket/table/<id>:<br/>read: stores previews read but never change (writable and deletable ARNs are readable too);<br/>write: where they may write -- tether mode's data prefixes and the prod tables they commit to (aws/data-access's prefixes and table\_arns);<br/>delete: what they may delete -- tether mode's Lance working branches only (bucket/prefix*/\_refs/branches/tether.ws.* and bucket/prefix*/tree/tether.ws.*);<br/>kms\_key\_arns: the keys of those stores;<br/>extra\_action\_resources: what preview\_boundary\_extra\_actions apply to.<br/>Breaking from 0.2: this replaces preview\_boundary\_resources (["*"]), and a store not listed is out of every preview's reach. | <pre>object({<br/>    read                   = optional(list(string), [])<br/>    write                  = optional(list(string), [])<br/>    delete                 = optional(list(string), [])<br/>    kms_key_arns           = optional(list(string), [])<br/>    extra_action_resources = optional(list(string), ["*"])<br/>  })</pre> | `{}` | no |
| <a name="input_preview_boundary_extra_actions"></a> [preview\_boundary\_extra\_actions](#input\_preview\_boundary\_extra\_actions) | Actions beyond object-level S3, the S3 Tables data plane, KMS data keys and ECR pulls that preview workloads may be granted (e.g. "secretsmanager:GetSecretValue"), on preview\_boundary\_access.extra\_action\_resources. Never IAM or STS. | `list(string)` | `[]` | no |
| <a name="input_preview_boundary_federated_providers"></a> [preview\_boundary\_federated\_providers](#input\_preview\_boundary\_federated\_providers) | IAM OIDC provider ARNs (your clusters' IRSA issuers) every preview role session must come through; any other session -- a role a PR made assumable from elsewhere -- is denied everything. Wildcards match: "arn:aws:iam::<account>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/*" admits every EKS cluster's issuer registered in this account and survives a cluster rebuild, where a cluster's own ARN changes with it. Only the account's admins can register issuers (the preview role cannot). Empty (default) skips the check. | `list(string)` | `[]` | no |
| <a name="input_preview_deployer_role_name"></a> [preview\_deployer\_role\_name](#input\_preview\_deployer\_role\_name) | Name for the preview deployer IAM role | `string` | `"github-actions-preview-deployer"` | no |
| <a name="input_preview_ecr_repositories"></a> [preview\_ecr\_repositories](#input\_preview\_ecr\_repositories) | ECR repository names whose preview-tagged images the preview role may prune on teardown, and the only ones preview workloads may pull from (empty: every repository in this account) | `list(string)` | `[]` | no |
| <a name="input_preview_ephemeral_bucket_pattern"></a> [preview\_ephemeral\_bucket\_pattern](#input\_preview\_ephemeral\_bucket\_pattern) | S3 bucket name pattern for per-preview ephemeral buckets the role may create/destroy | `string` | `"preview-processeddata-*"` | no |
| <a name="input_preview_iam_path"></a> [preview\_iam\_path](#input\_preview\_iam\_path) | IAM path of every role and policy the preview stack creates (the modules' iam\_path). The preview role may create and change roles and policies under it only -- nothing of prod's, which must never use it -- and only roles carrying the preview permissions boundary. | `string` | `"/preview/"` | no |
| <a name="input_preview_iceberg_namespace_pattern"></a> [preview\_iceberg\_namespace\_pattern](#input\_preview\_iceberg\_namespace\_pattern) | Namespace pattern (s3tables:namespace condition) scoping which tables the preview role may drop during teardown — must match your preview names (e.g. pr*) and never prod namespaces | `string` | `"pr*"` | no |
| <a name="input_preview_repos"></a> [preview\_repos](#input\_preview\_repos) | GitHub repositories (name only) whose Actions may assume the preview deployer role | `list(string)` | `[]` | no |
| <a name="input_preview_resource_tag_key"></a> [preview\_resource\_tag\_key](#input\_preview\_resource\_tag\_key) | Tag key gating the preview role's KMS key mutations and which keys preview workloads may use (aws/s3-bucket tags a preview's key with the preview stack's tags) | `string` | `"Environment"` | no |
| <a name="input_preview_resource_tag_value"></a> [preview\_resource\_tag\_value](#input\_preview\_resource\_tag\_value) | Tag value gating the preview role's KMS key mutations and which keys preview workloads may use | `string` | `"preview"` | no |
| <a name="input_preview_state_key_prefix"></a> [preview\_state\_key\_prefix](#input\_preview\_state\_key\_prefix) | State object key prefix the preview role may read and write (its workspaces' state); it reads no other state but preview\_state\_read\_keys | `string` | `"preview/*"` | no |
| <a name="input_preview_state_read_keys"></a> [preview\_state\_read\_keys](#input\_preview\_state\_read\_keys) | State objects outside preview\_state\_key\_prefix the preview role may read: the preview stack's own backend `key` when it lies outside the prefix (e.g. ["template-app/terraform.tfstate"]) -- its default-workspace object, which `tofu init` reads before a preview workspace is selected, and which previews never write. Never another stack's key: state holds that stack's secrets. | `list(string)` | `[]` | no |
| <a name="input_preview_table_bucket_arns"></a> [preview\_table\_bucket\_arns](#input\_preview\_table\_bucket\_arns) | S3 Tables table-bucket ARNs in which the preview role may create/destroy per-preview Iceberg namespaces (aws/iceberg-branches), and preview workloads may read every table and write those in preview\_iceberg\_namespace\_pattern. Empty skips the s3tables statements. | `list(string)` | `[]` | no |
| <a name="input_state_bucket_prevent_destroy"></a> [state\_bucket\_prevent\_destroy](#input\_state\_bucket\_prevent\_destroy) | Attach a Deny s3:DeleteBucket policy to the state bucket so no principal can delete it without first removing the policy | `bool` | `true` | no |
| <a name="input_state_noncurrent_expiration_days"></a> [state\_noncurrent\_expiration\_days](#input\_state\_noncurrent\_expiration\_days) | Days after which noncurrent state versions are expired | `number` | `180` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to created resources | `map(string)` | `{}` | no |
| <a name="input_teardown_ref"></a> [teardown\_ref](#input\_teardown\_ref) | The one git ref whose runs may assume the teardown role (scheduled and dispatched runs of the default branch) | `string` | `"refs/heads/main"` | no |
| <a name="input_teardown_repos"></a> [teardown\_repos](#input\_teardown\_repos) | GitHub repositories (name only) whose runs on teardown\_ref may assume the teardown role | `list(string)` | `[]` | no |
| <a name="input_teardown_role_name"></a> [teardown\_role\_name](#input\_teardown\_role\_name) | Name for the teardown IAM role | `string` | `"github-actions-teardown"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_ci_deployer_role_arn"></a> [ci\_deployer\_role\_arn](#output\_ci\_deployer\_role\_arn) | ARN of the CI deployer role (null when disabled) |
| <a name="output_github_oidc_provider_arn"></a> [github\_oidc\_provider\_arn](#output\_github\_oidc\_provider\_arn) | ARN of the GitHub Actions OIDC provider (created or reused) |
| <a name="output_lock_table_name"></a> [lock\_table\_name](#output\_lock\_table\_name) | Name of the DynamoDB state lock table |
| <a name="output_operator_admin_role_arn"></a> [operator\_admin\_role\_arn](#output\_operator\_admin\_role\_arn) | ARN of the MFA-gated operator role (null when disabled). Feed it to eks-platform's access\_entries so the role can reach the cluster. |
| <a name="output_operator_guardrails_policy_arn"></a> [operator\_guardrails\_policy\_arn](#output\_operator\_guardrails\_policy\_arn) | ARN of the operator guardrail Deny policy (null when disabled). Already attached to the role; attach it to the static identities in operator\_principal\_arns too. |
| <a name="output_preview_deployer_role_arn"></a> [preview\_deployer\_role\_arn](#output\_preview\_deployer\_role\_arn) | ARN of the preview deployer role (null when disabled) |
| <a name="output_preview_iam_path"></a> [preview\_iam\_path](#output\_preview\_iam\_path) | IAM path the preview stack must create its roles and policies under (the modules' iam\_path) |
| <a name="output_preview_permissions_boundary_arn"></a> [preview\_permissions\_boundary\_arn](#output\_preview\_permissions\_boundary\_arn) | Permissions boundary every preview role must carry (aws/data-adapter's permissions\_boundary\_arn); null when the preview role is disabled |
| <a name="output_state_bucket_arn"></a> [state\_bucket\_arn](#output\_state\_bucket\_arn) | ARN of the Terraform state bucket |
| <a name="output_state_bucket_name"></a> [state\_bucket\_name](#output\_state\_bucket\_name) | Name of the Terraform state bucket |
| <a name="output_teardown_role_arn"></a> [teardown\_role\_arn](#output\_teardown\_role\_arn) | ARN of the default-branch-only teardown role (null when disabled) |
<!-- END_TF_DOCS -->
