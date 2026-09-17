output "arn" {
  description = "The IAM OIDC provider ARN: aws/data-adapter's oidc_provider_arn"
  value       = aws_iam_openid_connect_provider.this.arn
}

output "issuer_url" {
  description = "The issuer URL the provider trusts. With host_discovery this is the hosted URL: start the API server with --service-account-issuer=<this> --service-account-jwks-uri=<this>/keys.json"
  value       = local.issuer_url
}

output "discovery_bucket" {
  description = "Name of the hosted-discovery bucket (null when issuer_url was given)"
  value       = local.hosting ? aws_s3_bucket.discovery[0].bucket : null
}
