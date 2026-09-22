# keycloak-realm

The platform realm inside [`modules/keycloak`](../keycloak): tenants as group
subtrees, superadmins, delegated tenant and group admins, the Dex client,
and the upstream identity providers. See [docs/tenancy.md](../../docs/tenancy.md).

| Group | Who | May |
| --- | --- | --- |
| `/platform-admins` | `superadmins` (authoritative here) | realm-admin |
| `/<tenant>/admins` | runtime | manage the tenant's members: accounts, and who is in (and administers) each of its groups |
| `/<tenant>/<group>/admins` | runtime | add and remove members of that group and its admins |

Delegation is fine-grained admin permissions v2, shaped by its evaluation
rules -- every permission covering a group must grant, and
`manage-membership` does not cascade: one permission on the tenant's own two
groups for its admins (the member scopes cascade to its groups), one per
group whose single policy admits that group's admins or the tenant's, and
one realm-wide users permission (`view`, `manage-group-membership`; adding a
user to a group needs that *and* `manage-membership` on the group). Nothing
targets `/platform-admins` or another tenant, and nobody gets `manage` on
groups: Keycloak gives a group created at runtime no permissions
(keycloak/keycloak#29100), so groups are declared in `tenants`. Keycloak's
"Verify Profile" required action is off (names come from the upstream IdP).
Changing a group permission's policies in place can fail with a 400 from
Keycloak; `-replace` the permission if it does.

```hcl
module "realm" {
  source = "github.com/Rosebud-Biosciences/lab-platform//modules/keycloak-realm?ref=main"

  keycloak_base_url = module.keycloak.base_url
  tenants           = module.tenancy.realm_tenants
  superadmins       = ["sam@lab.org"]
  dex_redirect_uri  = "https://dex.example.com/dex/callback"
  identity_providers = {
    # Your own Workspace: verified, bounded emails, so a first login may take
    # over the pre-created account with that address (superadmins included).
    google = { type = "google", client_id = var.google_client_id, client_secret = var.google_client_secret, hosted_domain = "lab.org", link_existing_by_email = true }
  }
}

module "dex" {
  source        = "github.com/Rosebud-Biosciences/lab-platform//modules/dex?ref=main"
  connectors    = [module.realm.dex_connector]
  connector_env = module.realm.dex_connector_env # $KEYCLOAK_CLIENT_SECRET
  # ...
}
```

Superadmins without a local user are pre-created with no credential; their
first brokered login links to them only through a provider with
`link_existing_by_email` (off by default, and refused unless the provider's
emails are trusted). Linking has no confirmation step: whoever controls the
provider becomes any account it can assert an address for. Enable it for
your own Workspace's Google (`hosted_domain`), never for a provider a
tenant brings; generic OIDC providers need `issuer` and `jwks_url` (tokens
are always signature-checked) and are not trusted for emails unless you say
so (`trust_email`). Brute-force protection is on for password logins. The
`groups` client scope puts full paths in Dex's tokens.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_keycloak"></a> [keycloak](#requirement\_keycloak) | >= 5.9 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.6 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_keycloak"></a> [keycloak](#provider\_keycloak) | >= 5.9 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.6 |

## Resources

| Name | Type |
|------|------|
| [keycloak_authentication_execution.auto_link](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/authentication_execution) | resource |
| [keycloak_authentication_execution.create_if_unique](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/authentication_execution) | resource |
| [keycloak_authentication_flow.link_by_email](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/authentication_flow) | resource |
| [keycloak_group.group](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/group) | resource |
| [keycloak_group.group_admins](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/group) | resource |
| [keycloak_group.platform_admins](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/group) | resource |
| [keycloak_group.tenant](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/group) | resource |
| [keycloak_group.tenant_admins](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/group) | resource |
| [keycloak_group_admin_permissions.group](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/group_admin_permissions) | resource |
| [keycloak_group_admin_permissions.tenant](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/group_admin_permissions) | resource |
| [keycloak_group_memberships.platform_admins](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/group_memberships) | resource |
| [keycloak_group_roles.group_admins](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/group_roles) | resource |
| [keycloak_group_roles.platform_admins](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/group_roles) | resource |
| [keycloak_group_roles.tenant_admins](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/group_roles) | resource |
| [keycloak_oidc_github_identity_provider.this](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/oidc_github_identity_provider) | resource |
| [keycloak_oidc_google_identity_provider.this](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/oidc_google_identity_provider) | resource |
| [keycloak_oidc_identity_provider.this](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/oidc_identity_provider) | resource |
| [keycloak_openid_client.dex](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/openid_client) | resource |
| [keycloak_openid_client_default_scopes.dex](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/openid_client_default_scopes) | resource |
| [keycloak_openid_client_group_policy.all_admins](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/openid_client_group_policy) | resource |
| [keycloak_openid_client_group_policy.group_admins](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/openid_client_group_policy) | resource |
| [keycloak_openid_client_group_policy.tenant_admins](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/openid_client_group_policy) | resource |
| [keycloak_openid_client_scope.groups](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/openid_client_scope) | resource |
| [keycloak_openid_group_membership_protocol_mapper.groups](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/openid_group_membership_protocol_mapper) | resource |
| [keycloak_realm.this](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/realm) | resource |
| [keycloak_required_action.verify_profile](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/required_action) | resource |
| [keycloak_user.local](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/user) | resource |
| [keycloak_user.superadmin](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/user) | resource |
| [keycloak_user_groups.local](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/user_groups) | resource |
| [keycloak_users_admin_permissions.admins](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/resources/users_admin_permissions) | resource |
| [random_password.dex_client](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [keycloak_openid_client.admin_permissions](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/data-sources/openid_client) | data source |
| [keycloak_openid_client.realm_management](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/data-sources/openid_client) | data source |
| [keycloak_role.query](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/data-sources/role) | data source |
| [keycloak_role.realm_admin](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs/data-sources/role) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_dex_redirect_uri"></a> [dex\_redirect\_uri](#input\_dex\_redirect\_uri) | Dex's callback URL (<dex issuer>/callback) | `string` | n/a | yes |
| <a name="input_keycloak_base_url"></a> [keycloak\_base\_url](#input\_keycloak\_base\_url) | Keycloak's public base URL (modules/keycloak base\_url), used to build the issuer URL | `string` | n/a | yes |
| <a name="input_admins_can_view_all_users"></a> [admins\_can\_view\_all\_users](#input\_admins\_can\_view\_all\_users) | Let tenant and group admins look up any user in the realm (needed to add someone who is not yet a member; FGAP v2 user permissions are realm-wide). Memberships stay fenced to their own groups either way. | `bool` | `true` | no |
| <a name="input_brute_force_detection"></a> [brute\_force\_detection](#input\_brute\_force\_detection) | Keycloak's brute-force protection for the realm's password logins (local users): temporary lockouts that grow with repeated failures. max\_login\_failures before the first lockout. | <pre>object({<br/>    enabled                  = optional(bool, true)<br/>    max_login_failures       = optional(number, 10)<br/>    wait_increment_seconds   = optional(number, 60)<br/>    max_failure_wait_seconds = optional(number, 900)<br/>    failure_reset_seconds    = optional(number, 43200)<br/>  })</pre> | `{}` | no |
| <a name="input_connector_name"></a> [connector\_name](#input\_connector\_name) | Name of the Dex connector (the login button Dex shows) | `string` | `"Lab account"` | no |
| <a name="input_dex_client_id"></a> [dex\_client\_id](#input\_dex\_client\_id) | Client id of the confidential client Dex logs in with | `string` | `"dex"` | no |
| <a name="input_display_name"></a> [display\_name](#input\_display\_name) | Realm display name on the login page | `string` | `"Lab"` | no |
| <a name="input_identity_providers"></a> [identity\_providers](#input\_identity\_providers) | Upstream identity providers Keycloak brokers, keyed by alias. type:<br/>"google" (hosted\_domain restricts to a Workspace domain), "github", or<br/>"oidc" (authorization\_url, token\_url, issuer and jwks\_url all required;<br/>signatures are always validated).<br/><br/>trust\_email: take the provider's email as verified. Default true for<br/>google and github (they verify), false for oidc -- set it only for an<br/>issuer that verifies emails. Dex refuses unverified ones, so users of an<br/>untrusted provider cannot log in until Keycloak verifies their address<br/>itself: set verify\_email and smtp.<br/><br/>link\_existing\_by\_email (default false, per provider): a first login whose<br/>email matches an existing user -- a pre-created superadmin, or someone an<br/>admin added -- becomes that user, with no confirmation. Whoever controls<br/>the provider can then claim any address it can assert, superadmins<br/>included, so enable it only for a provider you control whose emails are<br/>verified and bounded (Google with your Workspace hosted\_domain), and<br/>never for one a tenant brings. It requires trust\_email. | <pre>map(object({<br/>    type                   = string<br/>    client_id              = string<br/>    client_secret          = string<br/>    display_name           = optional(string)<br/>    hosted_domain          = optional(string, "")<br/>    authorization_url      = optional(string, "")<br/>    token_url              = optional(string, "")<br/>    issuer                 = optional(string, "")<br/>    jwks_url               = optional(string, "")<br/>    default_scopes         = optional(string, "openid email profile")<br/>    trust_email            = optional(bool)<br/>    link_existing_by_email = optional(bool, false)<br/>  }))</pre> | `{}` | no |
| <a name="input_local_users"></a> [local\_users](#input\_local\_users) | Users with a password in the realm itself (CI and laptops), keyed by a short name: email, password, and the group paths they start in (e.g. "/lab/authors"). Their memberships are added, never removed, by tofu, so admins can change them at runtime. | <pre>map(object({<br/>    email      = string<br/>    password   = string<br/>    first_name = optional(string, "")<br/>    last_name  = optional(string, "")<br/>    groups     = optional(list(string), [])<br/>  }))</pre> | `{}` | no |
| <a name="input_realm"></a> [realm](#input\_realm) | Realm name; the issuer Dex brokers is <keycloak\_base\_url>/realms/<realm> | `string` | `"lab"` | no |
| <a name="input_smtp"></a> [smtp](#input\_smtp) | Outgoing mail for the realm (address verification, verify\_email). username empty: no SMTP authentication; otherwise smtp\_password is its password. | <pre>object({<br/>    host              = string<br/>    port              = optional(number, 587)<br/>    from              = string<br/>    from_display_name = optional(string, "")<br/>    reply_to          = optional(string, "")<br/>    starttls          = optional(bool, true)<br/>    ssl               = optional(bool, false)<br/>    username          = optional(string, "")<br/>  })</pre> | `null` | no |
| <a name="input_smtp_password"></a> [smtp\_password](#input\_smtp\_password) | Password for smtp.username | `string` | `""` | no |
| <a name="input_ssl_required"></a> [ssl\_required](#input\_ssl\_required) | "external" (HTTPS except from private addresses), "all", or "none" (kind over plain http) | `string` | `"external"` | no |
| <a name="input_sso_session_idle_timeout"></a> [sso\_session\_idle\_timeout](#input\_sso\_session\_idle\_timeout) | How long a realm login lasts unused (Keycloak's SSO Session Idle; its default is 30m). Dex's refresh tokens from the realm end with it, and relying parties refresh through Dex (oauth2-proxy every auth.session\_refresh, 1h by default; JupyterHub before spawns), so keep it above the longest refresh interval or users are sent back to log in. | `string` | `"4h"` | no |
| <a name="input_sso_session_max_lifespan"></a> [sso\_session\_max\_lifespan](#input\_sso\_session\_max\_lifespan) | The longest a realm login lasts however much it is used (SSO Session Max): after it, refreshes fail and users log in again. Match the relying parties' own caps (oauth2-proxy's session\_lifetime, JupyterHub's cookie, both a day by default). | `string` | `"24h"` | no |
| <a name="input_superadmins"></a> [superadmins](#input\_superadmins) | Emails of the platform's superadmins: members of /platform-admins (realm-admin), authoritative here. Each is pre-created so a brokered login with that verified email links to it. | `list(string)` | `[]` | no |
| <a name="input_tenants"></a> [tenants](#input\_tenants) | The platform's tenants (the same map modules/tenancy takes; only the<br/>group names are read here). Each tenant is a top-level group /<tenant><br/>with an /<tenant>/admins group; each of its groups is /<tenant>/<group><br/>with /<tenant>/<group>/admins. Tokens carry these full paths. Slugs are<br/>^[a-z]([a-z0-9\_]{0,19}[a-z0-9])?$ without "\_\_" (they become Postgres role<br/>names nb\_<tenant>\_\_<group>); "admins" is reserved. | <pre>map(object({<br/>    groups = optional(map(object({})), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_verify_email"></a> [verify\_email](#input\_verify\_email) | Make users with an unverified email -- those from an identity provider without trust\_email -- verify it by mail before their login completes. Needs smtp. | `bool` | `false` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_admin_groups"></a> [admin\_groups](#output\_admin\_groups) | Per tenant, the admin group paths: the tenant's own and each group's |
| <a name="output_dex_connector"></a> [dex\_connector](#output\_dex\_connector) | A Dex connector for this realm (modules/dex connectors); its secret is $KEYCLOAK\_CLIENT\_SECRET, supplied by dex\_connector\_env |
| <a name="output_dex_connector_env"></a> [dex\_connector\_env](#output\_dex\_connector\_env) | Environment for Dex's $VAR expansion (modules/dex connector\_env) |
| <a name="output_group_ids"></a> [group\_ids](#output\_group\_ids) | Group path => Keycloak group id |
| <a name="output_group_paths"></a> [group\_paths](#output\_group\_paths) | Every group path the realm defines |
| <a name="output_issuer_url"></a> [issuer\_url](#output\_issuer\_url) | The realm's OIDC issuer (what Dex's connector trusts) |
| <a name="output_realm"></a> [realm](#output\_realm) | The realm's name |
| <a name="output_superadmin_group"></a> [superadmin\_group](#output\_superadmin\_group) | The superadmins' group path (modules/workloads auth.superadmin\_group) |
| <a name="output_tailscale_acl_groups"></a> [tailscale\_acl\_groups](#output\_tailscale\_acl\_groups) | Tailscale ACL groups mirroring the realm's superadmins, for the tailnet policy file |
<!-- END_TF_DOCS -->
