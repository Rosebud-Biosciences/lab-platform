# neon-branches

Copy-on-write [Neon](https://neon.tech) Postgres branches for one preview
environment — the database side of "branch prod for testing, off prod." Given
named sources (e.g. `app`, `dagster`, `mlflow`), it cuts child branches off
their parents (typically prod `main`) in seconds, creates an autoscaling
endpoint per branch, and exports ready-to-use connection details and
SQLAlchemy URLs **per source**. Branches and endpoints are deleted on
`tofu destroy`, so no preview writes persist.

A Neon branch snapshots a whole project, and its compute belongs to the
branch, so the module branches per **(project, parent branch)**, not per
database: sources that share a parent share one branch and one compute, each
with its own database URL, and get the same snapshot. That makes the two
common layouts cost what they should:

| Prod layout | Sources | Branches per preview |
| --- | --- | --- |
| One project per service (`app-db`, `dagster-db`, `mlflow-db`) | 3 in 3 projects | 3, named `<prefix>app`, `<prefix>dagster`, `<prefix>mlflow` |
| One project, many databases | 3 in 1 project | **1**, named `<prefix>app-dagster-mlflow`, serving all three |
| `data` + `orchestration` projects | 3 in 2 projects | 2 |

`branch_names` stays keyed by source (sources sharing a branch report the
same name); `branches` lists what was actually created and which sources each
serves.

Isolated in its own submodule so non-Neon users never have to configure the
provider — the documented fallback is an empty branched DB plus a migration
step, or an Aurora fast-clone.

```hcl
module "neon" {
  source = "github.com/Rosebud-Biosciences/lab-platform//modules/neon-branches?ref=main"

  name_prefix = "pr123"
  branch_sources = {
    app = {
      project_id       = "prod-app"
      parent_branch_id = "br-prod-main-0000"
      role_name        = "app"
      db_name          = "app"
    }
  }
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_neon"></a> [neon](#requirement\_neon) | >= 0.6.3 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_neon"></a> [neon](#provider\_neon) | >= 0.6.3 |

## Resources

| Name | Type |
|------|------|
| [neon_branch.this](https://registry.terraform.io/providers/kislerdm/neon/latest/docs/resources/branch) | resource |
| [neon_endpoint.this](https://registry.terraform.io/providers/kislerdm/neon/latest/docs/resources/endpoint) | resource |
| [neon_branch_role_password.this](https://registry.terraform.io/providers/kislerdm/neon/latest/docs/data-sources/branch_role_password) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Unique per-preview prefix (e.g. the PR/preview name). Prepended to each branch name so previews never collide. | `string` | n/a | yes |
| <a name="input_autoscaling_max_cu"></a> [autoscaling\_max\_cu](#input\_autoscaling\_max\_cu) | Maximum compute units for each branch endpoint | `number` | `2` | no |
| <a name="input_autoscaling_min_cu"></a> [autoscaling\_min\_cu](#input\_autoscaling\_min\_cu) | Minimum compute units for each branch endpoint | `number` | `0.25` | no |
| <a name="input_branch_sources"></a> [branch\_sources](#input\_branch\_sources) | Parent Neon branch identifiers to cut copy-on-write child branches from,<br/>keyed by an arbitrary logical name (e.g. "app", "dagster", "mlflow"). Each<br/>entry names the project, the parent branch, the role to read the password<br/>for, and the database. Typically populated from the production data-storage<br/>stack's remote-state outputs. | <pre>map(object({<br/>    project_id       = string<br/>    parent_branch_id = string<br/>    role_name        = string<br/>    db_name          = string<br/>  }))</pre> | `{}` | no |
| <a name="input_suspend_timeout_seconds"></a> [suspend\_timeout\_seconds](#input\_suspend\_timeout\_seconds) | Idle seconds before a branch endpoint auto-suspends | `number` | `300` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_branch_names"></a> [branch\_names](#output\_branch\_names) | Name of the ephemeral Neon branch serving each source, keyed by source name (sources sharing a parent share a branch) |
| <a name="output_branches"></a> [branches](#output\_branches) | The ephemeral branches actually created, one per distinct (project, parent branch): {project\_id, branch\_id, name, sources} |
| <a name="output_connections"></a> [connections](#output\_connections) | Per-source connection details (host, user, password, dbname), keyed by the logical source name |
| <a name="output_postgres_urls"></a> [postgres\_urls](#output\_postgres\_urls) | Per-source SQLAlchemy-style Postgres URLs, keyed by the logical source name |
<!-- END_TF_DOCS -->
