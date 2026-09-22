output "realm" {
  description = "The realm's name"
  value       = keycloak_realm.this.realm
}

output "issuer_url" {
  description = "The realm's OIDC issuer (what Dex's connector trusts)"
  value       = local.issuer_url
}

output "dex_connector" {
  description = "A Dex connector for this realm (modules/dex connectors); its secret is $KEYCLOAK_CLIENT_SECRET, supplied by dex_connector_env"
  value = {
    type = "oidc"
    id   = "keycloak"
    name = var.connector_name
    config = {
      issuer       = local.issuer_url
      clientID     = keycloak_openid_client.dex.client_id
      clientSecret = "$KEYCLOAK_CLIENT_SECRET"
      redirectURI  = var.dex_redirect_uri
      scopes       = ["openid", "profile", "email", "groups"]
      # Keycloak's groups claim (full paths) becomes Dex's groups.
      insecureEnableGroups = true
      userNameKey          = "email"
      # Dex otherwise sends prompt=consent, which Keycloak honours with a
      # consent page on every login.
      promptType = ""
    }
  }
}

output "dex_connector_env" {
  description = "Environment for Dex's $VAR expansion (modules/dex connector_env)"
  value       = { KEYCLOAK_CLIENT_SECRET = random_password.dex_client.result }
  sensitive   = true
}

output "group_paths" {
  description = "Every group path the realm defines"
  value       = sort(keys(local.group_ids_by_path))
}

output "group_ids" {
  description = "Group path => Keycloak group id"
  value       = local.group_ids_by_path
}

output "admin_groups" {
  description = "Per tenant, the admin group paths: the tenant's own and each group's"
  value = {
    for t in keys(var.tenants) : t => concat(
      ["/${t}/admins"],
      [for k, v in local.tenant_groups : "/${k}/admins" if v.tenant == t],
    )
  }
}

output "superadmin_group" {
  description = "The superadmins' group path (modules/workloads auth.superadmin_group)"
  value       = "/platform-admins"
}

output "tailscale_acl_groups" {
  description = "Tailscale ACL groups mirroring the realm's superadmins, for the tailnet policy file"
  value       = { "group:platform" = local.superadmins }
}
