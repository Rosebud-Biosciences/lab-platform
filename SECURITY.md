# Security policy

## Reporting a vulnerability

Report it privately: this repository's **Security** tab, **Report a
vulnerability**. Only the maintainers can read the report. Please do not open
a public issue, pull request or discussion about it.

Fixes land on `main` and in the next release; only the latest release is
supported.

## Scope

In scope: anything in this repository that decides what a role, a pod or a
CI job can reach -- the modules under `modules/` and `aws/`, the examples, and
the reusable workflows in `.github/workflows/`.

Out of scope: vulnerabilities in the charts, images and providers the modules
install (report those upstream), and deployments that loosen the defaults.

## Known gaps in the defaults

These are known and documented, not vulnerabilities to report. They matter
most to anyone running the preview workflows, so read them before you adopt:

1. **A preview deploys as cluster-admin.** The preview role reaches the
   cluster through a cluster-admin access entry, because `modules/workloads`
   creates each environment's namespaces itself. Anyone who can push a branch
   to an app repository that runs the preview workflows can therefore change
   anything in the cluster through them, prod's namespaces included, and act
   as any prod ServiceAccount and the IAM role bound to it. The label check
   that starts a preview is in a workflow file the PR can edit. Grant write
   access to such a repository as you would grant cluster-admin.
2. **The preview permissions boundary caps actions, not resources.**
   `aws/bootstrap`'s boundary keeps every `/preview/` role away from IAM, STS,
   compute and the Terraform state bucket, but `preview_boundary_resources`
   defaults to `["*"]`: a PR can create a `/preview/` role, with a trust
   policy of its choosing, that reads, writes or deletes objects in any bucket
   in the account. Set `preview_boundary_resources` to the buckets, table
   buckets, KMS keys and ECR repositories previews actually use.

By design, `tether` mode lets a preview's pods write into production stores
(never delete): opt in only where the PR's code is trusted with that.

[docs/preview-environments.md](docs/preview-environments.md), "Trust: what a
preview can reach", has the full picture. The planned fixes: a preview role
scoped to its own namespaces; writes and deletes only on preview-owned
resources, with `aws:ResourceAccount` pinned; and the sweep retiring orphaned
`/preview/` roles.
