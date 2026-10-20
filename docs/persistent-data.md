# Persistent data and deletion guards

Almost everything in this family is intentionally disposable: that is what
makes previews cheap. The few places real data persists are each guarded
against an accidental `destroy`:

| Data | Where | Guard |
| --- | --- | --- |
| Terraform state | `aws/bootstrap` S3 bucket | Versioning + a Deny `s3:DeleteBucket` bucket policy (`state_bucket_prevent_destroy`, default on); with the operator role on, an identity Deny on `DeleteObjectVersion` and on removing the bucket policy from a non-MFA key |
| State locks | `aws/bootstrap` DynamoDB table | Native deletion protection (`lock_table_deletion_protection`, default on); with the operator role on, an identity Deny on `DeleteTable` and on flipping the flag from a non-MFA key |
| JupyterHub user homes + shared dir | `aws/compute-adapter` EFS filesystem (`modules/workloads` only binds to it, so destroying the workloads never deletes homes) | `lifecycle.prevent_destroy` (`jupyterhub_efs_prevent_destroy`, default on); back up via the `jupyterhub_efs_id` output |
| Durable object data | `aws/s3-bucket` | Deny `s3:DeleteBucket` policy + a KMS key policy denying `kms:ScheduleKeyDeletion` (`prevent_destroy`), `force_destroy = false`, versioning |
| Databases | External (Neon/RDS — never module-managed) | Provider-side (e.g. Neon retains parents; previews only ever touch child branches) |

Everything else — preview buckets, Neon branches, namespaces, Helm releases,
NodePools, ephemeral Ray clusters — is meant to be destroyed freely. The
guarded resources make teardown a deliberate two-step: disarm the guard in one
apply, destroy in the next. Prometheus/MLflow/hub-db PVCs ride on EBS with the
cluster's default reclaim policy and are treated as rebuildable caches; if you
care about them, switch their StorageClass to `reclaimPolicy: Retain`.

The guards stop a stray `destroy`. They do not stop a person — or a leaked
long-lived access key — from turning the guards off first. For that, the
operator's static identity keeps only the right to step up into an MFA-gated
role, and a Deny policy protects the guards and the role from anything that is
not that role. How to set that up, and how to run tofu through it, is in
[operator-access.md](operator-access.md).
