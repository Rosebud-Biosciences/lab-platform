variable "issuer_url" {
  description = <<-EOT
    The cluster's ServiceAccount token issuer (https://...) when AWS can fetch
    its discovery document directly -- GKE
    (https://container.googleapis.com/v1/projects/.../clusters/...), AKS
    (the cluster's oidcIssuerProfile.issuerUrl), any cluster whose API server
    is public. Leave empty and set host_discovery instead when it is not.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = (var.issuer_url != "") != (var.host_discovery != null)
    error_message = "Set exactly one of issuer_url (public issuer) or host_discovery (S3-hosted issuer)."
  }

  validation {
    condition     = var.issuer_url == "" || startswith(var.issuer_url, "https://")
    error_message = "issuer_url must start with https://."
  }
}

variable "host_discovery" {
  description = <<-EOT
    Host the issuer on S3 for a cluster AWS cannot reach (kind, on-prem).
    The module creates a public-read bucket and writes
    <prefix>/.well-known/openid-configuration and <prefix>/keys.json; the
    issuer becomes https://<bucket_name>.s3.<region>.amazonaws.com[/<prefix>]
    (output issuer_url). The API server must have been started with
      --service-account-issuer=<that URL>
      --service-account-jwks-uri=<that URL>/keys.json
    and jwks_json is its `kubectl get --raw /openid/v1/jwks`. Rotate by
    re-applying with the new JWKS. bucket_name must be DNS-safe without dots
    (virtual-hosted TLS).
  EOT
  type = object({
    bucket_name   = string
    prefix        = optional(string, "")
    jwks_json     = string
    force_destroy = optional(bool, true)
  })
  default = null

  validation {
    condition     = var.host_discovery == null || can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.host_discovery.bucket_name))
    error_message = "host_discovery.bucket_name must be 3-63 lowercase alphanumerics/dashes with no dots."
  }

  validation {
    condition     = var.host_discovery == null || can(jsondecode(var.host_discovery.jwks_json).keys)
    error_message = "host_discovery.jwks_json must be a JWKS document ({\"keys\": [...]})."
  }
}

variable "client_id_list" {
  description = "Audiences the provider accepts; sts.amazonaws.com is what modules/workloads' projected token and the AWS SDKs use"
  type        = list(string)
  default     = ["sts.amazonaws.com"]
}

variable "thumbprint_list" {
  description = "Server certificate thumbprints. IAM validates well-known CAs itself since 2023, so this is normally left empty; set it for an issuer behind a private CA."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}
