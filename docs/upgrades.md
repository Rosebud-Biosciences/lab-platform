# Keeping versions current

What moves underneath a deployed platform, which of it a dependency bot sees,
and how to keep the rest from silently aging. The Tailscale section is the one
to read if you only read one: those are the clients on your network boundary,
and their fixes arrive as releases.

## What Dependabot covers, and what it cannot

[`.github/dependabot.yml`](../.github/dependabot.yml) keeps two surfaces fresh:
the GitHub Actions the workflows use, and the Terraform providers and registry
modules pinned in every module and example. Copy that arrangement into the
stack that consumes these modules.

Three things are invisible to it:

| Surface | Where it lives | Who watches it |
| --- | --- | --- |
| Helm chart versions in variable defaults (`*_chart_version`, `karpenter_version`, ...) | `modules/*/variables.tf` | [`chart-drift`](../.github/workflows/chart-drift.yml), monthly |
| EKS add-on builds and the Kubernetes support calendar | the AWS API, per live cluster | your stack (see below) |
| The Tailscale relay's AMI | `var.ts_relay_ami` in `aws/network`, or Canonical's SSM parameter when unpinned | you, deliberately (see below) |

Renovate can reach the chart pins with regex managers if you run it; nothing
here assumes you do.

## Chart pins: the `chart-drift` report

Every chart this module family installs from an HTTP chart repository *and*
exposes as an input is checked monthly against that repository's stable
releases by [`chart-drift.sh`](../.github/scripts/chart-drift.sh). The defaults
are the module's promise to its users — a fresh apply should not install last
year's charts — so the report opens one issue, refreshes it in place on each
run, and closes it when the pins are back within threshold.

Thresholds: more than three stable releases behind for most charts; **any**
newer release for the Tailscale operator chart (why, below). Charts pinned
literally inside a `helm_release` and charts pulled from OCI registries
(Karpenter, Kubecost, the Neuron plugin) are out of scope — bump those with the
chart's release notes to hand.

Run it locally before a deliberate upgrade; it needs `helm` and `jq` and no
credentials:

```bash
.github/scripts/chart-drift.sh
```

## Tailscale: three kinds of client, three update paths

Every Tailscale release can carry a CVE fix, and a tailnet is only as patched as
its oldest node. The platform runs Tailscale in three places, and each updates
differently.

**Containers — the operator and its Ingress proxies (`aws/eks-platform`).**
One pin, `tailscale_operator_chart_version`, is the Tailscale version of the
operator *and* of every proxy it runs for a private UI; the proxies follow the
operator's image. Containers never self-update, so bumping that pin is how a
fix reaches the cluster. On apply the operator rolls each proxy to the new
image — node identity persists in the proxy's state Secret, so the MagicDNS
names and ACL tags are unchanged; expect a pod-restart blip per UI. This is
the pin `chart-drift` holds to "any newer release".

**The relay — an EC2 subnet router (`aws/network`).** It keeps itself
current: `tailscale-init.sh` runs `tailscale set --auto-update`, so client
releases land on the running instance without a rebuild. Its AMI is therefore
a hygiene clock, not an exposure clock — the client on the box is newer than
the client in the image within days of boot. Two consequences:

- Pin `ts_relay_ami` in anything long-lived. Left empty, the module resolves
  Canonical's *current* Ubuntu 24.04 image at plan time, and `ami` forces
  replacement, so an unpinned relay is rebuilt on whatever apply follows
  Canonical's next publish — every few weeks — taking the tailnet's route into
  the private subnets with it for a few minutes.
- A rebuild is always *safe*: the relay's pre-auth key is single-use, and
  `terraform_data.relay_build` re-mints it in the same apply that replaces the
  instance, so the new box never boots with a spent key. It is just never
  *free*. Repin on your own schedule (a couple of times a year is plenty) and
  apply during a quiet hour.
- A relay built before auto-update was in the init script needs the flag set
  once by hand, over SSM Session Manager:
  `sudo tailscale set --auto-update && sudo tailscale update`.

**Everything else — laptops and future hosts.** Make auto-updates the tailnet
default so joining devices inherit it. The module does not manage your tailnet
(its ACL and settings are yours), but if the stack that does uses the Tailscale
provider, this is one resource:

```hcl
resource "tailscale_tailnet_settings" "this" {
  devices_auto_updates_on = true
}
```

It applies to devices as they join; devices already enrolled keep their own
setting (flip them from the admin console's machine list, or with
`tailscale set --auto-update` on the device).

For an urgent fix, the trigger is Tailscale's
[security bulletins](https://tailscale.com/security-bulletins), not a monthly
report: bump the chart pin, apply, and confirm the relay picked up the release
(`tailscale version` over SSM).

## The cluster itself

Kubernetes leaves standard support on a fixed calendar and EKS add-on builds
are qualified per Kubernetes version; both exist only in the AWS API and only
for a live cluster, so this repository — which has none — cannot report on
them. In the consuming stack, the source of truth is:

```bash
aws eks describe-cluster-versions --cluster-type eks --cluster-versions <k8s>  # endOfStandardSupportDate
aws eks describe-addon-versions --addon-name <addon> --kubernetes-version <k8s> # newest build offered
```

Worth wrapping in the same monthly-issue pattern as `chart-drift`: extended
support bills the control plane at a far higher rate and ends in a forced
upgrade, and a 180-day warning is what turns that into a planned one.
