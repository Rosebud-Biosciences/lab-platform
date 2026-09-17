mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-west-2" }
  }
}

run "public_issuer" {
  command = plan

  variables {
    issuer_url = "https://container.googleapis.com/v1/projects/p/locations/us-central1/clusters/c"
  }

  assert {
    condition     = output.issuer_url == "https://container.googleapis.com/v1/projects/p/locations/us-central1/clusters/c"
    error_message = "a public issuer is trusted as given"
  }
  assert {
    condition     = length(aws_s3_bucket.discovery) == 0 && output.discovery_bucket == null
    error_message = "no hosting for a public issuer"
  }
  assert {
    condition     = contains(aws_iam_openid_connect_provider.this.client_id_list, "sts.amazonaws.com")
    error_message = "the default audience is what the SDKs send"
  }
}

run "hosted_issuer" {
  command = plan

  variables {
    host_discovery = {
      bucket_name = "lab-kind-oidc-123456789012"
      prefix      = "kind-lab"
      jwks_json   = "{\"keys\":[{\"use\":\"sig\",\"kty\":\"RSA\",\"kid\":\"k\",\"alg\":\"RS256\",\"n\":\"x\",\"e\":\"AQAB\"}]}"
    }
  }

  assert {
    condition     = output.issuer_url == "https://lab-kind-oidc-123456789012.s3.us-west-2.amazonaws.com/kind-lab"
    error_message = "the hosted issuer is the virtual-hosted bucket URL plus prefix"
  }
  assert {
    condition     = aws_s3_object.openid_configuration[0].key == "kind-lab/.well-known/openid-configuration" && aws_s3_object.jwks[0].key == "kind-lab/keys.json"
    error_message = "discovery documents live under the prefix"
  }
  assert {
    condition     = jsondecode(aws_s3_object.openid_configuration[0].content).jwks_uri == "https://lab-kind-oidc-123456789012.s3.us-west-2.amazonaws.com/kind-lab/keys.json"
    error_message = "the discovery document must point at the hosted JWKS"
  }
  assert {
    condition     = aws_iam_openid_connect_provider.this.url == "https://lab-kind-oidc-123456789012.s3.us-west-2.amazonaws.com/kind-lab"
    error_message = "the IAM provider trusts the hosted issuer"
  }
}

run "hosted_issuer_without_prefix" {
  command = plan

  variables {
    host_discovery = {
      bucket_name = "lab-kind-oidc"
      jwks_json   = "{\"keys\":[]}"
    }
  }

  assert {
    condition     = output.issuer_url == "https://lab-kind-oidc.s3.us-west-2.amazonaws.com" && aws_s3_object.jwks[0].key == "keys.json"
    error_message = "no prefix means documents at the bucket root"
  }
}

run "exactly_one_mode" {
  command = plan

  variables {
    issuer_url     = "https://example.com"
    host_discovery = { bucket_name = "b-b-b", jwks_json = "{\"keys\":[]}" }
  }

  expect_failures = [var.issuer_url]
}

run "bucket_name_without_dots" {
  command = plan

  variables {
    host_discovery = { bucket_name = "has.dots.in.it", jwks_json = "{\"keys\":[]}" }
  }

  expect_failures = [var.host_discovery]
}
