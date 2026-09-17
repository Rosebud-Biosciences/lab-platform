data "aws_region" "current" {}

locals {
  hosting = var.host_discovery != null

  prefix = local.hosting ? trim(var.host_discovery.prefix, "/") : ""
  key    = local.prefix != "" ? "${local.prefix}/" : ""

  hosted_issuer = local.hosting ? (
    local.prefix != ""
    ? "https://${var.host_discovery.bucket_name}.s3.${data.aws_region.current.region}.amazonaws.com/${local.prefix}"
    : "https://${var.host_discovery.bucket_name}.s3.${data.aws_region.current.region}.amazonaws.com"
  ) : ""

  issuer_url = local.hosting ? local.hosted_issuer : var.issuer_url

  # What kube-apiserver serves at /.well-known/openid-configuration, minus the
  # in-cluster jwks_uri, which we point at the hosted copy.
  discovery = {
    issuer                                = local.issuer_url
    jwks_uri                              = "${local.issuer_url}/keys.json"
    authorization_endpoint                = "urn:kubernetes:programmatic_authorization"
    response_types_supported              = ["id_token"]
    subject_types_supported               = ["public"]
    id_token_signing_alg_values_supported = ["RS256"]
    claims_supported                      = ["sub", "iss"]
  }
}

# ------------------------------------------------------------------------------
# Hosted discovery (kind, on-prem): a public-read bucket holding two small JSON
# documents. Public by design -- an OIDC issuer IS a public document; the JWKS
# holds public keys only. Nothing else may be written to it.
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "discovery" {
  count = local.hosting ? 1 : 0

  # Two small, public, rewritten-on-rotation JSON documents: the S3 hardening
  # checks assume data worth protecting, which these are not (they are public
  # keys and a pointer to them).
  #checkov:skip=CKV_AWS_18:Access logging is noise for a two-object public discovery bucket
  #checkov:skip=CKV_AWS_21:Versioning is meaningless for documents rewritten on key rotation
  #checkov:skip=CKV_AWS_145:Public discovery documents cannot be KMS-encrypted (anonymous GetObject cannot decrypt)
  #checkov:skip=CKV2_AWS_61:No lifecycle: two objects that are overwritten, never accumulated
  #checkov:skip=CKV2_AWS_6:The public access block below is deliberately partial (policy allowed, ACLs blocked)
  bucket        = var.host_discovery.bucket_name
  force_destroy = var.host_discovery.force_destroy
  tags          = var.tags
}

# An OIDC issuer must be readable by AWS STS anonymously; these are the two
# knobs that allow a public bucket policy at all. ACLs stay blocked.
resource "aws_s3_bucket_public_access_block" "discovery" {
  count = local.hosting ? 1 : 0

  #checkov:skip=CKV_AWS_54:Public read of the OIDC discovery document is the purpose of this bucket
  #checkov:skip=CKV_AWS_56:see CKV_AWS_54
  bucket                  = aws_s3_bucket.discovery[0].id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "discovery" {
  count = local.hosting ? 1 : 0

  bucket = aws_s3_bucket.discovery[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "discovery" {
  count = local.hosting ? 1 : 0

  #checkov:skip=CKV_AWS_70:Anonymous GetObject on the two discovery objects is the point; writes stay private
  bucket = aws_s3_bucket.discovery[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadDiscoveryDocuments"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource = [
        "${aws_s3_bucket.discovery[0].arn}/${local.key}.well-known/openid-configuration",
        "${aws_s3_bucket.discovery[0].arn}/${local.key}keys.json",
      ]
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.discovery]
}

resource "aws_s3_object" "openid_configuration" {
  count = local.hosting ? 1 : 0

  bucket       = aws_s3_bucket.discovery[0].id
  key          = "${local.key}.well-known/openid-configuration"
  content      = jsonencode(local.discovery)
  content_type = "application/json"
  etag         = md5(jsonencode(local.discovery))
}

resource "aws_s3_object" "jwks" {
  count = local.hosting ? 1 : 0

  bucket       = aws_s3_bucket.discovery[0].id
  key          = "${local.key}keys.json"
  content      = var.host_discovery.jwks_json
  content_type = "application/json"
  etag         = md5(var.host_discovery.jwks_json)
}

# ------------------------------------------------------------------------------
# The IAM OIDC provider. With hosting, wait for the documents so IAM's
# validation fetch succeeds on the first apply.
# ------------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "this" {
  # tflint evaluates locals with variable defaults, where neither mode is set
  # and the URL is ""; var.issuer_url's validation rejects that at plan time.
  # tflint-ignore: aws_iam_openid_connect_provider_invalid_url
  url             = local.issuer_url
  client_id_list  = var.client_id_list
  thumbprint_list = length(var.thumbprint_list) > 0 ? var.thumbprint_list : null
  tags            = var.tags

  depends_on = [
    aws_s3_bucket_policy.discovery,
    aws_s3_object.openid_configuration,
    aws_s3_object.jwks,
  ]
}
