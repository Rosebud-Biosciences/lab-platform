"""mlflow-auth-sync: MLflow (mlflow-oidc-auth) service accounts, tokens, patterns.

Run by the workloads module as a CronJob next to MLflow in auth mode "oidc".
Standard library only. Authenticates with its projected ServiceAccount token
(MLFLOW_TOKEN_FILE), as the MLflow admin MLflow's init container made it.

For each service account in config.json:
  - create it in MLflow (idempotent);
  - keep a token in each of its Secrets (pre-created by the environment that
    owns the namespace), renewed RENEW_BEFORE ahead of MLflow's one-year cap
    (the Secret's lab-platform.io/mlflow-token-expires annotation records
    when);
  - grant its experiment patterns.
Then grant the group experiment patterns (auth.mlflow_group_rules).
"""

import base64
import datetime as dt
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

MLFLOW = os.environ["MLFLOW_URL"].rstrip("/")
MLFLOW_TOKEN_FILE = os.environ["MLFLOW_TOKEN_FILE"]
MLFLOW_USER = os.environ["MLFLOW_USER"]
CONFIG_PATH = os.environ.get("CONFIG_PATH", "/etc/mlflow-auth-sync/config.json")
EXPIRY_ANNOTATION = "lab-platform.io/mlflow-token-expires"
LIFETIME = dt.timedelta(days=364)
RENEW_BEFORE = dt.timedelta(days=30)
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S = "https://kubernetes.default.svc"


def _request(req: urllib.request.Request, context: ssl.SSLContext | None = None) -> object:
    with urllib.request.urlopen(req, timeout=30, context=context) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else {}


def mlflow(method: str, path: str, body: object | None = None) -> object:
    req = urllib.request.Request(
        MLFLOW + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
    )
    with open(MLFLOW_TOKEN_FILE) as f:
        req.add_header("Authorization", f"Bearer {f.read().strip()}")
    req.add_header("Content-Type", "application/json")
    return _request(req)


def k8s(method: str, path: str, body: object | None = None) -> object:
    with open(f"{SA_DIR}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(
        K8S + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
    )
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/merge-patch+json")
    return _request(req, ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt"))


def now() -> dt.datetime:
    return dt.datetime.now(dt.UTC)


def token_is_fresh(namespace: str, name: str) -> bool:
    secret = k8s("GET", f"/api/v1/namespaces/{namespace}/secrets/{name}")
    assert isinstance(secret, dict)
    expires = (secret.get("metadata", {}).get("annotations") or {}).get(EXPIRY_ANNOTATION)
    return bool(expires) and dt.datetime.fromisoformat(expires) - now() > RENEW_BEFORE and bool(secret.get("data"))


def write_token(namespace: str, name: str, username: str, token: str, expires: dt.datetime) -> None:
    b64 = lambda s: base64.b64encode(s.encode()).decode()  # noqa: E731
    k8s(
        "PATCH",
        f"/api/v1/namespaces/{namespace}/secrets/{name}",
        {
            "metadata": {"annotations": {EXPIRY_ANNOTATION: expires.isoformat()}},
            "data": {"MLFLOW_TRACKING_USERNAME": b64(username), "MLFLOW_TRACKING_PASSWORD": b64(token)},
        },
    )


def ensure_patterns(base: str, wanted: list[dict]) -> None:
    """Create the patterns under `base` that are not there yet (by regex + permission)."""
    existing = mlflow("GET", base)
    have = {(p["regex"], p["permission"]) for p in existing} if isinstance(existing, list) else set()
    for p in wanted:
        if (p["regex"], p["permission"]) not in have:
            mlflow("POST", base, {"regex": p["regex"], "priority": p["priority"], "permission": p["permission"]})
            print(f"  + {base}: {p['regex']} -> {p['permission']}")


def main() -> int:
    me = mlflow("GET", "/api/2.0/mlflow/users/current")
    if not (isinstance(me, dict) and me.get("username") == MLFLOW_USER and me.get("is_admin")):
        print(f"MLflow does not know {MLFLOW_USER} as an admin (its admin-auth-sync init container makes it one): {me}", file=sys.stderr)
        return 1
    with open(CONFIG_PATH) as f:
        config = json.load(f)

    for username, account in config.get("service_accounts", {}).items():
        print(f"service account {username}")
        mlflow("POST", "/api/2.0/mlflow/users", {"username": username, "display_name": username, "is_service_account": True})
        secrets = [(s["namespace"], s["name"]) for s in account["secrets"]]
        if any(not token_is_fresh(ns, name) for ns, name in secrets):
            expires = now() + LIFETIME
            reply = mlflow("PATCH", "/api/2.0/mlflow/users/access-token", {"username": username, "expiration": expires.isoformat()})
            assert isinstance(reply, dict)
            # One token per account: every Secret gets the new one.
            for ns, name in secrets:
                write_token(ns, name, username, reply["token"], expires)
            print(f"  token renewed in {', '.join(f'{ns}/{name}' for ns, name in secrets)} (expires {expires:%Y-%m-%d})")
        ensure_patterns(
            f"/api/2.0/mlflow/permissions/users/{urllib.parse.quote(username, safe='')}/experiment-patterns",
            account.get("experiment_patterns", []),
        )

    for group, patterns in config.get("group_rules", {}).items():
        print(f"group {group}")
        # Group names are full paths (/lab/authors): encode the whole name so
        # the plugin's {group_name:path} segment receives it, leading slash
        # included.
        try:
            ensure_patterns(f"/api/2.0/mlflow/permissions/groups/{urllib.parse.quote(group, safe='')}/experiment-patterns", patterns)
        except urllib.error.HTTPError as e:
            # The plugin creates a group when one of its members first logs in
            # and offers no API to create one; until then there is nothing to
            # attach patterns to. The next run picks it up.
            if e.code not in (404, 500):
                raise
            print("  not known to MLflow yet (no member has logged in); next run")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.HTTPError as e:
        print(f"{e.code} {e.reason} from {e.url}: {e.read().decode(errors='replace')[:500]}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"cannot reach MLflow or the Kubernetes API: {e.reason}", file=sys.stderr)
        sys.exit(1)
