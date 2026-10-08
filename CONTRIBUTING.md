# Contributing

Issues and pull requests are welcome. For anything larger than a fix, open an
issue first so the design can be agreed before the code. Security problems go
through [SECURITY.md](SECURITY.md), never a public issue. Everyone taking part
follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## OpenTofu only

The family targets OpenTofu >= 1.12 and is tested only with it: the
persistent-data guards use a dynamic `prevent_destroy`, which Terraform
rejects. Please don't add Terraform-only constructs or compatibility shims.

## The CI gates

A pull request must pass the same six gates CI runs
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)). Run them from the
repository root:

```bash
# 1. fmt
tofu fmt -check -recursive -diff .

# 2. validate: every directory in ci.yml's validate matrix (modules/*, aws/*, examples/*)
tofu -chdir=<dir> init -backend=false && tofu -chdir=<dir> validate

# 3. tflint
tflint --init && tflint --recursive --config "$(pwd)/.tflint.hcl"

# 4. checkov: one tree per run (two -d flags under-report)
uvx checkov -d modules --framework terraform --config-file .checkov.yml --quiet --compact
uvx checkov -d aws --framework terraform --config-file .checkov.yml --quiet --compact

# 5. terraform-docs: CI fails if a module README is stale
terraform-docs -c .terraform-docs.yml <module dir>

# 6. tofu test: every directory in ci.yml's test matrix (plan-only)
tofu -chdir=<dir> test
```

- Suppress a tflint or checkov finding only at the one site, with the reason
  (`# tflint-ignore: <rule>`, or `#checkov:skip=<ID>:<reason>` inside the
  resource block). Repo-wide checkov exceptions go in `.checkov.yml`, with a
  reason.
- A new module or example directory goes into the validate, docs and test
  matrices in `ci.yml` and into `.github/dependabot.yml`.
- Changes to `modules/workloads` or the auth modules: `examples/kind` runs
  them end to end on a laptop (`kind smoke` in CI).

## Changelog

Every user-visible change gets an entry under `[Unreleased]` in
[CHANGELOG.md](CHANGELOG.md) ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)),
saying what changed and what a user has to do about it. Mark breaking changes
**breaking**.
