# Preview example (workspace-per-PR)

The flagship feature: **branch prod for testing, off prod.** Each PR gets a
full, isolated copy of the workloads on the *shared* cluster, with its own
copy-on-write database branches and an ephemeral S3 bucket — then it all
disappears on teardown. Prod is never touched.

## How the isolation works

| Concern        | Prod                          | Preview (`pr123`)                                  |
| -------------- | ----------------------------- | -------------------------------------------------- |
| Cluster        | shared EKS cluster            | **same cluster** (no new control plane)            |
| Namespaces     | `webapp`, `dagster`, …        | `pr123-webapp`, `pr123-dagster`, … (`name_prefix`) |
| IAM / NodePools| base names                    | `pr123-`-stamped                                   |
| Database       | Neon `main`                   | copy-on-write branch off `main` (seconds to cut)   |
| Object storage | prod bucket                   | ephemeral `preview-processeddata-pr123` bucket     |
| Iceberg (opt.) | prod namespaces               | own `pr123` namespace in the shared table bucket   |
| State          | `prod/…`                      | Terraform workspace `pr123` → `preview/pr123/…`    |

Because the cluster and its operators (Karpenter, LB controller, Tailscale) are
shared, a preview only pays for the pods and nodes it actually schedules.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # or pass -var flags from CI

tofu workspace new pr123        # one workspace per PR = isolated state
tofu apply -var preview_name=pr123

# ... test against the pr123-* private URLs ...

tofu workspace select pr123
tofu destroy -var preview_name=pr123
tofu workspace delete pr123
```

The reusable GitHub workflows in [`.github/workflows`](../../.github/workflows)
(`preview-up`, `preview-down`, `nightly-sweep`) wrap exactly this loop, using the
least-privilege preview role from `aws/bootstrap`.

## Notes

- **GPU isolation** — unlike the source setup, the `ray-gpu-worker` NodePool is
  `name_prefix`-stamped, so each preview gets its own GPU capacity instead of
  sharing prod's pool.
- **MLflow artifacts** — routed to the ephemeral bucket, so preview runs never
  write into the prod artifact store.
- **No Neon?** — leave `neon_branch_sources` empty and pass your own DB
  connection details instead; the copy-on-write branching is the happy path, not
  a hard requirement. The fallback is an empty branched DB plus a migration step.
- **Iceberg** — set `iceberg_table_bucket_arn` to give the preview its own
  ephemeral namespace in the shared S3 Tables bucket, with IAM confining its
  writes to that namespace (and optional read-only access to prod namespaces via
  `iceberg_read_namespaces`). Teardown caveat: tables inside the namespace must
  be dropped before `destroy` — see
  [`aws/iceberg-branches`](../../aws/iceberg-branches) for the CI
  snippet and for cutting true copy-on-write Iceberg branch refs engine-side.

See [`docs/preview-environments.md`](../../docs/preview-environments.md) for the
full design writeup.
