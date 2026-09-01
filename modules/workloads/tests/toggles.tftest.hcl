# Toggle-matrix plan assertions: every enable_* = false must yield no resources
# of that family (asserted via the namespace outputs, which are null when the
# service is off), and flipping a toggle on must create its namespace. Plan-only
# against mocked providers, so no cloud creds or real cluster are needed.

mock_provider "aws" {
  # IRSA roles consume a rendered IAM policy document; the default mock string is
  # not valid JSON and fails the provider's assume_role_policy validation.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  # A mocked policy arn is a random string; downstream attachments validate ARN
  # shape, so pin it to a well-formed ARN.
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock"
    }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}

variables {
  cluster_name      = "eks-test"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/TEST"
  region            = "us-west-2"
  vpc_name          = "vpc-test"
}

run "all_disabled_creates_nothing" {
  command = plan

  assert {
    condition     = output.webapp_namespace == null
    error_message = "webapp namespace should not exist when enable_webapp = false"
  }
  assert {
    condition     = output.dagster_namespace == null
    error_message = "dagster namespace should not exist when enable_dagster = false"
  }
  assert {
    condition     = output.ray_namespace == null
    error_message = "ray namespace should not exist when enable_ray = false"
  }
  assert {
    condition     = output.mlflow_namespace == null
    error_message = "mlflow namespace should not exist when enable_mlflow = false"
  }
  assert {
    condition     = output.jupyterhub_namespace == null
    error_message = "jupyterhub namespace should not exist when enable_jupyterhub = false"
  }
}

run "webapp_only" {
  command = plan

  variables {
    enable_webapp = true
    webapp_image  = "public.ecr.aws/nginx/nginx:latest"
  }

  assert {
    condition     = output.webapp_namespace != null
    error_message = "webapp namespace should exist when enable_webapp = true"
  }
  assert {
    condition     = output.dagster_namespace == null
    error_message = "enabling only the webapp must not create the dagster namespace"
  }
  assert {
    condition     = output.mlflow_namespace == null
    error_message = "enabling only the webapp must not create the mlflow namespace"
  }
}

run "mlflow_only" {
  command = plan

  variables {
    enable_mlflow          = true
    mlflow_artifact_bucket = "test-artifacts"
    mlflow_db_host         = "db.example.com"
    mlflow_db_name         = "mlflow"
    mlflow_db_user         = "mlflow"
    mlflow_db_password     = "test"
  }

  assert {
    condition     = output.mlflow_namespace != null
    error_message = "mlflow namespace should exist when enable_mlflow = true"
  }
  assert {
    condition     = output.webapp_namespace == null
    error_message = "enabling only mlflow must not create the webapp namespace"
  }
}

# JupyterHub renders the auth values template and creates the EFS filesystem.
# Two runs cover both guard variants of the filesystem (prevent_destroy
# true/false are separate resources) and two auth templates.
run "jupyterhub_protected_efs" {
  command = plan

  variables {
    enable_jupyterhub           = true
    vpc_id                      = "vpc-12345678"
    private_subnets             = ["subnet-aaa", "subnet-bbb"]
    private_subnets_cidr_blocks = ["100.64.0.0/18", "100.64.64.0/18"]
    vpc_secondary_cidr_blocks   = ["100.64.0.0/16"]
    jupyterhub_user_password    = "test-password"
    # jupyterhub_efs_prevent_destroy defaults to true (the guarded variant).
  }

  assert {
    condition     = output.jupyterhub_namespace != null
    error_message = "jupyterhub namespace should exist when enable_jupyterhub = true"
  }
}

run "jupyterhub_oidc_auth" {
  command = plan

  variables {
    enable_jupyterhub           = true
    vpc_id                      = "vpc-12345678"
    private_subnets             = ["subnet-aaa", "subnet-bbb"]
    private_subnets_cidr_blocks = ["100.64.0.0/18", "100.64.64.0/18"]
    vpc_secondary_cidr_blocks   = ["100.64.0.0/16"]

    jupyterhub_auth_mechanism      = "oidc"
    jupyterhub_oidc_client_id      = "test-client"
    jupyterhub_oidc_client_secret  = "test-secret"
    jupyterhub_oidc_callback_url   = "https://hub.example.ts.net/hub/oauth_callback"
    jupyterhub_oidc_authorize_url  = "https://accounts.google.com/o/oauth2/v2/auth"
    jupyterhub_oidc_token_url      = "https://oauth2.googleapis.com/token"
    jupyterhub_oidc_userdata_url   = "https://openidconnect.googleapis.com/v1/userinfo"
    jupyterhub_oidc_login_service  = "Google"
    jupyterhub_allowed_users       = ["ada@example.com"]
    jupyterhub_admin_users         = ["ada@example.com"]
    jupyterhub_efs_prevent_destroy = false
  }

  assert {
    condition     = output.jupyterhub_namespace != null
    error_message = "jupyterhub should render with oidc auth"
  }
}

run "jupyterhub_unguarded_efs_firstuse_auth" {
  command = plan

  variables {
    enable_jupyterhub           = true
    vpc_id                      = "vpc-12345678"
    private_subnets             = ["subnet-aaa", "subnet-bbb"]
    private_subnets_cidr_blocks = ["100.64.0.0/18", "100.64.64.0/18"]
    vpc_secondary_cidr_blocks   = ["100.64.0.0/16"]

    jupyterhub_efs_prevent_destroy = false
    jupyterhub_auth_mechanism      = "firstuse"
    jupyterhub_admin_users         = ["ada"]
    jupyterhub_allowed_users       = ["ada", "grace"]
    jupyterhub_extra_values        = ["singleuser:\n  startTimeout: 300\n"]
  }

  assert {
    condition     = output.jupyterhub_namespace != null
    error_message = "jupyterhub namespace should exist when enable_jupyterhub = true"
  }
}

# Dagster requires Ray (an explicit precondition, not a silent coupling): with
# both on, both namespaces come up.
run "dagster_requires_ray" {
  command = plan

  variables {
    enable_ray          = true
    enable_dagster      = true
    dagster_db_host     = "db.example.com"
    dagster_db_name     = "dagster"
    dagster_db_user     = "dagster"
    dagster_db_password = "test"
  }

  assert {
    condition     = output.ray_namespace != null
    error_message = "ray namespace should exist when enable_ray = true"
  }
  assert {
    condition     = output.dagster_namespace != null
    error_message = "dagster namespace should exist when enable_dagster = true (with ray)"
  }
}
