# JupyterHub example

A multi-user notebook lab on the platform: per-user logins, a persistent
per-user home directory, a shared team directory, and the
[marimo](https://marimo.io) notebook available from the JupyterLab launcher.

What you get:

- **Per-user logins** — `firstuse` auth: each username on the allow list sets
  its own password the first time it logs in. No identity provider needed.
  When you have one, switch to real SSO — Google shown, any OIDC provider
  works the same way:

  ```hcl
  jupyterhub_auth_mechanism      = "oidc"
  jupyterhub_oidc_login_service  = "Google"
  jupyterhub_oidc_client_id      = var.google_client_id
  jupyterhub_oidc_client_secret  = var.google_client_secret # sensitive
  jupyterhub_oidc_authorize_url  = "https://accounts.google.com/o/oauth2/v2/auth"
  jupyterhub_oidc_token_url      = "https://oauth2.googleapis.com/token"
  jupyterhub_oidc_userdata_url   = "https://openidconnect.googleapis.com/v1/userinfo"
  jupyterhub_oidc_callback_url   = "https://<hub host>/hub/oauth_callback"
  # usernames are now email addresses (oidc_username_claim defaults to email):
  jupyterhub_admin_users   = ["ada@your-org.com"]
  jupyterhub_allowed_users = ["ada@your-org.com", "grace@your-org.com"]
  ```

  The callback host only needs to be reachable by the *browser*, so a
  tailnet-private hub (`https://<name>.<tailnet>.ts.net`) works — register
  that URL with the IdP.
- **Per-user home** — every user's `/home/jovyan` is a private sub-directory
  (`home/<username>`) on one shared EFS filesystem, so notebooks survive server
  restarts and idle culling.
- **Shared directory** — `/home/shared` is mounted read-write in every user's
  server for handing files around.
- **marimo** — installed at server start via a `postStart` hook together with
  `jupyter-marimo-proxy`, which adds a marimo tile to the JupyterLab launcher.
  Bake both packages into `jupyterhub_singleuser_image` for production.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars   # set your usernames
tofu init

# First apply only: create the cluster before planning the workloads on it.
tofu apply -target=module.network -target=module.platform
tofu apply
```

## Log in

No ingress is configured in this example; use a port-forward:

```bash
aws eks update-kubeconfig --name "$(tofu output -raw cluster_name)" --region "$(tofu output -raw region)"
tofu output -raw port_forward_command | sh
```

Open <http://localhost:8080>, log in as one of the allowed usernames, and pick
any password — that password is now yours (admins can reset passwords from the
control panel). Start the server, then:

- your files live in `/home/jovyan` (private, persistent);
- team files live in `/home/shared` (visible to everyone);
- the launcher has a **marimo** tile next to the notebook/console tiles.

## The data is guarded

User homes live on one EFS filesystem, which is the only persistent user data
in the stack. `aws/compute-adapter` owns it and protects it with
`lifecycle.prevent_destroy` by default (`jupyterhub_efs_prevent_destroy = true`),
so `tofu destroy` — or flipping `enable_jupyterhub` off — fails until you
deliberately disarm the guard first and apply that change. `modules/workloads`
only binds PersistentVolumes to the filesystem, so destroying the workloads
layer alone never touches the data. Snapshot it with AWS Backup using the
adapter's `jupyterhub_efs_id` output before ever doing so.

## Cost

Same baseline as [`examples/minimal`](../minimal) (~$225/mo: EKS control plane,
core nodes, one NAT gateway) plus EFS (~$0.30/GiB-mo, pennies at notebook scale)
and whatever nodes Karpenter provisions for active user servers.
