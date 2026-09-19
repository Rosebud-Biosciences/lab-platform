# Authentication and authorization

The platform runs several UIs that cannot authenticate on their own (Dagster
OSS, MLflow OSS, the Ray dashboard), two that can (Argo Workflows, JupyterHub),
and an application that should own its users. This document is the one place
that says how they are gated, where identity comes from, and which part of
that state belongs to an environment -- and so branches with a preview -- and
which does not.

## Three modes

`modules/workloads` takes `var.auth`:

| | `mode = "headers"` (default) | `mode = "oidc"` | `mode = "none"` |
| --- | --- | --- | --- |
| Who authenticates | the private network: a proxy that already knows the caller (the Tailscale operator's Ingress sets `Tailscale-User-Login`) | OpenID Connect against one issuer | nobody |
| Deployed by the module | nothing | an `oauth2-proxy` per protected service, Argo SSO config, JupyterHub OIDC config, the webapp's `OIDC_*` env, the OAuth2 clients | nothing |
| Portability | needs a network whose edge identifies users | any network, any IngressClass (Tailscale included) | -- |
| Per-service authorization | the network ACL (tags per Ingress) | `protect[svc]` gates, Argo `rbac-rule`s, JupyterHub `allowed_groups` | -- |

The mode is one switch that means the same thing everywhere. The webapp
receives it as `AUTH_MODE` and accepts exactly that mode's identity source:
the header named in `IDENTITY_HEADER` in `headers` mode, its own login in
`oidc` mode (or, when it sits behind an oauth2-proxy, the proxy's signed ID
token), nothing in `none` mode. A header the module has not named is never
trusted, and in `oidc` or `none` mode no header is. JupyterHub follows the
mode too (`jupyterhub_auth_mechanism` defaults to `oidc` in `oidc` mode and is
an override otherwise).

A public webapp Ingress is refused in `headers` mode: the public load
balancer passes whatever headers an internet client sends, so the tailnet's
identity header would identify anyone as anyone. A public webapp runs `oidc`
(it logs users in itself) or `none`.

## The pieces in `oidc` mode

```mermaid
flowchart LR
  Browser --> Proxy["oauth2-proxy (per env, per protected svc)"]
  Proxy -->|"302 login"| Dex["Dex (one per cluster)"]
  Dex -->|"connector"| IdP[Google, GitHub, LDAP, SAML, or the CI password DB]
  Proxy -->|"gate, then X-Forwarded-Email / -Groups"| Dagster
  Browser --> Argo["Argo server: native SSO + group rbac-rules"] --> Dex
  Browser --> Hub["JupyterHub: GenericOAuthenticator"] --> Dex
  Browser --> App["webapp: its own OIDC login"] --> Dex
  App -->|"users, sessions, memberships"| AppDB["db/app (Neon branch or tether fork)"]
```

**Dex is the issuer** ([`modules/dex`](../modules/dex)). It owns no users;
its connectors delegate the actual login to whatever you already run and
re-issue standard OIDC tokens. That hop buys two things: vendor neutrality
(swap the connector, nothing downstream changes) and dynamic clients. Google's
OAuth client has a static redirect-URI list, so a per-PR environment with
hostnames like `pr7-dagster.<suffix>` could never register with Google
directly; with Dex's `kubernetes` storage a client is an `OAuth2Client`
custom resource, which each environment creates for itself and deletes with
its `tofu destroy`. Connector secrets reach Dex as environment variables from
a Secret (`connector_env`, or `connector_env_secret_name` for one created
outside tofu), referenced as `$NAME` in the connector config, so they are
never in the Helm values or Dex's rendered config.

**oauth2-proxy is the relying party for services that cannot be one.** One
Deployment per protected service, in reverse-proxy mode: the private Ingress
points at the proxy, the proxy runs the login, enforces the service's gate
and forwards to the upstream with `X-Forwarded-Email`, `X-Forwarded-User`,
`X-Forwarded-Groups`. Because it is in the request path rather than a
forward-auth hook, it works behind any IngressClass and without any Ingress
at all (the kind example reaches the proxies by their in-cluster Service
URLs). Its sessions:

- **host-only cookies** -- no shared cookie domain. On a flat tailnet one
  environment's hosts sit beside every other's (`pr7-dagster.<suffix>` next
  to `dagster.<suffix>`), so any domain that covered one environment's
  proxies would carry prod's session cookie to every preview, which serves
  PR code.
- **re-validated hourly, at most a day long** (`session_refresh = "1h"`,
  `session_lifetime = "24h"`): the proxy asks Dex for `offline_access` and
  refreshes, re-reading groups, so removing someone from a group takes
  effect within the hour rather than oauth2-proxy's week-long default. Dex's
  ID tokens last an hour (`id_token_expiry`).

**Services that speak OIDC talk to Dex directly.** Argo's server runs
`authModes: [sso]`; JupyterHub's `GenericOAuthenticator` gets the issuer's
`/auth`, `/token`, `/userinfo`; the webapp receives `OIDC_ISSUER_URL`,
`OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_REDIRECT_URL`, `OIDC_GROUPS_CLAIM`,
`OIDC_SCOPES`, `SESSION_SECRET` and `COOKIE_SECURE`, and runs the
authorization-code flow itself (with PKCE, a verified email required, users
keyed by issuer and subject). If the webapp is itself behind an oauth2-proxy
(`protect.webapp`), the proxy forwards its ID token (`Authorization: Bearer`)
and the app verifies it against Dex's keys (`IDENTITY_JWT_ISSUER`,
`IDENTITY_JWT_AUDIENCE`) -- the signed-assertion pattern of IAP or an ALB --
so its identity does not rest on the network path.

**Single sign-on is per issuer session, not per cookie.** Dex keeps no
browser session in any release yet (its auth-sessions work, with per-client
`ssoSharedWith`, merged in March-April 2026 after v2.45.1): each relying
party's login goes back to the connector, and is silent only when the
upstream IdP has a session of its own (Google, GitHub, Keycloak do; Dex's
password DB does not). When a Dex release ships sessions, enabling them is a
config change here, not a redesign.

## Authorization: groups, default-deny

Every gate names who it admits; nothing admits "anyone the issuer admits"
unless you say so:

| Where | Input | Effect |
| --- | --- | --- |
| a proxied UI | `protect = { dagster = { allowed_groups = ["pipelines"] } }` | only members of `pipelines` open Dagster. A gate with neither groups nor emails needs `allowed_email_domains` (empty by default, so an ungated service fails the plan); `["*"]` is the explicit "everyone the issuer admits", right only when its connectors are restricted (a GitHub connector without `orgs` admits all of GitHub) |
| Argo | `argo_rbac_rules = { admins = { rule = "'platform' in groups", access = "write", precedence = 10 }, lab = { rule = "'lab' in groups", access = "read" } }` | one ServiceAccount per rule, annotated `workflows.argoproj.io/rbac-rule` and `-precedence`, bound to the `read` or `write` Role. Argo tries the numerically highest precedence first, so broad rules get low numbers. No implicit catch-all: a user matching no rule gets no Argo, and SSO requires at least one rule |
| JupyterHub | `jupyterhub_allowed_groups = ["lab"]` (or `jupyterhub_allowed_users`) | `allowed_groups` + `claim_groups_key` on the authenticator; `jupyterhub_allow_all = true` is the explicit open door |
| the webapp | its own tables | `require_group(...)` dependencies, group-filtered queries -- see the template app |

Groups arrive as a claim (`groups_claim`, default `groups`) that Dex forwards
when its connector can supply one: GitHub teams and LDAP / SAML / Microsoft
groups out of the box; Google only with an Admin SDK service account
configured on the connector; Dex's local password DB never. The `mockCallback`
connector returns a fixed identity in group `authors`, which is how the kind
smoke test proves a group gate end to end without an external IdP.

## The fence: the gate must be the way in

A gate means nothing if a caller can go around it, and inside a cluster
there are callers: notebook users run arbitrary code, and a preview runs a
PR's. So `network_policies` (on by default, both modes) puts a NetworkPolicy
in each UI service's namespace:

- the service's own pods accept traffic from their namespace, from the
  services that legitimately call them (by the `lab-platform.io/service`
  namespace label, in any environment: Dagster from the webapp; MLflow from
  the webapp, Dagster, Ray, Argo, JupyterHub; Ray from Dagster and Argo, plus
  the KubeRay operator; Argo from the webapp), and -- only when the service
  has no login proxy -- from the ingress controller's namespaces
  (`ingress_namespaces`, default the Tailscale operator's `tailscale`);
- a login proxy accepts traffic only from the ingress controller's
  namespaces.

So in `headers` mode only the tailnet Ingress can hand the webapp an
identity header, and in `oidc` mode a proxied service is reachable from
outside its callers only through its proxy. Clients are matched by label so
an app-only preview's webapp still reaches prod's Dagster -- the documented
stamp-or-share trade-off. A NetworkPolicy is inert unless the CNI enforces
it: kind's kindnet does (the smoke test asserts the refusals); on EKS turn on
the VPC CNI's policy agent with `aws/eks-platform`'s `enable_network_policy`,
after checking `ingress_namespaces` names your ingress namespace.

## What is state, and where it lives

| State | Lives in | Branches with a preview? |
| --- | --- | --- |
| identity: who exists, how they prove it, which groups they are in | the upstream IdP, behind Dex | no, and it must not -- a preview should not contain different people |
| Dex's own records (clients, refresh tokens, signing keys) | Dex's CRDs | no; the environment's clients are **stamped** with it and deleted on destroy |
| proxy sessions | an encrypted, host-only cookie | no state |
| Argo rbac ServiceAccounts, JupyterHub allowed lists, proxy gates, NetworkPolicies | the environment's Kubernetes objects | stamped per environment |
| users, memberships, record ownership, roles | the webapp's database (`db/app`) | **yes** -- a Neon branch (tofu) or a tether fork; preview signups and permission experiments never touch prod |
| the webapp's login sessions | the webapp's database | **a hazard of branching, neutralized**: a preview's branch starts with prod's rows, prod's live sessions included, in a database PR code can read. The app stores only `HMAC(SESSION_SECRET, id)`, and each environment has its own `SESSION_SECRET`, so the copies cannot log anyone in to the preview or, replayed, to prod; preview-up also deletes them right after migrating |

This is the same split Neon draws with its Managed Better Auth: the auth
*schema* branches with the database while the social providers behind it do
not. The one thing Better Auth can additionally branch -- password hashes --
is deliberately not replicated here: the platform is SSO-only, Dex's password
DB exists for CI, and a self-contained user store (Zitadel, Keycloak) would
take Dex's slot rather than change the rest of the design.

## Trust between environments

Per-environment clients are a boundary only if an environment cannot write
another's. Registration needs write access to Dex's namespace, so a
preview's CI could, by design, rewrite prod's `OAuth2Client` redirect URIs.
`modules/dex`'s `client_admission` closes that with a ValidatingAdmissionPolicy:
requests from the restricted principals (the preview role's Kubernetes
username prefix or group) may only create, change or delete clients whose id
matches `allowed_id_pattern` (`^pr[0-9]+-`), checked on both the new and the
old object. The kind smoke test impersonates such a principal and asserts
both outcomes.

That fences the auth objects; it does not make a cluster-admin preview role
safe. A preview role that can do anything can also delete the policy.
Scoping the preview role to its own namespaces is the real fix and needs the
workloads module to stop creating cluster-scoped objects per environment
(today: its namespaces, and the prefixed ClusterRoles and bindings for
Dagster's Ray access and Argo's workflows) or a pre-created set of them;
until then the policy is a guard against mistakes, not against a malicious
PR.

## Choosing an issuer

- **Dex** (recommended): one per cluster, `enable_password_db` for CI, a
  connector for your IdP in production, `dex_namespace` set on every
  environment so clients are registered automatically.
- **Any other OIDC issuer** (Google directly, Okta, Keycloak): set
  `issuer_url`, leave `dex_namespace` empty and bring `clients` for each
  relying party (`oauth2-proxy`, `argo`, `jupyterhub`, `webapp`), registered
  with the redirect URIs `output.auth` prints. Drop `groups` from `scopes` for
  issuers that reject it. Per-preview environments are impractical this way
  for the redirect-URI reason above.

The issuer URL must be the same string from a browser and from a pod: on
kind the in-cluster Service URL serves both; on a real cluster give Dex an
Ingress hostname that pods can also resolve.

## Where the network still matters

`oidc` mode makes authentication independent of the network, which is what
makes the network swappable later (Headscale, NetBird, plain ingress-nginx on
a public cluster). It does not remove the reason to have a private network:
Kubernetes API access, databases and object stores are still reached over it,
and in `headers` mode the tailnet's ACL remains a perfectly good gate.

**Status.** `oidc` mode has run end to end on kind (the smoke test), not yet
on EKS. Before relying on it in production, run it on a sandbox cluster and
settle one open problem: with a tailnet-only Dex hostname, pods (the proxies,
Argo, the webapp) must reach the issuer at the same URL browsers use, which
needs either the Tailscale egress proxy for pods or a split-horizon DNS name
pointing pods at Dex's Service. Until then `headers` is the production mode
on a tailnet.
