# The compute adapter emits three of modules/workloads' contract inputs
# (jupyterhub_shared_storage, public-ingress annotations, scheduling) from
# EKS-bound resources. Plan-only against mocked providers.

mock_provider "aws" {
  mock_resource "aws_efs_file_system" {
    defaults = {
      id       = "fs-0123456789abcdef0"
      dns_name = "fs-0123456789abcdef0.efs.us-west-2.amazonaws.com"
    }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:us-west-2:123456789012:regional/webacl/webapp-public/mock"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-west-2:123456789012:log-group:aws-waf-logs-webapp-public"
    }
  }
}
mock_provider "helm" {}

variables {
  cluster_name = "eks-test"
}

run "nothing_enabled" {
  command = plan

  assert {
    condition     = output.jupyterhub_shared_storage.nfs_server == null && output.jupyterhub_efs_id == null
    error_message = "no EFS without JupyterHub"
  }
  assert {
    condition     = length(output.webapp_public_ingress_annotations) == 0 && output.webapp_waf_acl_arn == null
    error_message = "no public annotations without the public ingress"
  }
  assert {
    condition     = length(output.scheduling) == 0 && length(helm_release.karpenter_node_pools) == 0
    error_message = "no NodePools or scheduling without pools"
  }
  assert {
    condition     = output.webapp_public_ingress_class_name == "alb"
    error_message = "the class is always the ALB controller's"
  }
}

run "jupyterhub_efs_in_pod_cidr_subnets" {
  command = plan

  variables {
    enable_jupyterhub              = true
    jupyterhub_efs_prevent_destroy = false
    vpc_id                         = "vpc-12345678"
    private_subnets                = ["subnet-node-a", "subnet-pod-a", "subnet-pod-b"]
    private_subnets_cidr_blocks    = ["10.0.1.0/24", "100.64.0.0/18", "100.64.64.0/18"]
    vpc_secondary_cidr_blocks      = ["100.64.0.0/16"]
  }

  assert {
    condition     = length(aws_efs_mount_target.jupyterhub) == 2
    error_message = "mount targets go only in the 100.x pod-CIDR subnets"
  }
  assert {
    condition     = output.jupyterhub_shared_storage.nfs_server == "fs-0123456789abcdef0.efs.us-west-2.amazonaws.com" && output.jupyterhub_shared_storage.storage_class_name == null
    error_message = "the storage contract must carry the EFS DNS name in NFS mode"
  }
}

run "public_ingress_with_waf_and_stickiness" {
  command = plan

  variables {
    enable_webapp_public_ingress    = true
    webapp_acm_certificate_arn      = "arn:aws:acm:us-west-2:123456789012:certificate/abc"
    webapp_health_check_path        = "/healthz"
    webapp_session_affinity_seconds = 3600
    enable_webapp_waf               = true
    name_prefix                     = "pr9-"
  }

  assert {
    condition     = output.webapp_public_ingress_annotations["alb.ingress.kubernetes.io/certificate-arn"] == "arn:aws:acm:us-west-2:123456789012:certificate/abc"
    error_message = "ACM certificate must be in the annotation set"
  }
  assert {
    condition     = output.webapp_public_ingress_annotations["alb.ingress.kubernetes.io/healthcheck-path"] == "/healthz"
    error_message = "health check path must be forwarded"
  }
  assert {
    condition     = strcontains(output.webapp_public_ingress_annotations["alb.ingress.kubernetes.io/target-group-attributes"], "duration_seconds=3600")
    error_message = "stickiness must follow webapp_session_affinity_seconds"
  }
  assert {
    condition     = contains(keys(output.webapp_public_ingress_annotations), "alb.ingress.kubernetes.io/wafv2-acl-arn") && aws_wafv2_web_acl.webapp[0].name == "pr9-webapp-public"
    error_message = "WAF ACL must be created, prefixed, and referenced"
  }
}

run "public_ingress_requires_certificate" {
  command = plan

  variables {
    enable_webapp_public_ingress = true
  }

  expect_failures = [var.webapp_acm_certificate_arn]
}

run "node_pools_become_scheduling" {
  command = plan

  variables {
    name_prefix                  = "pr9-"
    vpc_name                     = "vpc-test"
    karpenter_node_iam_role_name = "eks-test-karpenter-node"
    karpenter_node_pools = {
      default = {}
      gpu = {
        instance_families = ["g5"]
        labels            = { "nvidia.com/gpu" = "true" }
        taints            = [{ key = "nvidia.com/gpu", value = "true", effect = "NoSchedule" }]
      }
    }
    node_pool_roles = {
      default = ["webapp", "dagster"]
      gpu     = ["ray_worker"]
    }
  }

  assert {
    condition     = length(helm_release.karpenter_node_pools) == 2 && output.node_pool_names.gpu == "pr9-gpu"
    error_message = "one release per pool, names prefixed"
  }
  assert {
    condition     = output.scheduling.webapp.node_selector["karpenter.sh/nodepool"] == "pr9-default" && length(output.scheduling.webapp.tolerations) == 0
    error_message = "roles on an untainted pool get a selector and no tolerations"
  }
  assert {
    condition     = output.scheduling.ray_worker.tolerations[0].key == "nvidia.com/gpu" && output.scheduling.ray_worker.tolerations[0].operator == "Equal" && output.scheduling.ray_worker.tolerations[0].value == "true"
    error_message = "roles on a tainted pool tolerate its taints"
  }
  assert {
    condition     = !contains(keys(output.scheduling), "mlflow")
    error_message = "unlisted roles are absent so they schedule anywhere"
  }
  assert {
    condition     = helm_release.karpenter_node_pools["default"].namespace == "karpenter"
    error_message = "by default the releases live in Karpenter's namespace"
  }
}

run "preview_node_pools_stay_in_its_namespace" {
  command = plan

  variables {
    name_prefix                  = "preview-pr9-"
    vpc_name                     = "vpc-test"
    karpenter_node_iam_role_name = "eks-test-karpenter-node"
    karpenter_node_pools         = { default = {} }
    node_pools_namespace         = "preview-pr9-webapp"
  }

  assert {
    condition     = helm_release.karpenter_node_pools["default"].namespace == "preview-pr9-webapp" && output.node_pool_names.default == "preview-pr9-default"
    error_message = "a preview's NodePool release lives in its own namespace, and the pool carries its prefix"
  }
}

run "node_pools_off_without_node_role" {
  command = plan

  variables {
    karpenter_node_pools = { default = {} }
    node_pool_roles      = { default = ["webapp"] }
  }

  assert {
    condition     = length(helm_release.karpenter_node_pools) == 0
    error_message = "no karpenter_node_iam_role_name means no pools are created"
  }
}

run "node_pool_roles_must_reference_pools" {
  command = plan

  variables {
    node_pool_roles = { nope = ["webapp"] }
  }

  expect_failures = [var.node_pool_roles]
}
