# dex

The platform's OpenID Connect issuer: one [Dex](https://dexidp.io) per
cluster that every service trusts. Dex owns no users. It brokers whatever
identity provider the `connectors` name -- Google, GitHub, Microsoft, LDAP,
SAML, any other OIDC issuer -- or, for CI and laptops, its own password DB,
and re-issues standard OIDC tokens. That single hop is what makes the
platform's auth vendor-neutral (swap the connector, nothing downstream
changes) and preview-friendly: with Dex's `kubernetes` storage backend an
OAuth2 client is an `OAuth2Client` custom resource in this namespace, so each
environment `modules/workloads` stamps registers its own clients and takes
them away again, without a static redirect-URI list at Google.

What relies on it (all wired by `modules/workloads` `auth = { mode = "oidc" }`):

| Relying party | How |
| --- | --- |
| Dagster, MLflow, the Ray dashboard | an oauth2-proxy per service in front of a UI that has no login of its own; per-service `allowed_groups` |
| Argo Workflows | native SSO (`authModes: [sso]`) with group `rbac-rule`s |
| JupyterHub | `GenericOAuthenticator` against Dex, `allowed_groups` |
| the webapp | its own OIDC login, users/sessions/memberships in its own (branchable) database |

Identity stays global -- who exists and which groups they are in is the
upstream IdP's -- while what each environment does with an identity is
stamped or branched with it. See `docs/auth.md`.

```hcl
module "dex" {
  source = "github.com/Rosebud-Biosciences/lab-platform//modules/dex?ref=v0.3.0"

  providers = { kubernetes = kubernetes, helm = helm, kubectl = kubectl }

  # Browsers and pods must both reach this URL: on kind the Service URL, on a
  # real cluster the Ingress hostname.
  issuer_url = "https://dex.example.com/dex"
  ingress = {
    enabled         = true
    class_name      = "nginx"
    host            = "dex.example.com"
    tls_secret_name = "dex-tls"
  }

  # Dex expands $NAME from its environment, which comes from a Secret:
  # the secret never enters the Helm values or Dex's rendered config.
  connectors = [{
    type = "google"
    id   = "google"
    name = "Google"
    config = {
      clientID      = var.google_client_id
      clientSecret  = "$GOOGLE_CLIENT_SECRET"
      redirectURI   = "https://dex.example.com/dex/callback"
      hostedDomains = ["example.com"]
    }
  }]
  connector_env_secret_name = "dex-google" # created outside tofu; or connector_env = { ... }

  # A preview's CI may manage only preview- clients (Kubernetes >= 1.30).
  client_admission = {
    restricted_user_prefixes = ["arn:aws:sts::123456789012:assumed-role/preview-deployer/"]
  }
}
```

For CI (`examples/kind`): `enable_password_db = true` with one
`static_passwords` entry, plus a `mockCallback` connector whose fixed identity
carries group `authors` -- enough to exercise both a plain login and a
group-gated service.

Groups: Dex forwards a `groups` claim when the connector can supply one
(GitHub teams and LDAP/SAML/Microsoft groups out of the box; Google needs an
Admin SDK service account on the connector). Local password-DB users have no
groups.

Dex creates its `dex.coreos.com` CRDs on first start; the release waits for
the pod to be Ready so consumers can create `OAuth2Client` CRs right after.
Connector secrets belong in `connector_env_secret_name` (a Secret made
outside tofu, e.g. by External Secrets: out of state entirely) or
`connector_env` (a Secret this module makes: in state, but not in the Helm
release or Dex's config), referenced as `$NAME` in `connectors`. Literal
values in `connectors` land in the chart's config Secret and in state.

ID tokens last an hour (`id_token_expiry`): relying parties refresh, so a
group removed at the IdP stops granting access within the hour. Dex keeps no
browser session in any release yet (auth sessions with per-client
`ssoSharedWith` merged after v2.45.1), so logins to a second service are
silent only when the upstream IdP has a session of its own.

`client_admission` guards the per-environment clients: requests from the
restricted principals may create, change or delete only clients whose id
matches `allowed_id_pattern` (both the new and the old object), so a
preview's CI cannot rewrite prod's redirect URIs. It guards against
mistakes, not against a principal that can delete the policy itself -- see
`docs/auth.md` on scoping the preview role.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.12.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | >= 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 2.12.1 |

## Resources

| Name | Type |
|------|------|
| [helm_release.dex](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.client_admission_binding](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.client_admission_policy](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_namespace_v1.dex](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_secret_v1.connector_env](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_issuer_url"></a> [issuer\_url](#input\_issuer\_url) | The OIDC issuer URL, i.e. the URL browsers AND pods reach Dex at, including<br/>the path Dex serves under. Every relying party validates tokens against<br/>this exact string, so it must resolve identically from both. On a kind<br/>cluster the in-cluster Service URL works for both<br/>(http://dex.dex.svc.cluster.local:5556/dex); on a real cluster use the<br/>Ingress hostname (https://dex.example.com/dex). | `string` | n/a | yes |
| <a name="input_chart_repository"></a> [chart\_repository](#input\_chart\_repository) | Helm repository holding the dex chart | `string` | `"https://charts.dexidp.io"` | no |
| <a name="input_chart_version"></a> [chart\_version](#input\_chart\_version) | dexidp/dex Helm chart version | `string` | `"0.24.1"` | no |
| <a name="input_client_admission"></a> [client\_admission](#input\_client\_admission) | A ValidatingAdmissionPolicy on OAuth2Client objects in Dex's namespace:<br/>requests from restricted principals (Kubernetes usernames starting with<br/>one of restricted\_user\_prefixes, or members of restricted\_groups -- e.g.<br/>the preview CI role's username) may only create, change or delete<br/>clients whose id matches allowed\_id\_pattern (a preview's own<br/>"preview-" prefix, modules/preview-access's namespace\_prefix), so a PR's tofu cannot rewrite prod's redirect URIs. Everyone<br/>else is unaffected. Null disables it. Needs Kubernetes >= 1.30. | <pre>object({<br/>    restricted_user_prefixes = optional(list(string), [])<br/>    restricted_groups        = optional(list(string), [])<br/>    allowed_id_pattern       = optional(string, "^preview-")<br/>  })</pre> | `null` | no |
| <a name="input_connector_env"></a> [connector\_env](#input\_connector\_env) | Secret values for the connectors, as environment variables of the Dex<br/>pod: reference them as $NAME in `connectors` (Dex expands them), e.g.<br/>connector\_env = { GOOGLE\_CLIENT\_SECRET = var.google\_client\_secret } with<br/>clientSecret = "$GOOGLE\_CLIENT\_SECRET". They land in a Secret this module<br/>creates (so still in tofu state, but not in the Helm release or Dex's<br/>rendered config). Prefer connector\_env\_secret\_name to keep them out of<br/>state as well. | `map(string)` | `{}` | no |
| <a name="input_connector_env_secret_name"></a> [connector\_env\_secret\_name](#input\_connector\_env\_secret\_name) | Name of an existing Secret in Dex's namespace (created outside tofu, e.g. by External Secrets) whose keys become Dex's environment for $NAME expansion in `connectors`. Takes precedence over connector\_env. | `string` | `""` | no |
| <a name="input_connectors"></a> [connectors](#input\_connectors) | Dex connectors: the upstream identity providers users actually log in with,<br/>as the objects Dex's config.yaml takes (type, id, name, config). Any of<br/>Dex's connectors works -- google, github, microsoft, ldap, saml, oidc<br/>(generic) -- and swapping one for another changes nothing downstream:<br/>relying parties only ever see Dex. `mockCallback` (a fixed test identity<br/>in group "authors") is useful in CI. Sensitive: connector configs carry<br/>client secrets. Example:<br/><br/>  connectors = [{<br/>    type = "google"<br/>    id   = "google"<br/>    name = "Google"<br/>    config = {<br/>      clientID     = var.google\_client\_id<br/>      clientSecret = var.google\_client\_secret<br/>      redirectURI  = "https://dex.example.com/dex/callback"<br/>      hostedDomains = ["example.com"]<br/>    }<br/>  }] | `list(any)` | `[]` | no |
| <a name="input_create_namespace"></a> [create\_namespace](#input\_create\_namespace) | Create the namespace (false to deploy into an existing one) | `bool` | `true` | no |
| <a name="input_enable_password_db"></a> [enable\_password\_db](#input\_enable\_password\_db) | Enable Dex's built-in local users (static\_passwords). For CI and laptops; production logs in through a connector. | `bool` | `false` | no |
| <a name="input_extra_values"></a> [extra\_values](#input\_extra\_values) | Additional Helm values documents (YAML strings) merged after the module's; later documents win | `list(string)` | `[]` | no |
| <a name="input_id_token_expiry"></a> [id\_token\_expiry](#input\_id\_token\_expiry) | Lifetime of the ID tokens Dex issues (Go duration). Short, because relying parties (oauth2-proxy, the webapp) re-validate by refreshing: a user removed from a group loses what the group granted within this window. | `string` | `"1h"` | no |
| <a name="input_image_tag"></a> [image\_tag](#input\_image\_tag) | Dex image tag; empty uses the chart's appVersion | `string` | `""` | no |
| <a name="input_ingress"></a> [ingress](#input\_ingress) | Expose Dex through an Ingress. Required whenever the issuer\_url is not an<br/>in-cluster address: the login page must be reachable by browsers, and the<br/>token endpoint by the pods (oauth2-proxy, Argo, JupyterHub, the webapp).<br/>`annotations` are passed through (cert-manager, external-dns, ALB, ...);<br/>`tls_secret_name` is the pre-existing TLS Secret for the host, empty for a<br/>controller that terminates TLS itself. | <pre>object({<br/>    enabled         = optional(bool, false)<br/>    class_name      = optional(string, "")<br/>    host            = optional(string, "")<br/>    path            = optional(string, "/dex")<br/>    annotations     = optional(map(string), {})<br/>    tls_secret_name = optional(string, "")<br/>  })</pre> | `{}` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace for Dex. Environments register their OAuth2Client CRs here (modules/workloads auth.dex\_namespace). | `string` | `"dex"` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | nodeSelector for the Dex pod | `map(string)` | `{}` | no |
| <a name="input_release_name"></a> [release\_name](#input\_release\_name) | Helm release name; the chart derives the Service name from it | `string` | `"dex"` | no |
| <a name="input_resources"></a> [resources](#input\_resources) | Container resources for the Dex pod | `any` | <pre>{<br/>  "limits": {<br/>    "memory": "256Mi"<br/>  },<br/>  "requests": {<br/>    "cpu": "50m",<br/>    "memory": "64Mi"<br/>  }<br/>}</pre> | no |
| <a name="input_skip_approval_screen"></a> [skip\_approval\_screen](#input\_skip\_approval\_screen) | Skip Dex's consent page after upstream login (single-org platforms want this) | `bool` | `true` | no |
| <a name="input_static_clients"></a> [static\_clients](#input\_static\_clients) | OAuth2 clients fixed in Dex's config (bring-your-own). Environments<br/>stamped by modules/workloads register theirs dynamically as OAuth2Client<br/>CRs instead, so this is for clients outside the platform (kubectl OIDC<br/>login, a CLI). `public = true` clients need no secret (native apps). | <pre>list(object({<br/>    id            = string<br/>    name          = string<br/>    secret        = optional(string, "")<br/>    redirect_uris = optional(list(string), [])<br/>    public        = optional(bool, false)<br/>  }))</pre> | `[]` | no |
| <a name="input_static_passwords"></a> [static\_passwords](#input\_static\_passwords) | Local users for enable\_password\_db: email, bcrypt hash of the password,<br/>display username, and a stable user\_id. Local users have no groups. Dex's<br/>documented example hash `$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W`<br/>is the word "password". | <pre>list(object({<br/>    email    = string<br/>    hash     = string<br/>    username = string<br/>    user_id  = string<br/>  }))</pre> | `[]` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Tolerations for the Dex pod | `list(any)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_client_crd"></a> [client\_crd](#output\_client\_crd) | apiVersion/kind of the custom resource a dynamically registered client is (Dex's kubernetes storage) |
| <a name="output_in_cluster_url"></a> [in\_cluster\_url](#output\_in\_cluster\_url) | In-cluster base URL of Dex (no path); equals the issuer's origin on kind |
| <a name="output_issuer_url"></a> [issuer\_url](#output\_issuer\_url) | The OIDC issuer URL relying parties are configured with (modules/workloads auth.issuer\_url) |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Dex's namespace: where environments register OAuth2Client CRs (modules/workloads auth.dex\_namespace) |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | Dex's Service name |
<!-- END_TF_DOCS -->
