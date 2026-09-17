# The Tailscale subnet router is optional: with it off (the default), none of the
# Tailscale resources exist (asserted via the empty relay outputs). Plan-only,
# mocked providers.

mock_provider "aws" {
  # Keep mocked IAM policy documents valid JSON (the VPC module's flow-log role
  # consumes one); the default mock string fails the provider's JSON validation.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  # The module slices this to num_availability_zones (3); the default mock list is
  # too short. Provide three AZ names.
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-west-2a", "us-west-2b", "us-west-2c"]
    }
  }
  # A mocked policy arn is a random string; downstream attachments validate ARN
  # shape, so pin it to a well-formed ARN.
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock"
    }
  }
  # The VPC module's flow-log role + log group feed ARN-validated fields on
  # aws_flow_log; pin them to well-formed ARNs.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-west-2:123456789012:log-group:mock"
    }
  }
}
mock_provider "tailscale" {}

variables {
  name = "vpc-test"
}

run "tailscale_router_off_by_default" {
  command = plan

  assert {
    condition     = output.tailscale_instance_id == ""
    error_message = "no Tailscale relay instance should be created when the router is disabled"
  }
  assert {
    condition     = output.tailscale_security_group_id == ""
    error_message = "no Tailscale relay security group should be created when the router is disabled"
  }
}
