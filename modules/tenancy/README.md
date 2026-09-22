# tenancy

Which tenant runs where, validated. Pure computation: it takes the tenants
map, checks it against what each service can isolate (external tenants may
only share the webapp, JupyterHub and MLflow on OIDC; the plan fails
otherwise), and returns the inputs that realise it:

- `realm_tenants` for [`modules/keycloak-realm`](../keycloak-realm);
- `shared`: gates, code locations, notebook profiles, MLflow groups, rules
  and service accounts, and the data groups, for the platform's shared
  [`modules/workloads`](../workloads) instance;
- `stamps`: per tenant with an isolated service, the spec of its own
  `modules/workloads` stamp (prefix, services, gates, Argo rules, a fence to
  the tenant, identity, MLflow account), which the caller instantiates with
  `for_each`.

The model, the capability table and a wiring example are in
[docs/tenancy.md](../../docs/tenancy.md); [`examples/kind`](../../examples/kind)
runs it.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_tenants"></a> [tenants](#input\_tenants) | The platform's tenants. Per tenant:<br/>  trust     "internal" (the lab's own teams) or "external" (another<br/>            organization): external tenants may only share a service<br/>            that isolates tenants inside one instance (webapp,<br/>            jupyterhub, mlflow); the plan fails otherwise.<br/>  groups    its groups (/<tenant>/<group>); data = false skips the group's<br/>            Postgres role.<br/>  services  per service "shared" (the platform's instance, isolated inside<br/>            where the service can), "isolated" (the tenant's own stamp)<br/>            or "off".<br/>  dagster\_image  the tenant's code: a code location in the shared<br/>            Dagster, or its stamp's user code (empty: the stamp's<br/>            hello-world location).<br/>  data      database: "shared" (the app database, RLS) \| "own\_database";<br/>            bucket: "shared\_prefix" (s3://<shared>/tenants/<tenant>/) \|<br/>            "own" -- consumed by aws/tenant-data. | <pre>map(object({<br/>    trust = optional(string, "internal")<br/>    groups = optional(map(object({<br/>      data = optional(bool, true)<br/>    })), {})<br/>    services = optional(object({<br/>      webapp     = optional(string, "shared")<br/>      jupyterhub = optional(string, "shared")<br/>      mlflow     = optional(string, "shared")<br/>      dagster    = optional(string, "shared")<br/>      ray        = optional(string, "off")<br/>      argo       = optional(string, "off")<br/>    }), {})<br/>    dagster_image = optional(string, "")<br/>    data = optional(object({<br/>      database = optional(string, "shared")<br/>      bucket   = optional(string, "shared_prefix")<br/>    }), {})<br/>  }))</pre> | n/a | yes |
| <a name="input_group_secret_env"></a> [group\_secret\_env](#input\_group\_secret\_env) | Per group path, extra secrets for its notebook profile (e.g. DATABASE\_URL from modules/postgres-group-roles credentials) | `map(map(string))` | `{}` | no |
| <a name="input_platform_mlflow_oidc"></a> [platform\_mlflow\_oidc](#input\_platform\_mlflow\_oidc) | Whether the shared MLflow runs its own OIDC (auth.mlflow\_mode = "oidc"): only then can external tenants share it (per-experiment permissions) and do tenants get MLflow service accounts | `bool` | `true` | no |
| <a name="input_platform_prefix"></a> [platform\_prefix](#input\_platform\_prefix) | name\_prefix of the platform's shared workloads instance (its namespaces are <prefix><service>) | `string` | `""` | no |
| <a name="input_stamp_prefix"></a> [stamp\_prefix](#input\_stamp\_prefix) | Format of a tenant stamp's name\_prefix (%s = tenant) | `string` | `"t-%s-"` | no |
| <a name="input_superadmin_group"></a> [superadmin\_group](#input\_superadmin\_group) | The superadmins' group (modules/keycloak-realm superadmin\_group); admitted everywhere | `string` | `"/platform-admins"` | no |
| <a name="input_tenant_identity"></a> [tenant\_identity](#input\_tenant\_identity) | Per tenant, the identity its compute runs with (aws/tenant-data's IRSA role annotations, or static keys on kind): service\_account\_annotations, env, secret\_env | <pre>map(object({<br/>    service_account_annotations = optional(map(string), {})<br/>    env                         = optional(map(string), {})<br/>    secret_env                  = optional(map(string), {})<br/>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_groups"></a> [groups](#output\_groups) | Per tenant: member and admin group paths |
| <a name="output_realm_tenants"></a> [realm\_tenants](#output\_realm\_tenants) | The tenants map as modules/keycloak-realm takes it |
| <a name="output_shared"></a> [shared](#output\_shared) | Inputs for the platform's shared workloads instance (merge with its own):<br/>dagster\_allowed\_groups / ray\_allowed\_groups (protect gates),<br/>dagster\_code\_locations, argo\_rbac\_rules, jupyterhub\_allowed\_groups,<br/>jupyterhub\_group\_profiles, mlflow\_groups, mlflow\_group\_rules,<br/>mlflow\_service\_accounts, and postgres\_data\_groups<br/>(modules/postgres-group-roles). |
| <a name="output_stamps"></a> [stamps](#output\_stamps) | Per tenant with an isolated service: the spec of its modules/workloads stamp (name\_prefix, which services, gates, Argo rules, network\_policies, identity, MLflow account) |
<!-- END_TF_DOCS -->
