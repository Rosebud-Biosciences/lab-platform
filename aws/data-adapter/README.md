# aws/data-adapter

The **data axis** of the AWS backend: per-service IAM roles that let
[`modules/workloads`](../../modules/workloads) pods reach AWS data stores
(S3 buckets, S3 Tables, ECR) and emits the module's `workload_identity`
contract input.

Data is harder to move than compute, so this module deliberately does not
care where the cluster runs. Its roles trust plain OIDC federation --
`sub = system:serviceaccount:<namespace>:<serviceaccount>`,
`aud = sts.amazonaws.com` -- against whatever `oidc_provider_arn` you give
it:

| Compute | `oidc_provider_arn` | `binding` | What workloads does |
| --- | --- | --- | --- |
| EKS (same cloud as the data) | `module.platform.oidc_provider_arn` | `webhook` (default) | stamps `eks.amazonaws.com/role-arn` on each ServiceAccount; EKS injects the token |
| kind, GKE, AKS, on-prem | [`aws/oidc-provider`](../oidc-provider) output | `projected` | mounts a projected token and sets `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE`; no webhook needed |

The trusted subjects are fixed by workloads' identity contract (see its README;
Argo's is `<prefix>argo/argo-workflow`);
this module derives the same names from the same `name_prefix` /
`webapp_app_name`, and both publish them as `service_accounts` so a test can
assert they agree.

```hcl
module "data" {
  source = "github.com/Rosebud-Biosciences/terraform-aws-lab-platform//aws/data-adapter?ref=v0.2.0"

  cluster_name      = module.platform.cluster_name
  oidc_provider_arn = module.platform.oidc_provider_arn
  region            = var.region

  enable_webapp  = true
  enable_ray     = true
  enable_dagster = true
  enable_mlflow  = true

  webapp_policy_arns         = { datasets = module.datasets.aws_iam_policies.get_arn }
  ray_policy_arns            = { datasets = module.datasets.aws_iam_policies.putget_arn }
  mlflow_artifact_bucket     = module.artifacts.aws_s3_bucket.bucket
  mlflow_artifact_bucket_arn = module.artifacts.aws_s3_bucket.arn
}

module "workloads" {
  source = "github.com/Rosebud-Biosciences/terraform-aws-lab-platform//modules/workloads?ref=v0.2.0"
  # ...
  workload_identity            = module.data.workload_identity
  workload_identity_secret_env = module.data.workload_identity_secret_env
  mlflow_artifact_root         = module.data.mlflow_artifact_root
}
```

Role names keep the pre-0.2 pattern (`<cluster>-<prefix>dagster-sa`, ...),
so an existing deployment can `tofu state mv` its IRSA roles here instead of
recreating them (see CHANGELOG 0.2.0).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.28 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.28 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_role"></a> [role](#module\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | ~> 6.8 |

## Resources

| Name | Type |
|------|------|
| [aws_iam_policy.ecr_read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.mlflow_s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Identifier of the cluster the pods run on, used only to name the IAM roles (<cluster\_name>-<name\_prefix><service>-sa). Any string; it need not be an EKS cluster. | `string` | n/a | yes |
| <a name="input_oidc_provider_arn"></a> [oidc\_provider\_arn](#input\_oidc\_provider\_arn) | IAM OIDC provider the roles trust: the EKS cluster's (module.platform.oidc\_provider\_arn) or a foreign cluster's registered through aws/oidc-provider. | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS region the data lives in, published to pods as AWS\_REGION | `string` | n/a | yes |
| <a name="input_binding"></a> [binding](#input\_binding) | How pods present the trusted token:<br/>  webhook    the cluster injects it (EKS IRSA via the pod identity<br/>             webhook): workloads gets an eks.amazonaws.com/role-arn SA<br/>             annotation and nothing in the pod spec.<br/>  projected  any cluster: workloads mounts a projected ServiceAccount<br/>             token with audience sts.amazonaws.com and the SDK reads<br/>             AWS\_ROLE\_ARN + AWS\_WEB\_IDENTITY\_TOKEN\_FILE from env. Use<br/>             with aws/oidc-provider for kind/GKE/AKS/on-prem compute. | `string` | `"webhook"` | no |
| <a name="input_dagster_policy_arns"></a> [dagster\_policy\_arns](#input\_dagster\_policy\_arns) | IAM policy ARNs attached to the Dagster role | `map(string)` | `{}` | no |
| <a name="input_enable_argo_workflows"></a> [enable\_argo\_workflows](#input\_enable\_argo\_workflows) | Create the Argo Workflows role (workflow pods in the environment's argo namespace) | `bool` | `false` | no |
| <a name="input_enable_dagster"></a> [enable\_dagster](#input\_enable\_dagster) | Create the Dagster role | `bool` | `false` | no |
| <a name="input_enable_ecr_pull"></a> [enable\_ecr\_pull](#input\_enable\_ecr\_pull) | Let the Ray, Argo and Dagster roles pull from this account's ECR repositories (needed when pods pull private images with their own credentials rather than the node's) | `bool` | `true` | no |
| <a name="input_enable_jupyterhub"></a> [enable\_jupyterhub](#input\_enable\_jupyterhub) | Create the JupyterHub single-user role | `bool` | `false` | no |
| <a name="input_enable_mlflow"></a> [enable\_mlflow](#input\_enable\_mlflow) | Create the MLflow role and its artifact-bucket policy | `bool` | `false` | no |
| <a name="input_enable_ray"></a> [enable\_ray](#input\_enable\_ray) | Create the Ray role | `bool` | `false` | no |
| <a name="input_enable_webapp"></a> [enable\_webapp](#input\_enable\_webapp) | Create the webapp role | `bool` | `false` | no |
| <a name="input_jupyterhub_policy_arns"></a> [jupyterhub\_policy\_arns](#input\_jupyterhub\_policy\_arns) | IAM policy ARNs attached to the JupyterHub single-user role, on top of jupyterhub\_s3\_read\_only | `map(string)` | `{}` | no |
| <a name="input_jupyterhub_s3_read_only"></a> [jupyterhub\_s3\_read\_only](#input\_jupyterhub\_s3\_read\_only) | Attach the AWS managed AmazonS3ReadOnlyAccess policy to the JupyterHub single-user role | `bool` | `true` | no |
| <a name="input_mlflow_artifact_bucket"></a> [mlflow\_artifact\_bucket](#input\_mlflow\_artifact\_bucket) | Name of the S3 bucket for MLflow artifacts (required when enable\_mlflow) | `string` | `""` | no |
| <a name="input_mlflow_artifact_bucket_arn"></a> [mlflow\_artifact\_bucket\_arn](#input\_mlflow\_artifact\_bucket\_arn) | ARN of the MLflow artifact bucket (the tracking-server policy is scoped to it) | `string` | `""` | no |
| <a name="input_mlflow_artifact_kms_key_arn"></a> [mlflow\_artifact\_kms\_key\_arn](#input\_mlflow\_artifact\_kms\_key\_arn) | KMS key encrypting the artifact bucket, if customer-managed (aws/s3-bucket's aws\_kms\_key\_arn); grants the MLflow role decrypt/encrypt on it. Empty for SSE-S3. | `string` | `""` | no |
| <a name="input_mlflow_artifact_prefix"></a> [mlflow\_artifact\_prefix](#input\_mlflow\_artifact\_prefix) | Key prefix inside the artifact bucket (no leading slash). Empty uses the bucket root. | `string` | `""` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Same name\_prefix as the modules/workloads instance these roles serve; the trusted <namespace>/<serviceaccount> subjects are derived from it. | `string` | `""` | no |
| <a name="input_projected_token_mount_path"></a> [projected\_token\_mount\_path](#input\_projected\_token\_mount\_path) | Where the projected token is mounted in projected binding (the file is <mount\_path>/token). | `string` | `"/var/run/secrets/workload-identity"` | no |
| <a name="input_ray_policy_arns"></a> [ray\_policy\_arns](#input\_ray\_policy\_arns) | IAM policy ARNs attached to the Ray and Argo roles (pipeline compute) | `map(string)` | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every IAM resource | `map(string)` | `{}` | no |
| <a name="input_webapp_app_name"></a> [webapp\_app\_name](#input\_webapp\_app\_name) | Same webapp\_app\_name as the workloads instance (its namespace and ServiceAccount carry this name). | `string` | `"webapp"` | no |
| <a name="input_webapp_policy_arns"></a> [webapp\_policy\_arns](#input\_webapp\_policy\_arns) | IAM policy ARNs attached to the webapp role (e.g. a bucket's get\_arn) | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_mlflow_artifact_root"></a> [mlflow\_artifact\_root](#output\_mlflow\_artifact\_root) | The mlflow\_artifact\_root input for modules/workloads (s3://bucket[/prefix]); empty when MLflow is off |
| <a name="output_role_arns"></a> [role\_arns](#output\_role\_arns) | Per-service IAM role ARNs |
| <a name="output_service_accounts"></a> [service\_accounts](#output\_service\_accounts) | The <namespace>/<serviceaccount> subjects each role trusts (must equal modules/workloads' service\_accounts output for the same inputs) |
| <a name="output_workload_identity"></a> [workload\_identity](#output\_workload\_identity) | The workload\_identity input for modules/workloads: one entry per enabled service, shaped for the chosen binding |
| <a name="output_workload_identity_secret_env"></a> [workload\_identity\_secret\_env](#output\_workload\_identity\_secret\_env) | The workload\_identity\_secret\_env input for modules/workloads. Roles need no static credentials, so this is empty; provided for symmetric wiring. |
<!-- END_TF_DOCS -->
