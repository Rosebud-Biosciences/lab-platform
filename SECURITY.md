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

1. **Up to v0.2.0, a preview deploys as cluster-admin.** The preview role
   reaches the cluster through a cluster-admin access entry. Anyone who can
   push a branch to an app repository that runs the preview workflows can
   therefore change anything in the cluster through them, prod's namespaces
   included, and act as any prod ServiceAccount and the IAM role bound to it.
   The label check that starts a preview is in a workflow file the PR can
   edit. From the next release, `aws/eks-platform`'s `preview_access`, with
   the role's access entry mapped to its group alone, confines it to the
   `preview-*` namespaces it creates (`modules/preview-access`); until you
   configure both, grant write access to such a repository as you would
   grant cluster-admin.
2. **Up to v0.2.0, the preview permissions boundary caps actions, not
   resources.** `preview_boundary_resources` defaults to `["*"]` there: a PR
   can create a `/preview/` role, with a trust policy of its choosing, that
   reads, writes or deletes objects in any bucket in the account. Set it to
   the buckets, table buckets, KMS keys and ECR repositories previews use,
   or upgrade: from the next release the boundary reaches only what a
   preview owns plus `preview_boundary_access`, with writes and deletes
   listed separately and S3 pinned to the account.

By design, `tether` mode lets a preview's pods write into production stores
(never delete): opt in only where the PR's code is trusted with that.

[docs/preview-environments.md](docs/preview-environments.md), "Trust: what a
preview can reach", has the full picture. From the next release,
`nightly-sweep` also retires `/preview/` roles and policies that outlive
their preview.
