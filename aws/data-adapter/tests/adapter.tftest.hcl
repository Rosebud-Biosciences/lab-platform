# The adapter's job is to emit modules/workloads' identity contract with the
# right shape for each binding, trusting exactly the subjects workloads runs
# pods as. Plan-only against a mocked AWS provider.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }
}

variables {
  cluster_name      = "eks-test"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/TEST"
  region            = "us-west-2"
}

run "nothing_enabled_emits_nothing" {
  command = plan

  assert {
    condition     = length(output.workload_identity) == 0 && length(output.role_arns) == 0
    error_message = "no roles or identities without enabled services"
  }
  assert {
    condition     = output.mlflow_artifact_root == ""
    error_message = "no artifact root when MLflow is off"
  }
}

run "webhook_binding_annotates_service_accounts" {
  command = plan

  variables {
    enable_webapp      = true
    enable_ray         = true
    enable_dagster     = true
    webapp_policy_arns = { data = "arn:aws:iam::123456789012:policy/data-get" }
  }

  assert {
    condition     = toset(keys(output.workload_identity)) == toset(["webapp", "ray", "dagster"])
    error_message = "one identity per enabled service, none for the rest"
  }
  assert {
    condition     = contains(keys(output.workload_identity.webapp.service_account_annotations), "eks.amazonaws.com/role-arn")
    error_message = "webhook binding must emit the IRSA annotation"
  }
  assert {
    condition     = output.workload_identity.webapp.projected_token == null && !contains(keys(output.workload_identity.webapp.env), "AWS_ROLE_ARN")
    error_message = "webhook binding must not mount a token or set AWS_ROLE_ARN"
  }
  assert {
    condition     = output.workload_identity.webapp.env.AWS_REGION == "us-west-2"
    error_message = "AWS_REGION must be published"
  }
  assert {
    condition     = output.service_accounts.ray.namespace == "ray" && output.service_accounts.ray.name == "ray-s3-sa"
    error_message = "the ray role must trust ray/ray-s3-sa (the workloads contract)"
  }
  assert {
    condition     = length(aws_iam_policy.ecr_read) == 1
    error_message = "ECR pull policy exists when pipeline services are on"
  }
}

run "projected_binding_mounts_a_token" {
  command = plan

  variables {
    enable_webapp   = true
    enable_mlflow   = true
    binding         = "projected"
    name_prefix     = "pr42-"
    webapp_app_name = "app"

    mlflow_artifact_bucket     = "lab-mlflow"
    mlflow_artifact_bucket_arn = "arn:aws:s3:::lab-mlflow"
    mlflow_artifact_prefix     = "pr42"
  }

  assert {
    condition     = output.workload_identity.webapp.projected_token.audience == "sts.amazonaws.com"
    error_message = "projected binding must request an sts.amazonaws.com token"
  }
  assert {
    condition     = output.workload_identity.webapp.env.AWS_WEB_IDENTITY_TOKEN_FILE == "/var/run/secrets/workload-identity/token" && contains(keys(output.workload_identity.webapp.env), "AWS_ROLE_ARN")
    error_message = "projected binding must point the SDK at the mounted token and the role"
  }
  assert {
    condition     = length(output.workload_identity.webapp.service_account_annotations) == 0
    error_message = "projected binding must not annotate the ServiceAccount"
  }
  assert {
    condition     = output.service_accounts.webapp.namespace == "pr42-app" && output.service_accounts.webapp.name == "app"
    error_message = "name_prefix and webapp_app_name must shape the trusted subject exactly as workloads names it"
  }
  assert {
    condition     = output.mlflow_artifact_root == "s3://lab-mlflow/pr42"
    error_message = "mlflow_artifact_root must combine bucket and prefix"
  }
  assert {
    condition     = length(aws_iam_policy.ecr_read) == 0
    error_message = "no ECR policy without pipeline services"
  }
}

run "mlflow_requires_bucket" {
  command = plan

  variables {
    enable_mlflow = true
  }

  expect_failures = [var.mlflow_artifact_bucket, var.mlflow_artifact_bucket_arn]
}

run "binding_is_validated" {
  command = plan

  variables {
    binding = "sidecar"
  }

  expect_failures = [var.binding]
}

# A preview's IAM lives under aws/bootstrap's preview path with its boundary,
# and its MLflow reaches only its own artifact prefix of a shared bucket.
run "preview_iam_is_pathed_and_scoped" {
  command = plan

  variables {
    name_prefix                = "pr7-"
    iam_path                   = "/preview/"
    permissions_boundary_arn   = "arn:aws:iam::123456789012:policy/preview-boundary"
    enable_ray                 = true
    enable_mlflow              = true
    enable_jupyterhub          = true
    mlflow_artifact_bucket     = "lab-data"
    mlflow_artifact_bucket_arn = "arn:aws:s3:::lab-data"
    mlflow_artifact_prefix     = "tether/mlflow/pr7"
  }

  assert {
    condition     = aws_iam_policy.ecr_read[0].path == "/preview/" && aws_iam_policy.mlflow_s3[0].path == "/preview/"
    error_message = "the preview's policies are created under the preview path"
  }
  assert {
    condition     = local.mlflow_artifact_objects == "arn:aws:s3:::lab-data/tether/mlflow/pr7/*"
    error_message = "MLflow reads, writes and deletes its own prefix only, not the bucket's prod data"
  }
  assert {
    condition     = length(local.policies["jupyterhub"]) == 0
    error_message = "notebooks get no account-wide S3 read by default"
  }
}
