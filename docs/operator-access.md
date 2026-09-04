# Operator access

How the *person* running `tofu apply` should authenticate, and why the obvious
approaches don't work. Everything here was learned the expensive way — by an
apply that failed halfway — so it is written down in one place.

The CI roles in [`modules/bootstrap`](../modules/bootstrap) cover machines.
This document covers you.

## The problem with the obvious setup

Most people start with an IAM user and a long-lived access key in
`~/.aws/credentials`, attached to whatever policies make the applies pass. Two
things are wrong with that, and they compound:

1. **The key is the whole platform.** Anyone who has it can do everything the
   stacks can do, including delete the state bucket and stop CloudTrail. Access
   keys leak — from laptops, shell history, CI logs, `.env` files in git.
2. **You cannot put MFA on it.** A long-lived key never carries MFA context, so
   an `aws:MultiFactorAuthPresent` condition can't be satisfied by it — only by a
   session credential minted after an MFA challenge. Gating the *key* on MFA is
   not a thing AWS offers.

So the arrangement has to be: the key can do one thing — step up — and the
stepping-up is where MFA lives.

## The shape

```
IAM user (static key)  --sts:AssumeRole + MFA-->  operator-admin role  --> the stacks
        |                                                  |
        +---- guardrail Deny (attached to both) -----------+
```

- The **static identity** keeps `sts:AssumeRole` on the operator role and
  nothing else it doesn't strictly need. Ideally: self-service on its own
  credentials, and read-only for browsing.
- The **operator role** carries the real permissions (`AdministratorAccess` by
  default in `modules/bootstrap`; scope it down once you know what your stacks
  call). Its trust policy requires `aws:MultiFactorAuthPresent = true` and a
  recent `aws:MultiFactorAuthAge`, so getting into it *is* the MFA check.
  `max_session_duration` is four hours by default, because a full cluster
  apply can outlast the one-hour default and credentials expiring mid-apply is
  how state drifts from reality.
- A **guardrail** Deny policy protects the things whose loss is unrecoverable
  — state history, the lock table, the audit trail, and the role/guardrail
  themselves — from anything that is not the role. It is attached to the role
  by the module; you attach it to the static identity as well.

`modules/bootstrap` builds the role and the guardrail:

```hcl
module "bootstrap" {
  source = "your-org/lab-platform/aws//modules/bootstrap"

  state_bucket_name = "my-org-terraform-state"

  enable_operator_admin_role = true
  operator_principal_arns    = ["arn:aws:iam::123456789012:user/alice"]
  # operator_admin_policy_arns      = [...]   # AdministratorAccess by default
  # operator_mfa_max_age            = 3600
  # operator_admin_session_duration = 14400
}

resource "aws_iam_user_policy_attachment" "alice_guardrails" {
  user       = "alice"
  policy_arn = module.bootstrap.operator_guardrails_policy_arn
}
```

The module never touches IAM users or group membership — those are yours.

## Running tofu through the role

This is the part that is less obvious than it should be.

### Set up the profile

```bash
aws configure set profile.operator.role_arn         arn:aws:iam::123456789012:role/operator-admin
aws configure set profile.operator.source_profile   default
aws configure set profile.operator.mfa_serial       arn:aws:iam::123456789012:mfa/alice
aws configure set profile.operator.region           us-west-2
aws configure set profile.operator.duration_seconds 14400

aws sts get-caller-identity --profile operator   # prompts for the code
```

`source_profile = default` is the static key — the one the role exists to
defang. It still proves who you are; the MFA prompt is the second factor on
top. `duration_seconds` has to be set explicitly or the CLI asks for the
one-hour default and the role's four-hour `max_session_duration` never gets
used.

### `AWS_PROFILE=operator tofu apply` does not work, and cannot

The AWS CLI can stop and ask you for an MFA code. The Go SDK inside the
Terraform AWS provider has no way to prompt, and fails the moment it sees
`mfa_serial` on the profile:

```
Error: assume role with MFA enabled, but AssumeRoleTokenProvider session option not set.
```

So let the CLI do the prompting and hand tofu the result. The CLI caches the
assumed session, so this prompts once per `duration_seconds`:

```bash
eval "$(aws configure export-credentials --profile operator --format env)"
unset AWS_PROFILE   # or the provider re-reads the profile and fails again
tofu plan
```

`unset AWS_PROFILE` is not optional: with it set, the provider prefers the
shared-config profile over the credentials now in the environment, sees
`mfa_serial`, and raises the same error. Worth a shell function:

```bash
operator() {
  eval "$(aws configure export-credentials --profile operator --format env)"
  unset AWS_PROFILE
}
```

The alternative is a second profile whose `credential_process` shells out to
the CLI, which makes `AWS_PROFILE` work directly — but it hides the MFA prompt
behind captured stdout, so an expired cache produces a confusing failure rather
than a prompt. The two lines above are easier to reason about.

### The cluster has to know about the role

The `kubernetes`/`helm`/`kubectl` providers authenticate with `aws eks
get-token`, which signs as whatever credentials are ambient. When you switch
from the static key to the role, the cluster sees a new principal — and with
API authentication mode, a principal without an EKS access entry is refused.
`modules/eks-platform` gives the *creator* an entry automatically; the role
needs one of its own:

```hcl
module "platform" {
  source = "your-org/lab-platform/aws//modules/eks-platform"
  # ...
  access_entries = {
    operator = {
      principal_arn = module.bootstrap.operator_admin_role_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}
```

This is a chicken-and-egg: the entry has to be created by an identity that
already has one, so apply it **from the static key** (the creator) once. From
then on the role can run the cluster stacks itself, and you can set
`enable_cluster_creator_admin_permissions = false` so the bootstrap credential
stops holding standing admin — after confirming the role's entry works.

### Order of operations

1. Apply `bootstrap` with the operator role on. Run this from the static key;
   the role doesn't exist yet.
2. Attach the guardrail to the static identity. From here, changes to the
   guarded objects have to run as the role.
3. Apply `eks-platform` with the role in `access_entries`. From the static key
   — the role can't reach the cluster until this lands.
4. Run everything through the role for a while. Same permissions, so there
   should be no 403s; the session lifetime and `get-token` are the new moving
   parts.
5. Demote the static identity to `sts:AssumeRole` on the role plus whatever
   self-service you want. This is the step that turns a leaked key from an
   incident into a nuisance.

## Why the guardrail is shaped the way it is

The guardrail's self-protection statement has *two* conditions, ANDed:

```hcl
condition {
  test     = "ArnNotEquals"
  variable = "aws:PrincipalArn"
  values   = [operator_role_arn]
}
condition {
  test     = "BoolIfExists"
  variable = "aws:MultiFactorAuthPresent"
  values   = ["false"]
}
```

The Deny fires only for a caller that is **not the role** and **has no MFA in
its context** — the static key. The first condition is there because the
second cannot do the job on its own, and this is the thing that cost an apply:

> The temporary credentials returned by `AssumeRole` do not include MFA
> information in the context, so you cannot check individual API operations
> for MFA.
>
> — [IAM User Guide: Configuring MFA-protected API access][mfa-api]

STS uses MFA to authenticate the `AssumeRole` call and then **drops it**.
`aws:MultiFactorAuthPresent` is absent from every call made with the role's
credentials, however carefully the role was assumed. And `BoolIfExists`
treats an absent key as matching `"false"`, so a guardrail with only the MFA
test denies the MFA-gated role exactly as it denies a bare access key — it
locks out the one principal meant to get through. (That is also why a guardrail
must never use plain `Bool`: a long-lived key *omits* the key rather than
setting it false, and plain `Bool` would not match it.)

So: the role is exempted by identity. `aws:PrincipalArn` on an assumed-role
request is the role's ARN, not the session's, so it matches every session of
the role and nothing else. MFA for the role is enforced one step earlier, in
its trust policy — which is where AWS documents it belongs.

The MFA test stays for one reason: break-glass.

[mfa-api]: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa_configure-api-require.html

## Break-glass

If a future change to the guardrail ever denies the role itself, the role
cannot fix it. The escape hatch is `sts:GetSessionToken`, the one STS call
that carries MFA context forward: the session it mints is the *user's*
principal, with `aws:MultiFactorAuthPresent = true`, so it passes the
guardrail's MFA test while still being short-lived.

```bash
operator-mfa() {   # usage: operator-mfa 123456
  local creds
  creds=$(aws sts get-session-token --profile default \
    --serial-number arn:aws:iam::123456789012:mfa/alice \
    --token-code "$1" --duration-seconds 3600 \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text) || return
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$creds"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  unset AWS_PROFILE
}
```

Two caveats. It takes the code as an argument because `get-session-token` has
no prompting path of its own. And it only helps while the static identity still
holds permissions that can reach the guarded objects — after step 5 above it
doesn't, and the remaining break-glass is the account root. That is the correct
end state, not a bug.

## Changing a guardrail that binds you

Once the guardrail is attached to the identity running tofu, editing the
guardrail is subject to the guardrail. Two things to know.

**Description changes force replacement.** IAM has no API to update a managed
policy's description, so the provider destroys and recreates the policy (same
name, so the same ARN comes back) along with every attachment. There is a
brief window with no guardrail at all; if the apply dies in it, re-run and the
policy is recreated from config.

**A new guardrail binds mid-apply.** If the same apply also does something the
new guardrail denies to the identity running it, and Terraform happens to
create the guardrail first, the second thing fails with a 403 — Terraform has
no dependency edge between them, so they run in parallel. Do it in two passes,
landing everything else while the *old* guardrail is still in force:

```bash
tofu apply -exclude=module.bootstrap.aws_iam_policy.operator_guardrails
tofu apply
```

`-exclude` (OpenTofu ≥ 1.9) drops the target and everything that depends on
it, which here is the policy and its attachments.
