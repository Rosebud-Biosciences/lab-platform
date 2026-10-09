# keycloak

The platform's user store: one [Keycloak](https://www.keycloak.org) per
cluster (codecentric/keycloakx, the official image) behind Dex. It holds the
users, the tenants as group subtrees and the delegated admins
([`modules/keycloak-realm`](../keycloak-realm)), and brokers the upstream
logins; Dex stays the issuer every service trusts, with this realm as its
connector. Its state -- a Postgres database of its own, outside any preview
branching -- is global: who exists must not differ per environment.

```hcl
module "keycloak" {
  source = "github.com/Rosebud-Biosciences/lab-platform//modules/keycloak?ref=v0.3.0"

  hostname = "https://id.example.com" # browsers AND pods (tokens carry it)
  ingress  = { enabled = true, class_name = "nginx", host = "id.example.com", tls_secret_name = "id-tls" }
  database = { host = "db.example.com", name = "keycloak", username = "keycloak", password = var.keycloak_db_password }
}

provider "keycloak" {
  url           = "https://id.example.com"
  client_id     = module.keycloak.admin_client_id     # master-realm service account
  client_secret = module.keycloak.admin_client_secret # (client credentials)
  initial_login = false
}
```

Hostname v2: `hostname` is the one base URL in tokens; with
`backchannel_dynamic` (default) back-channel calls -- the realm module's
provider through a NodePort or port-forward -- may use another name.
Fine-grained admin permissions v2 are enabled (`KC_FEATURES`), which the
realm's delegated admins need (Keycloak >= 26.2). The bootstrap admin is a
master-realm service-account client with a generated secret (Keycloak's
`bootstrap-admin-client-id`), not a user: tofu configures the realm with it,
and the master realm has no password to guess. Superadmins log in to the
platform realm and administer it from its own console
(`/admin/<realm>/console`).

The public Ingress serves `/realms/<realm>` for the platform realms
(`ingress.realms`, default `["lab"]`) and `/resources` only, so the master
realm, the admin console and the admin API are not published with the
logins. Put them on a name only operators reach with `admin_hostname`
(`KC_HOSTNAME_ADMIN`) and `admin_ingress` (e.g. the Tailscale IngressClass).

The bootstrap variables only act on Keycloak's first start. If the
`tofu-admin` client is deleted or its secret changed, use Keycloak's
[recovery command](https://www.keycloak.org/server/bootstrap-admin-recovery):
stop Keycloak (scale its StatefulSet to 0), run
`kc.sh bootstrap-admin service --client-id temp-admin --client-secret:env=SECRET`
in a one-off pod with the same image and database env, start Keycloak again,
and with that temporary service account recreate `tofu-admin` (master realm,
service account with the `admin` role) with the secret held in the
`<release>-bootstrap-admin` Secret. Then delete the temporary account.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.12.1 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.6 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 2.12.1 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.6 |

## Resources

| Name | Type |
|------|------|
| [helm_release.keycloak](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_ingress_v1.admin](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_namespace_v1.keycloak](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_secret_v1.bootstrap_admin](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.db](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [random_password.bootstrap_admin](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_database"></a> [database](#input\_database) | External PostgreSQL for Keycloak's own state (users, groups, sessions, the realm). A database of its own, outside any preview branching: identity is global. | <pre>object({<br/>    host     = string<br/>    port     = optional(number, 5432)<br/>    name     = string<br/>    username = string<br/>    password = string<br/>  })</pre> | n/a | yes |
| <a name="input_hostname"></a> [hostname](#input\_hostname) | Keycloak's public base URL (hostname v2: scheme, host, optional port, no<br/>path), e.g. "https://id.example.com". Tokens carry it as their issuer<br/>origin, so browsers AND pods must reach Keycloak at this URL (on kind:<br/>the in-cluster Service URL; on a tailnet-only cluster: the private<br/>Ingress hostname plus pod DNS for it, docs/auth.md). Requests arriving<br/>under another name (a NodePort, a port-forward) are answered as this<br/>hostname when backchannel\_dynamic is set. | `string` | n/a | yes |
| <a name="input_admin_hostname"></a> [admin\_hostname](#input\_admin\_hostname) | Base URL of Keycloak's admin console and admin API (KC\_HOSTNAME\_ADMIN), e.g. https://keycloak-admin.<tailnet>.ts.net: a name only operators reach, served by admin\_ingress. Empty: the admin console answers on hostname, reachable only where something routes /admin (in-cluster, a port-forward). | `string` | `""` | no |
| <a name="input_admin_ingress"></a> [admin\_ingress](#input\_admin\_ingress) | Optional Ingress for admin\_hostname (a private IngressClass, e.g. tailscale): serves everything, admin console included, on that host only | <pre>object({<br/>    enabled         = optional(bool, false)<br/>    class_name      = optional(string, "")<br/>    host            = optional(string, "")<br/>    annotations     = optional(map(string), {})<br/>    tls_secret_name = optional(string, "")<br/>  })</pre> | `{}` | no |
| <a name="input_backchannel_dynamic"></a> [backchannel\_dynamic](#input\_backchannel\_dynamic) | Let back-channel requests (token exchange, the admin API) use the host they arrive on, so tofu can configure the realm through a NodePort or port-forward while browsers use hostname (KC\_HOSTNAME\_BACKCHANNEL\_DYNAMIC) | `bool` | `true` | no |
| <a name="input_bootstrap_admin_client_id"></a> [bootstrap\_admin\_client\_id](#input\_bootstrap\_admin\_client\_id) | Client id of the master-realm admin service account Keycloak creates on first start (client credentials, generated secret). modules/keycloak-realm's provider authenticates with it; there is no password-bearing admin user. Superadmins administer the platform realm from its own console (/admin/<realm>/console). | `string` | `"tofu-admin"` | no |
| <a name="input_chart_repository"></a> [chart\_repository](#input\_chart\_repository) | Helm repository holding the keycloakx chart | `string` | `"https://codecentric.github.io/helm-charts"` | no |
| <a name="input_chart_version"></a> [chart\_version](#input\_chart\_version) | codecentric/keycloakx Helm chart version | `string` | `"7.3.2"` | no |
| <a name="input_create_namespace"></a> [create\_namespace](#input\_create\_namespace) | Create the namespace (false to deploy into an existing one) | `bool` | `true` | no |
| <a name="input_extra_env"></a> [extra\_env](#input\_extra\_env) | Extra Keycloak environment variables (KC\_* options), merged over the module's | `map(string)` | `{}` | no |
| <a name="input_extra_values"></a> [extra\_values](#input\_extra\_values) | Extra Helm values documents, applied after the module's | `list(string)` | `[]` | no |
| <a name="input_image_tag"></a> [image\_tag](#input\_image\_tag) | quay.io/keycloak/keycloak tag; empty uses the chart's (26.7.4 for chart 7.3.2). Fine-grained admin permissions v2 need >= 26.2. | `string` | `""` | no |
| <a name="input_ingress"></a> [ingress](#input\_ingress) | Optional Ingress in front of Keycloak (host should match hostname). It serves paths only -- by default /realms/<realm> for each of realms (logins, token endpoints, the account console) and /resources (their assets) -- so neither the master realm nor the admin console and admin API are published with the logins; see admin\_hostname / admin\_ingress. paths replaces that list. | <pre>object({<br/>    enabled         = optional(bool, false)<br/>    class_name      = optional(string, "")<br/>    host            = optional(string, "")<br/>    annotations     = optional(map(string), {})<br/>    tls_secret_name = optional(string, "")<br/>    realms          = optional(list(string), ["lab"])<br/>    paths           = optional(list(string))<br/>  })</pre> | `{}` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace for Keycloak | `string` | `"keycloak"` | no |
| <a name="input_node_port"></a> [node\_port](#input\_node\_port) | Fixed node port for service\_type = NodePort (e.g. one kind maps to the host) | `number` | `null` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node selector for the Keycloak pod | `map(string)` | `{}` | no |
| <a name="input_proxy_headers"></a> [proxy\_headers](#input\_proxy\_headers) | Which proxy headers Keycloak trusts for the client's scheme and host: "xforwarded" (ingress-nginx, most controllers), "forwarded" (RFC 7239), or "" (none: Keycloak is reached directly) | `string` | `"xforwarded"` | no |
| <a name="input_release_name"></a> [release\_name](#input\_release\_name) | Helm release name; also the chart's fullname, so the HTTP Service is <release\_name>-http | `string` | `"keycloak"` | no |
| <a name="input_resources"></a> [resources](#input\_resources) | Keycloak container resources | `any` | <pre>{<br/>  "limits": {<br/>    "memory": "1536Mi"<br/>  },<br/>  "requests": {<br/>    "cpu": "250m",<br/>    "memory": "768Mi"<br/>  }<br/>}</pre> | no |
| <a name="input_service_type"></a> [service\_type](#input\_service\_type) | Service type for Keycloak's HTTP port: ClusterIP, or NodePort to reach it from the machine running tofu (kind) | `string` | `"ClusterIP"` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Tolerations for the Keycloak pod | `list(any)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_admin_client_id"></a> [admin\_client\_id](#output\_admin\_client\_id) | The master-realm admin service account (client credentials) modules/keycloak-realm's provider authenticates with |
| <a name="output_admin_client_secret"></a> [admin\_client\_secret](#output\_admin\_client\_secret) | Its secret |
| <a name="output_base_url"></a> [base\_url](#output\_base\_url) | Keycloak's public base URL (the hostname variable); a realm's issuer is <base\_url>/realms/<realm> |
| <a name="output_internal_url"></a> [internal\_url](#output\_internal\_url) | In-cluster base URL of Keycloak's HTTP Service |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Keycloak's namespace |
| <a name="output_release"></a> [release](#output\_release) | The Helm release, for depends\_on in callers configuring the realm |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | Keycloak's HTTP Service |
<!-- END_TF_DOCS -->
