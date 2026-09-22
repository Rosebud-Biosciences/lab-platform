# Mocked apply (not plan) so every group gets a distinct id and the tests can
# prove which groups each permission targets.
mock_provider "keycloak" {
  mock_data "keycloak_openid_client" {
    defaults = { id = "mock-client" }
  }
  mock_data "keycloak_role" {
    defaults = { id = "mock-role" }
  }
}
mock_provider "random" {}

variables {
  keycloak_base_url = "https://id.example.com"
  dex_redirect_uri  = "https://dex.example.com/dex/callback"
  tenants = {
    lab  = { trust = "internal", groups = { authors = {}, pipelines = {} } }
    acme = { trust = "external", groups = { research = {} } }
  }
  superadmins = ["Sam@lab.org", "root@lab.org"]
  local_users = {
    sam = { email = "sam@lab.org", password = "pw", groups = ["/platform-admins"] }
    ann = { email = "ann@lab.org", password = "pw", groups = ["/lab/authors"] }
    bob = { email = "bob@lab.org", password = "pw" }
  }
}

run "tenant_tree" {
  command = apply

  assert {
    condition     = length(keycloak_group.tenant) == 2 && length(keycloak_group.tenant_admins) == 2 && length(keycloak_group.group) == 3 && length(keycloak_group.group_admins) == 3
    error_message = "one group and one admins group per tenant and per tenant group"
  }
  assert {
    condition     = output.group_paths == tolist(["/acme", "/acme/admins", "/acme/research", "/acme/research/admins", "/lab", "/lab/admins", "/lab/authors", "/lab/authors/admins", "/lab/pipelines", "/lab/pipelines/admins", "/platform-admins"])
    error_message = "full paths for the whole tree"
  }
  assert {
    condition     = keycloak_group.group["lab/authors"].parent_id == keycloak_group.tenant["lab"].id && keycloak_group.group_admins["lab/authors"].parent_id == keycloak_group.group["lab/authors"].id
    error_message = "groups nest under their tenant, admins under their group"
  }
}

run "delegation_is_fenced" {
  command = plan

  assert {
    condition     = local.tenant_admin_targets["lab"] == ["/lab", "/lab/admins"] && toset(keycloak_group_admin_permissions.tenant["lab"].scopes) == toset(["view", "view-members", "manage-members", "manage-membership"])
    error_message = "a tenant's admins hold the tenant's own groups; the member scopes cascade to its groups"
  }
  assert {
    condition     = alltrue([for t, paths in local.tenant_admin_targets : alltrue([for p in paths : startswith(p, "/${t}/") || p == "/${t}"])]) && alltrue([for k, paths in local.group_admin_targets : alltrue([for p in paths : startswith(p, "/${k}")])])
    error_message = "nothing targets /platform-admins or another tenant"
  }
  assert {
    condition     = local.group_admin_targets["lab/authors"] == ["/lab/authors", "/lab/authors/admins"] && toset(keycloak_group_admin_permissions.group["lab/authors"].scopes) == toset(["view", "view-members", "manage-membership"])
    error_message = "a group's admins change who is in their group (and its admins), nothing else"
  }
  assert {
    condition     = toset([for g in keycloak_openid_client_group_policy.group_admins["lab/authors"].groups : g.path]) == toset(["/lab/authors/admins", "/lab/admins"]) && keycloak_group_admin_permissions.group["lab/authors"].policies == toset([keycloak_openid_client_group_policy.group_admins["lab/authors"].id])
    error_message = "one permission per group whose one policy admits the group's admins or the tenant's: Keycloak denies when any covering permission denies"
  }
  assert {
    condition     = !anytrue([for p in values(keycloak_group_admin_permissions.tenant) : contains(p.scopes, "manage")]) && !anytrue([for p in values(keycloak_group_admin_permissions.group) : contains(p.scopes, "manage")])
    error_message = "nobody creates or reshapes groups at runtime: structure is the tenants map's"
  }
  assert {
    condition     = toset(keycloak_users_admin_permissions.admins[0].scopes) == toset(["view", "manage-group-membership"])
    error_message = "admins look users up and change memberships realm-wide; the group permissions fence which groups"
  }
  assert {
    condition     = [for g in keycloak_openid_client_group_policy.tenant_admins["lab"].groups : g.path] == ["/lab/admins"] && length(keycloak_openid_client_group_policy.all_admins[0].groups) == 5
    error_message = "each policy is its admin group, without children; one policy spans every admin group for the users permission"
  }
}

run "superadmins" {
  command = apply

  assert {
    condition     = keys(keycloak_user.superadmin) == ["root@lab.org"]
    error_message = "superadmins without a local user are pre-created (lowercased); a local user with the email is the same account"
  }
  assert {
    condition     = toset(keycloak_group_memberships.platform_admins.members) == toset(["sam@lab.org", "root@lab.org"]) && keycloak_group_roles.platform_admins.role_ids == toset(["mock-role"])
    error_message = "/platform-admins membership is authoritative and carries realm-admin"
  }
  assert {
    condition     = keys(keycloak_user_groups.local) == ["ann"] && keycloak_user_groups.local["ann"].exhaustive == false
    error_message = "local users start in their groups; tofu adds, never removes (admins change them at runtime)"
  }
  assert {
    condition     = output.tailscale_acl_groups == { "group:platform" = ["sam@lab.org", "root@lab.org"] }
    error_message = "the superadmins are mirrored for the tailnet ACL"
  }
}

run "dex_client_and_connector" {
  command = apply

  assert {
    condition     = keycloak_openid_group_membership_protocol_mapper.groups.full_path && contains(keycloak_openid_client_default_scopes.dex.default_scopes, "groups") && contains(keycloak_openid_client_default_scopes.dex.default_scopes, "basic")
    error_message = "Dex's tokens carry full-path groups (and sub, from the basic scope)"
  }
  assert {
    condition     = output.dex_connector.config.issuer == "https://id.example.com/realms/lab" && output.dex_connector.config.clientSecret == "$KEYCLOAK_CLIENT_SECRET" && output.dex_connector.config.insecureEnableGroups
    error_message = "a Dex oidc connector with its secret by reference"
  }
  assert {
    condition     = keycloak_openid_client.dex.valid_redirect_uris == toset(["https://dex.example.com/dex/callback"]) && keycloak_openid_client.dex.access_type == "CONFIDENTIAL"
    error_message = "a confidential client redirecting only to Dex"
  }
  assert {
    condition     = length(keycloak_authentication_flow.link_by_email) == 0
    error_message = "no brokering flow without identity providers"
  }
}

run "identity_providers_link_only_when_asked" {
  command = apply

  variables {
    identity_providers = {
      google = { type = "google", client_id = "g", client_secret = "gs", hosted_domain = "lab.org", link_existing_by_email = true }
      github = { type = "github", client_id = "h", client_secret = "hs" }
      partner = {
        type              = "oidc"
        client_id         = "p"
        client_secret     = "ps"
        authorization_url = "https://idp.partner.example/auth"
        token_url         = "https://idp.partner.example/token"
        issuer            = "https://idp.partner.example"
        jwks_url          = "https://idp.partner.example/jwks"
      }
    }
  }

  assert {
    condition     = keycloak_oidc_google_identity_provider.this["google"].first_broker_login_flow_alias == "first-broker-login-link-by-email" && keycloak_oidc_google_identity_provider.this["google"].trust_email
    error_message = "a provider that opts in (your Workspace's Google) links a first login to an existing user by email"
  }
  assert {
    condition     = keycloak_oidc_github_identity_provider.this["github"].first_broker_login_flow_alias == "first broker login" && keycloak_oidc_identity_provider.this["partner"].first_broker_login_flow_alias == "first broker login"
    error_message = "linking is off unless a provider asks for it"
  }
  assert {
    condition     = !keycloak_oidc_identity_provider.this["partner"].trust_email && keycloak_oidc_identity_provider.this["partner"].validate_signature
    error_message = "a generic issuer's emails are not trusted by default, and its tokens are always signature-checked"
  }
}

run "no_link_flow_when_nobody_links" {
  command = apply

  variables {
    identity_providers = { github = { type = "github", client_id = "h", client_secret = "hs" } }
  }

  assert {
    condition     = length(keycloak_authentication_flow.link_by_email) == 0
    error_message = "the auto-link flow exists only when a provider opts in"
  }
}

run "oidc_without_issuer_or_keys_is_refused" {
  command = plan

  variables {
    identity_providers = {
      partner = { type = "oidc", client_id = "p", client_secret = "ps", authorization_url = "https://x/auth", token_url = "https://x/token" }
    }
  }

  expect_failures = [var.identity_providers]
}

run "linking_on_an_untrusted_email_is_refused" {
  command = plan

  variables {
    identity_providers = {
      partner = {
        type                   = "oidc"
        client_id              = "p"
        client_secret          = "ps"
        authorization_url      = "https://x/auth"
        token_url              = "https://x/token"
        issuer                 = "https://x"
        jwks_url               = "https://x/jwks"
        link_existing_by_email = true
      }
    }
  }

  expect_failures = [var.identity_providers]
}

run "brute_force_protection_on" {
  command = plan

  assert {
    condition     = keycloak_realm.this.security_defenses[0].brute_force_detection[0].max_login_failures == 10 && !keycloak_realm.this.security_defenses[0].brute_force_detection[0].permanent_lockout
    error_message = "repeated password failures lock an account out for a while"
  }
}

run "reserved_and_ambiguous_slugs_are_refused" {
  command = plan

  variables {
    tenants = { lab = { groups = { admins = {} } }, "a__b" = { groups = {} } }
  }

  expect_failures = [var.tenants]
}

run "unknown_starting_group_is_refused" {
  command = plan

  variables {
    local_users = { eve = { email = "eve@lab.org", password = "pw", groups = ["/lab/nope"] } }
  }

  expect_failures = [keycloak_user_groups.local]
}

run "trailing_underscore_is_refused" {
  command = plan

  # nb_lab___authors would read back as /lab/_authors.
  variables {
    tenants = { "lab_" = { groups = { authors = {} } } }
  }

  expect_failures = [var.tenants]
}

run "sessions_outlast_the_refresh_interval" {
  command = plan

  assert {
    condition     = keycloak_realm.this.sso_session_idle_timeout == "4h" && keycloak_realm.this.sso_session_max_lifespan == "24h"
    error_message = "a realm login outlives oauth2-proxy's hourly refresh (Keycloak's 30m default would not) and lasts a day"
  }
  assert {
    condition     = !keycloak_realm.this.verify_email && length(keycloak_realm.this.smtp_server) == 0
    error_message = "no mail unless smtp is given"
  }
}

run "smtp_and_email_verification" {
  command = plan

  variables {
    smtp          = { host = "smtp.example.com", from = "id@example.com", username = "id" }
    smtp_password = "pw"
    verify_email  = true
  }

  assert {
    condition     = keycloak_realm.this.verify_email && keycloak_realm.this.smtp_server[0].port == "587" && keycloak_realm.this.smtp_server[0].starttls && keycloak_realm.this.smtp_server[0].auth[0].username == "id"
    error_message = "verification mail goes out through the given server"
  }
}

run "verify_email_needs_smtp" {
  command = plan

  variables {
    verify_email = true
  }

  expect_failures = [var.verify_email]
}
