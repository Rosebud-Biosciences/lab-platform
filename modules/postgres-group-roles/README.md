# postgres-group-roles

One Postgres login role per data group, `nb_<tenant>__<group>`, for
notebooks (a JupyterHub group profile's `DATABASE_URL`) and tenant compute.
It owns nothing and is a member of `app_notebook` only, whose row-level
security policy (the template app's migration 0004) reads the group back out
of the name the role logged in with (`session_user`): the role sees its
group's rows and cannot widen that with a session setting -- nor with
`SET ROLE app_notebook`, which the provider's plain grant allows on
PostgreSQL 16+ (it cannot grant `WITH SET FALSE`) but which leaves
`session_user` alone. Any policy written against these roles must use
`session_user`, not `current_user`.

Created by SQL through the `cyrilgdn/postgresql` provider -- never Neon's role
API, whose roles may `SET ROLE neon_superuser` and so bypass row-level
security. The provider's role needs CREATEROLE (the database owner on Neon).

```hcl
module "group_roles" {
  source = "github.com/Rosebud-Biosciences/lab-platform//modules/postgres-group-roles?ref=v0.2.0"

  groups     = module.tenancy.shared.postgres_data_groups # ["/lab/authors", "/acme/research"]
  connection = { host = "ep-x.neon.tech", database = "app" }
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_postgresql"></a> [postgresql](#requirement\_postgresql) | >= 1.25 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.6 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_postgresql"></a> [postgresql](#provider\_postgresql) | >= 1.25 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.6 |

## Resources

| Name | Type |
|------|------|
| [postgresql_role.group](https://registry.terraform.io/providers/cyrilgdn/postgresql/latest/docs/resources/role) | resource |
| [random_password.role](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_connection"></a> [connection](#input\_connection) | Where the roles connect, for the URLs in the output (host, port, database, sslmode) | <pre>object({<br/>    host     = string<br/>    port     = optional(number, 5432)<br/>    database = string<br/>    sslmode  = optional(string, "require")<br/>  })</pre> | n/a | yes |
| <a name="input_connection_limit"></a> [connection\_limit](#input\_connection\_limit) | Connection limit per role (-1 = none) | `number` | `10` | no |
| <a name="input_groups"></a> [groups](#input\_groups) | Group paths (/<tenant>/<group>) that get a login role nb\_<tenant>\_\_<group>. The app's row-level security maps the role back to the path (app\_viewer\_groups() in the template's migration 0004). | `list(string)` | `[]` | no |
| <a name="input_member_of"></a> [member\_of](#input\_member\_of) | NOLOGIN roles every group role is granted (the app's app\_notebook, whose policies do the scoping) | `list(string)` | <pre>[<br/>  "app_notebook"<br/>]</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_credentials"></a> [credentials](#output\_credentials) | Group path => { username, password, url }, e.g. for a JupyterHub group profile's secret\_env (DATABASE\_URL) |
| <a name="output_roles"></a> [roles](#output\_roles) | Group path => role name |
<!-- END_TF_DOCS -->
