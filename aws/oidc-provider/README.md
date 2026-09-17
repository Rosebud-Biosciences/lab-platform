# aws/oidc-provider

The bridge that lets **AWS data be used from non-AWS compute without static
keys**: registers a foreign Kubernetes cluster's ServiceAccount token issuer
as an IAM OIDC provider, so [`aws/data-adapter`](../data-adapter) roles
(`binding = "projected"`) can trust its pods exactly as they trust an EKS
cluster's.

Two situations:

- **The issuer is public** (GKE, AKS, any cluster with a reachable API
  server): pass `issuer_url`. Nothing is hosted.
- **The issuer is not reachable by AWS** (kind on a laptop or a CI runner,
  an on-prem cluster): set `host_discovery`. The module publishes the OIDC
  discovery document and the cluster's JWKS to a public-read S3 bucket, and
  the issuer becomes that bucket URL -- the same trick EKS uses internally.

## Hosted issuer flow (kind)

The issuer URL must be baked into the API server before it mints tokens, and
the JWKS only exists once the cluster runs, so:

1. Pick a bucket name and prefix; the issuer will be
   `https://<bucket>.s3.<region>.amazonaws.com/<prefix>`.
2. Start the cluster with that issuer. For kind:

   ```yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   kubeadmConfigPatches:
     - |
       kind: ClusterConfiguration
       apiServer:
         extraArgs:
           service-account-issuer: https://<bucket>.s3.<region>.amazonaws.com/<prefix>
           service-account-jwks-uri: https://<bucket>.s3.<region>.amazonaws.com/<prefix>/keys.json
   ```

3. Export the JWKS: `kubectl get --raw /openid/v1/jwks > jwks.json`.
4. Apply this module with `host_discovery = { bucket_name, prefix, jwks_json = file("jwks.json") }`,
   feed `arn` to `aws/data-adapter` (`binding = "projected"`), and its
   `workload_identity` to `modules/workloads`. Pods now assume per-service
   IAM roles with a projected token; no keys anywhere.

[`examples/kind-aws-data`](../../examples/kind-aws-data) runs this end to end.
Key rotation (a new kind cluster) is a re-apply with the new JWKS.

The bucket is intentionally public-read for two objects and nothing else; the
JWKS contains public keys only.

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

## Resources

| Name | Type |
|------|------|
| [aws_iam_openid_connect_provider.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_s3_bucket.discovery](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_ownership_controls.discovery](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.discovery](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.discovery](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_object.jwks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [aws_s3_object.openid_configuration](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_client_id_list"></a> [client\_id\_list](#input\_client\_id\_list) | Audiences the provider accepts; sts.amazonaws.com is what modules/workloads' projected token and the AWS SDKs use | `list(string)` | <pre>[<br/>  "sts.amazonaws.com"<br/>]</pre> | no |
| <a name="input_host_discovery"></a> [host\_discovery](#input\_host\_discovery) | Host the issuer on S3 for a cluster AWS cannot reach (kind, on-prem).<br/>The module creates a public-read bucket and writes<br/><prefix>/.well-known/openid-configuration and <prefix>/keys.json; the<br/>issuer becomes https://<bucket\_name>.s3.<region>.amazonaws.com[/<prefix>]<br/>(output issuer\_url). The API server must have been started with<br/>  --service-account-issuer=<that URL><br/>  --service-account-jwks-uri=<that URL>/keys.json<br/>and jwks\_json is its `kubectl get --raw /openid/v1/jwks`. Rotate by<br/>re-applying with the new JWKS. bucket\_name must be DNS-safe without dots<br/>(virtual-hosted TLS). | <pre>object({<br/>    bucket_name   = string<br/>    prefix        = optional(string, "")<br/>    jwks_json     = string<br/>    force_destroy = optional(bool, true)<br/>  })</pre> | `null` | no |
| <a name="input_issuer_url"></a> [issuer\_url](#input\_issuer\_url) | The cluster's ServiceAccount token issuer (https://...) when AWS can fetch<br/>its discovery document directly -- GKE<br/>(https://container.googleapis.com/v1/projects/.../clusters/...), AKS<br/>(the cluster's oidcIssuerProfile.issuerUrl), any cluster whose API server<br/>is public. Leave empty and set host\_discovery instead when it is not. | `string` | `""` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource | `map(string)` | `{}` | no |
| <a name="input_thumbprint_list"></a> [thumbprint\_list](#input\_thumbprint\_list) | Server certificate thumbprints. IAM validates well-known CAs itself since 2023, so this is normally left empty; set it for an issuer behind a private CA. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_arn"></a> [arn](#output\_arn) | The IAM OIDC provider ARN: aws/data-adapter's oidc\_provider\_arn |
| <a name="output_discovery_bucket"></a> [discovery\_bucket](#output\_discovery\_bucket) | Name of the hosted-discovery bucket (null when issuer\_url was given) |
| <a name="output_issuer_url"></a> [issuer\_url](#output\_issuer\_url) | The issuer URL the provider trusts. With host\_discovery this is the hosted URL: start the API server with --service-account-issuer=<this> --service-account-jwks-uri=<this>/keys.json |
<!-- END_TF_DOCS -->
