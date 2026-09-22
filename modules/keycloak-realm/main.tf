# ------------------------------------------------------------------------------
# KEYCLOAK REALM - tenants, admins, and the Dex client
#
#   /platform-admins                  superadmins: realm-admin; membership is
#                                     authoritative here (repo access = power)
#   /<tenant>                         a tenant
#   /<tenant>/admins                  manage the tenant's members (accounts and
#                                     memberships of all its groups)
#   /<tenant>/<group>                 a group; tokens carry this full path
#   /<tenant>/<group>/admins          manage that group's members
#
# IaC owns the structure and who administers what; memberships below the
# admins are runtime state that admins change in the console (or API).
# Delegation is fine-grained admin permissions v2: a group policy per admin
# group on the realm's admin-permissions client, a group permission per
# scope level, and one realm-wide users permission. Nothing targets
# /platform-admins or another tenant's groups.
# ------------------------------------------------------------------------------

locals {
  identity_providers = nonsensitive(var.identity_providers)
  local_users        = nonsensitive({ for k, u in var.local_users : k => { email = lower(u.email), first_name = u.first_name, last_name = u.last_name, groups = u.groups } })

  tenant_groups = merge([
    for t, v in var.tenants : { for g in keys(v.groups) : "${t}/${g}" => { tenant = t, group = g } }
  ]...)

  issuer_url = "${var.keycloak_base_url}/realms/${var.realm}"

  # Every path the realm defines, to ids (for local users' starting groups).
  group_ids_by_path = merge(
    { "/platform-admins" = keycloak_group.platform_admins.id },
    { for t in keys(var.tenants) : "/${t}" => keycloak_group.tenant[t].id },
    { for t in keys(var.tenants) : "/${t}/admins" => keycloak_group.tenant_admins[t].id },
    { for k in keys(local.tenant_groups) : "/${k}" => keycloak_group.group[k].id },
    { for k in keys(local.tenant_groups) : "/${k}/admins" => keycloak_group.group_admins[k].id },
  )

  # What each permission targets, by path (resolved to ids below): the tenant
  # permission the tenant's own two groups (its member scopes cascade to the
  # tenant's groups), a group permission that group and its admins group.
  # Never /platform-admins, never another tenant.
  tenant_admin_targets = { for t in keys(var.tenants) : t => ["/${t}", "/${t}/admins"] }
  group_admin_targets  = { for k in keys(local.tenant_groups) : k => ["/${k}", "/${k}/admins"] }

  superadmins = [for e in var.superadmins : lower(e)]
  # Superadmins without a local user are pre-created (no credential) so a
  # brokered login links to them; a local user with that email is the same
  # account.
  precreated_superadmins = toset([for e in local.superadmins : e if !contains([for u in values(local.local_users) : u.email], e)])
}

resource "keycloak_realm" "this" {
  realm        = var.realm
  enabled      = true
  display_name = var.display_name
  ssl_required = var.ssl_required

  login_with_email_allowed = true
  duplicate_emails_allowed = false
  registration_allowed     = false
  reset_password_allowed   = false

  # Fine-grained admin permissions v2 (creates the admin-permissions client).
  admin_permissions_enabled = true

  # Dex's refresh tokens from this realm are online ones: they end with the
  # SSO session, and every relying party's refresh goes through them.
  sso_session_idle_timeout = var.sso_session_idle_timeout
  sso_session_max_lifespan = var.sso_session_max_lifespan

  verify_email = var.verify_email

  dynamic "smtp_server" {
    for_each = var.smtp != null ? [var.smtp] : []
    content {
      host              = smtp_server.value.host
      port              = tostring(smtp_server.value.port)
      from              = smtp_server.value.from
      from_display_name = smtp_server.value.from_display_name
      reply_to          = smtp_server.value.reply_to
      starttls          = smtp_server.value.starttls
      ssl               = smtp_server.value.ssl

      dynamic "auth" {
        for_each = smtp_server.value.username != "" ? [1] : []
        content {
          username = smtp_server.value.username
          password = var.smtp_password
        }
      }
    }
  }

  dynamic "security_defenses" {
    for_each = var.brute_force_detection.enabled ? [var.brute_force_detection] : []
    content {
      brute_force_detection {
        permanent_lockout          = false
        max_login_failures         = security_defenses.value.max_login_failures
        wait_increment_seconds     = security_defenses.value.wait_increment_seconds
        max_failure_wait_seconds   = security_defenses.value.max_failure_wait_seconds
        failure_reset_time_seconds = security_defenses.value.failure_reset_seconds
      }
    }
  }
}

# Keycloak's user profile requires first and last name, and "Verify Profile"
# stops a login until they are filled in. Names come from the upstream IdP
# (or tofu for local users); a platform login is not the place to ask.
resource "keycloak_required_action" "verify_profile" {
  realm_id = keycloak_realm.this.id
  alias    = "VERIFY_PROFILE"
  name     = "Verify Profile"
  enabled  = false
}

# ------------------------------------------------------------------------------
# Groups
# ------------------------------------------------------------------------------

resource "keycloak_group" "platform_admins" {
  realm_id = keycloak_realm.this.id
  name     = "platform-admins"
}

resource "keycloak_group" "tenant" {
  for_each = var.tenants

  realm_id = keycloak_realm.this.id
  name     = each.key
}

resource "keycloak_group" "tenant_admins" {
  for_each = var.tenants

  realm_id  = keycloak_realm.this.id
  parent_id = keycloak_group.tenant[each.key].id
  name      = "admins"
}

resource "keycloak_group" "group" {
  for_each = local.tenant_groups

  realm_id  = keycloak_realm.this.id
  parent_id = keycloak_group.tenant[each.value.tenant].id
  name      = each.value.group
}

resource "keycloak_group" "group_admins" {
  for_each = local.tenant_groups

  realm_id  = keycloak_realm.this.id
  parent_id = keycloak_group.group[each.key].id
  name      = "admins"
}

# ------------------------------------------------------------------------------
# Superadmins
# ------------------------------------------------------------------------------

data "keycloak_openid_client" "realm_management" {
  realm_id  = keycloak_realm.this.id
  client_id = "realm-management"
}

data "keycloak_role" "realm_admin" {
  realm_id  = keycloak_realm.this.id
  client_id = data.keycloak_openid_client.realm_management.id
  name      = "realm-admin"
}

resource "keycloak_group_roles" "platform_admins" {
  realm_id = keycloak_realm.this.id
  group_id = keycloak_group.platform_admins.id
  role_ids = [data.keycloak_role.realm_admin.id]
}

resource "keycloak_user" "superadmin" {
  for_each = local.precreated_superadmins

  realm_id       = keycloak_realm.this.id
  username       = each.key
  email          = each.key
  email_verified = true
  enabled        = true
}

resource "keycloak_group_memberships" "platform_admins" {
  realm_id = keycloak_realm.this.id
  group_id = keycloak_group.platform_admins.id
  members  = local.superadmins

  depends_on = [keycloak_user.superadmin, keycloak_user.local]
}

# ------------------------------------------------------------------------------
# Delegated admins (fine-grained admin permissions v2)
# ------------------------------------------------------------------------------

data "keycloak_openid_client" "admin_permissions" {
  realm_id  = keycloak_realm.this.id
  client_id = "admin-permissions"

  depends_on = [keycloak_realm.this]
}

resource "keycloak_openid_client_group_policy" "tenant_admins" {
  for_each = var.tenants

  realm_id           = keycloak_realm.this.id
  resource_server_id = data.keycloak_openid_client.admin_permissions.id
  name               = "tenant-${each.key}-admins"
  logic              = "POSITIVE"
  decision_strategy  = "UNANIMOUS"

  groups {
    id              = keycloak_group.tenant_admins[each.key].id
    path            = "/${each.key}/admins"
    extend_children = false
  }
}

# A group's administrators: its own admins group OR its tenant's (a group
# policy grants on membership of any of its groups).
resource "keycloak_openid_client_group_policy" "group_admins" {
  for_each = local.tenant_groups

  realm_id           = keycloak_realm.this.id
  resource_server_id = data.keycloak_openid_client.admin_permissions.id
  name               = "group-${each.value.tenant}-${each.value.group}-admins"
  logic              = "POSITIVE"
  decision_strategy  = "UNANIMOUS"

  # Sorted by id: Keycloak returns a policy's groups ordered by id, and a
  # different order here would be a change on every plan.
  dynamic "groups" {
    for_each = sort([
      "${keycloak_group.group_admins[each.key].id}|/${each.key}/admins",
      "${keycloak_group.tenant_admins[each.value.tenant].id}|/${each.value.tenant}/admins",
    ])
    content {
      id              = split("|", groups.value)[0]
      path            = split("|", groups.value)[1]
      extend_children = false
    }
  }
}

# Keycloak grants only when EVERY permission covering a resource grants, so
# no two permissions cover the same group with different policies:
#
#   tenant-<t>        /<t>, /<t>/admins: view, view-members, manage-members,
#                     manage-membership -- tenant admins. The member scopes
#                     cascade to every group of the tenant.
#   group-<t>-<g>     /<t>/<g>, /<t>/<g>/admins: view, view-members,
#                     manage-membership -- the group's admins OR the tenant's
#                     (one permission, one policy naming both groups).
#
# Nobody gets `manage` (create, rename, move, delete groups): Keycloak gives a
# group created at runtime no permissions (keycloak/keycloak#29100), so its
# creator could not manage its members, and an all-groups fallback would reach
# across tenants. Group structure is the tenants map's, changed by a PR.
resource "keycloak_group_admin_permissions" "tenant" {
  for_each = var.tenants

  realm_id  = keycloak_realm.this.id
  name      = "tenant-${each.key}"
  group_ids = [for path in local.tenant_admin_targets[each.key] : local.group_ids_by_path[path]]
  scopes    = ["view", "view-members", "manage-members", "manage-membership"]
  policies  = [keycloak_openid_client_group_policy.tenant_admins[each.key].id]
}

resource "keycloak_group_admin_permissions" "group" {
  for_each = local.tenant_groups

  realm_id  = keycloak_realm.this.id
  name      = "group-${each.value.tenant}-${each.value.group}"
  group_ids = [for path in local.group_admin_targets[each.key] : local.group_ids_by_path[path]]
  scopes    = ["view", "view-members", "manage-membership"]
  policies  = [keycloak_openid_client_group_policy.group_admins[each.key].id]

  # Keycloak registers a group as an authorization resource the first time a
  # permission names it; permissions created at the same moment collide
  # (409 Duplicate resource).
  depends_on = [keycloak_group_admin_permissions.tenant]
}

# Adding a user to a group needs manage-group-membership on the user (always
# realm-wide in v2) AND manage-membership on the group (fenced above).
resource "keycloak_openid_client_group_policy" "all_admins" {
  count = length(var.tenants) > 0 ? 1 : 0

  realm_id           = keycloak_realm.this.id
  resource_server_id = data.keycloak_openid_client.admin_permissions.id
  name               = "tenant-and-group-admins"
  logic              = "POSITIVE"
  decision_strategy  = "AFFIRMATIVE"

  # Sorted by id, as in group_admins.
  dynamic "groups" {
    for_each = sort(concat(
      [for t in keys(var.tenants) : "${keycloak_group.tenant_admins[t].id}|/${t}/admins"],
      [for k in keys(local.tenant_groups) : "${keycloak_group.group_admins[k].id}|/${k}/admins"],
    ))
    content {
      id              = split("|", groups.value)[0]
      path            = split("|", groups.value)[1]
      extend_children = false
    }
  }
}

resource "keycloak_users_admin_permissions" "admins" {
  count = length(var.tenants) > 0 ? 1 : 0

  realm_id = keycloak_realm.this.id
  name     = "tenant-and-group-admins-users"
  scopes   = var.admins_can_view_all_users ? ["view", "manage-group-membership"] : ["manage-group-membership"]
  policies = [keycloak_openid_client_group_policy.all_admins[0].id]
}

# Admins use the console (or the admin API) to search: the query roles only
# open the search; what they see and change is the permissions above.
data "keycloak_role" "query" {
  for_each = toset(["query-users", "query-groups"])

  realm_id  = keycloak_realm.this.id
  client_id = data.keycloak_openid_client.realm_management.id
  name      = each.key
}

resource "keycloak_group_roles" "tenant_admins" {
  for_each = var.tenants

  realm_id = keycloak_realm.this.id
  group_id = keycloak_group.tenant_admins[each.key].id
  role_ids = [for r in data.keycloak_role.query : r.id]
}

resource "keycloak_group_roles" "group_admins" {
  for_each = local.tenant_groups

  realm_id = keycloak_realm.this.id
  group_id = keycloak_group.group_admins[each.key].id
  role_ids = [for r in data.keycloak_role.query : r.id]
}

# ------------------------------------------------------------------------------
# The Dex client: full-path groups in the tokens
# ------------------------------------------------------------------------------

resource "keycloak_openid_client_scope" "groups" {
  realm_id               = keycloak_realm.this.id
  name                   = "groups"
  description            = "Group memberships as full paths (/tenant/group)"
  include_in_token_scope = true
}

resource "keycloak_openid_group_membership_protocol_mapper" "groups" {
  realm_id        = keycloak_realm.this.id
  client_scope_id = keycloak_openid_client_scope.groups.id
  name            = "groups"
  claim_name      = "groups"
  full_path       = true

  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

resource "random_password" "dex_client" {
  length  = 40
  special = false
}

resource "keycloak_openid_client" "dex" {
  realm_id  = keycloak_realm.this.id
  client_id = var.dex_client_id
  name      = "Dex (the platform's issuer)"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  client_secret         = random_password.dex_client.result
  standard_flow_enabled = true
  valid_redirect_uris   = [var.dex_redirect_uri]
}

resource "keycloak_openid_client_default_scopes" "dex" {
  realm_id  = keycloak_realm.this.id
  client_id = keycloak_openid_client.dex.id
  # "basic" carries sub; the rest are Keycloak's defaults plus groups.
  default_scopes = ["basic", "profile", "email", "roles", "web-origins", "acr", keycloak_openid_client_scope.groups.name]
}

# ------------------------------------------------------------------------------
# Upstream identity providers. Linking a first login to an existing user by
# email is opt-in per provider (link_existing_by_email), and only on a
# trusted email: the linked account is whoever the provider says it is.
# ------------------------------------------------------------------------------

resource "keycloak_authentication_flow" "link_by_email" {
  count = local.link_by_mail ? 1 : 0

  realm_id    = keycloak_realm.this.id
  alias       = "first-broker-login-link-by-email"
  description = "First brokered login: create the user if the email is new, otherwise link to the existing user"
}

resource "keycloak_authentication_execution" "create_if_unique" {
  count = local.link_by_mail ? 1 : 0

  realm_id          = keycloak_realm.this.id
  parent_flow_alias = keycloak_authentication_flow.link_by_email[0].alias
  authenticator     = "idp-create-user-if-unique"
  requirement       = "ALTERNATIVE"
  priority          = 10
}

resource "keycloak_authentication_execution" "auto_link" {
  count = local.link_by_mail ? 1 : 0

  realm_id          = keycloak_realm.this.id
  parent_flow_alias = keycloak_authentication_flow.link_by_email[0].alias
  authenticator     = "idp-auto-link"
  requirement       = "ALTERNATIVE"
  priority          = 20

  depends_on = [keycloak_authentication_execution.create_if_unique]
}

locals {
  first_broker_flow = { for k, p in local.identity_providers : k => p.link_existing_by_email ? keycloak_authentication_flow.link_by_email[0].alias : "first broker login" }
  # Google and GitHub verify the emails they assert; a generic issuer must be
  # vouched for explicitly.
  trust_email  = { for k, p in local.identity_providers : k => coalesce(p.trust_email, p.type != "oidc") }
  link_by_mail = anytrue([for p in values(local.identity_providers) : p.link_existing_by_email])
}

resource "keycloak_oidc_google_identity_provider" "this" {
  for_each = { for k, p in local.identity_providers : k => p if p.type == "google" }

  realm                         = keycloak_realm.this.id
  alias                         = each.key
  display_name                  = coalesce(each.value.display_name, "Google")
  client_id                     = each.value.client_id
  client_secret                 = var.identity_providers[each.key].client_secret
  hosted_domain                 = each.value.hosted_domain
  trust_email                   = local.trust_email[each.key]
  sync_mode                     = "IMPORT"
  first_broker_login_flow_alias = local.first_broker_flow[each.key]
}

resource "keycloak_oidc_github_identity_provider" "this" {
  for_each = { for k, p in local.identity_providers : k => p if p.type == "github" }

  realm                         = keycloak_realm.this.id
  alias                         = each.key
  display_name                  = coalesce(each.value.display_name, "GitHub")
  client_id                     = each.value.client_id
  client_secret                 = var.identity_providers[each.key].client_secret
  trust_email                   = local.trust_email[each.key]
  sync_mode                     = "IMPORT"
  first_broker_login_flow_alias = local.first_broker_flow[each.key]
}

resource "keycloak_oidc_identity_provider" "this" {
  for_each = { for k, p in local.identity_providers : k => p if p.type == "oidc" }

  realm                         = keycloak_realm.this.id
  alias                         = each.key
  display_name                  = coalesce(each.value.display_name, each.key)
  client_id                     = each.value.client_id
  client_secret                 = var.identity_providers[each.key].client_secret
  authorization_url             = each.value.authorization_url
  token_url                     = each.value.token_url
  issuer                        = each.value.issuer
  jwks_url                      = each.value.jwks_url
  validate_signature            = true
  default_scopes                = each.value.default_scopes
  trust_email                   = local.trust_email[each.key]
  sync_mode                     = "IMPORT"
  first_broker_login_flow_alias = local.first_broker_flow[each.key]
}

# ------------------------------------------------------------------------------
# Local users (CI, laptops)
# ------------------------------------------------------------------------------

resource "keycloak_user" "local" {
  for_each = local.local_users

  realm_id       = keycloak_realm.this.id
  username       = each.value.email
  email          = each.value.email
  email_verified = true
  enabled        = true
  first_name     = each.value.first_name
  last_name      = each.value.last_name

  initial_password {
    value     = var.local_users[each.key].password
    temporary = false
  }
}

resource "keycloak_user_groups" "local" {
  for_each = { for k, u in local.local_users : k => u if length([for g in u.groups : g if g != "/platform-admins"]) > 0 }

  realm_id = keycloak_realm.this.id
  user_id  = keycloak_user.local[each.key].id
  # /platform-admins is keycloak_group_memberships' (authoritative) business.
  group_ids  = [for g in each.value.groups : local.group_ids_by_path[g] if g != "/platform-admins"]
  exhaustive = false

  lifecycle {
    precondition {
      condition     = alltrue([for g in each.value.groups : contains(keys(local.group_ids_by_path), g)])
      error_message = "local_users.${each.key}.groups names a group the realm does not define: ${join(", ", [for g in each.value.groups : g if !contains(keys(local.group_ids_by_path), g)])}."
    }
  }
}
