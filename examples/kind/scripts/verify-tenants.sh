# shellcheck shell=bash
# Sourced by verify.sh when the example runs Keycloak and tenants
# (enable_keycloak): who gets into what, who may administer whom, which data a
# tenant can reach. Uses verify.sh's probe pod ($pod, namespace verify), its
# helpers (status_from) and variables (P, DEX_ISSUER, here, example).
#
#   sam /platform-admins, ann /lab/authors, alice /lab/authors/admins,
#   bob (no groups), cara /acme/research, dan /acme/admins -- all @example.com

KC="http://keycloak-http.keycloak.svc.cluster.local"
PW="${KIND_USERS_PASSWORD:-password}"
ML="http://${P}mlflow.${P}mlflow.svc.cluster.local"

in_pod() { kubectl -n verify exec "$pod" -- "$@"; }

# kc_login <start URL> <user> [jar in the pod] -> the final HTTP status
kc_login() {
  kubectl -n verify exec -i "$pod" -- env JAR="${3:-}" sh -s -- "$1" "$DEX_ISSUER" keycloak "$2@example.com" "$PW" <"$here/oidc-login.sh" | head -1
}

# gate <namespace> <service> <user> <want>: log in through the service's proxy
gate() {
  local got
  got=$(kc_login "http://$2-auth.$1.svc.cluster.local/oauth2/start?rd=%2F" "$3")
  echo "   $3 -> $2 ($1): $got (want $4)"
  [ "$got" = "$4" ]
}

# api <jar> <method> <url> [json] -> "<status> <body on one line>"
api() {
  local jar="$1" method="$2" url="$3" body="${4:-}" raw
  if [ -n "$body" ]; then
    raw=$(in_pod curl -sS -b "$jar" -X "$method" -H 'Content-Type: application/json' --data "$body" -w '\n%{http_code}' "$url")
  else
    raw=$(in_pod curl -sS -b "$jar" -X "$method" -w '\n%{http_code}' "$url")
  fi
  printf '%s %s\n' "$(printf '%s\n' "$raw" | tail -n 1)" "$(printf '%s\n' "$raw" | sed '$d' | tr -d '\n')"
}

json_field() { grep -o "\"$1\" *: *\"[^\"]*\"" | head -1 | sed -E 's/.*: *"([^"]*)"/\1/'; }


# The admin checks below change memberships; start from, and return to, the
# realm tofu made (bob in no group, cara a plain member of /acme/research).
kc_token() {
  in_pod curl -sS -d grant_type=password -d client_id=admin-cli -d "username=$1@example.com" -d "password=$PW" \
    "$KC/realms/lab/protocol/openid-connect/token" | json_field access_token
}
kc() { # kc <token> <method> <path> [json] -> status
  local extra=()
  [ -n "${4:-}" ] && extra=(-H 'Content-Type: application/json' --data "$4")
  # ${extra[@]+...}: an empty array is "unbound" to bash 3.2 under set -u.
  in_pod curl -sS -o /dev/null -w '%{http_code}' -X "$2" -H "Authorization: Bearer $1" ${extra[@]+"${extra[@]}"} "$KC/admin/realms/lab$3"
}
kc_id() { # kc_id <token> <path> -> the first "id" in the answer
  in_pod curl -sS -H "Authorization: Bearer $1" "$KC/admin/realms/lab$2" | json_field id
}
sam_t=$(kc_token sam); alice_t=$(kc_token alice); dan_t=$(kc_token dan)
bob_id=$(kc_id "$sam_t" "/users?email=bob@example.com&exact=true")
cara_id=$(kc_id "$sam_t" "/users?email=cara@example.com&exact=true")
g() { kc_id "$sam_t" "/group-by-path/$1"; }
authors=$(g lab/authors); pipelines=$(g lab/pipelines); research=$(g acme/research); research_admins=$(g acme/research/admins); platform=$(g platform-admins); acme=$(g acme)
reset_memberships() {
  kc "$sam_t" DELETE "/users/$bob_id/groups/$authors" >/dev/null
  kc "$sam_t" DELETE "/users/$cara_id/groups/$research_admins" >/dev/null
}
reset_memberships
trap 'reset_memberships >/dev/null 2>&1 || true; kubectl -n verify delete pod "$pod" --wait=false >/dev/null 2>&1 || true; kubectl -n "${P}webapp" delete pod "$client_pod" --wait=false >/dev/null 2>&1 || true' EXIT

echo "-- tenants: the gates (Keycloak groups through Dex)"
gate "${P}ray" ray sam 200             # the platform's Ray: superadmins only
gate "${P}ray" ray alice 403
gate "${P}dagster" dagster ann 200     # the shared Dagster: tenants that share it
gate "${P}dagster" dagster cara 403    #   (acme runs its own)
gate t-acme-dagster dagster cara 200   # acme's Dagster: acme only
gate t-acme-dagster dagster ann 403
gate t-lab-ray ray ann 200             # lab's Ray: every lab group, admins too
gate t-lab-ray ray alice 200
gate t-lab-ray ray cara 403

echo "-- tenants: Argo SSO rules"
argo_list() { # argo_list <argo prefix> <user> -> status of listing workflows after an SSO login
  local jar="/tmp/argo-$1-$2.jar" url="http://$1argo-server.$1argo.svc.cluster.local:2746"
  kc_login "$url/oauth2/redirect?redirect=/workflows" "$2" "$jar" >/dev/null || true
  api "$jar" GET "$url/api/v1/workflows/$1argo" | cut -d' ' -f1
}
got=$(argo_list "${P}" sam); echo "   sam lists the platform's workflows: $got (want 200)"; [ "$got" = "200" ]
got=$(argo_list "${P}" bob); echo "   bob (no rule matches) on the platform's Argo: $got (want 401 or 403)"; [ "$got" = "401" ] || [ "$got" = "403" ]
got=$(argo_list t-acme- cara); echo "   cara lists acme's workflows: $got (want 200)"; [ "$got" = "200" ]
wf='{"workflow":{"metadata":{"generateName":"verify-"},"spec":{"entrypoint":"main","templates":[{"name":"main","container":{"image":"busybox:1.37","command":["sh","-c","echo hello from acme"]}}]}}}'
got=$(api /tmp/argo-t-acme--cara.jar POST "http://t-acme-argo-server.t-acme-argo.svc.cluster.local:2746/api/v1/workflows/t-acme-argo" "$wf" | cut -d' ' -f1)
echo "   cara (read) submits to acme's Argo: $got (want 403)"; [ "$got" = "403" ]
argo_list t-acme- dan >/dev/null
out=$(api /tmp/argo-t-acme--dan.jar POST "http://t-acme-argo-server.t-acme-argo.svc.cluster.local:2746/api/v1/workflows/t-acme-argo" "$wf")
echo "   dan (write) submits to acme's Argo: ${out%% *} (want 200)"; [ "${out%% *}" = "200" ]
wf_name=$(printf '%s' "$out" | json_field name)
kubectl -n t-acme-argo wait "workflow/$wf_name" --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m
echo "   dan's workflow $wf_name succeeded"

echo "-- tenants: delegated admins (Keycloak admin API, fine-grained permissions v2)"
got=$(kc "$alice_t" PUT "/users/$bob_id/groups/$authors"); echo "   alice adds bob to /lab/authors: $got (want 204)"; [ "$got" = "204" ]
for target in "$pipelines:/lab/pipelines" "$research:/acme/research" "$platform:/platform-admins"; do
  got=$(kc "$alice_t" PUT "/users/$bob_id/groups/${target%%:*}"); echo "   alice adds bob to ${target#*:}: $got (want 403)"; [ "$got" = "403" ]
done
got=$(kc "$dan_t" PUT "/users/$cara_id/groups/$research_admins"); echo "   dan (tenant admin) makes cara an admin of /acme/research: $got (want 204)"; [ "$got" = "204" ]
got=$(kc "$dan_t" PUT "/users/$bob_id/groups/$authors"); echo "   dan adds bob to lab's /lab/authors: $got (want 403)"; [ "$got" = "403" ]
# Group structure is the tenants map's (a PR): Keycloak would give a group made
# at runtime no permissions, so nobody gets to create one.
got=$(kc "$dan_t" POST "/groups/$acme/children" '{"name":"ml"}'); echo "   dan creates /acme/ml: $got (want 403: structure is IaC)"; [ "$got" = "403" ]
gate "${P}dagster" dagster bob 200     # bob's new group reaches the shared Dagster on his next login
reset_memberships

echo "-- tenants: MLflow permissions (mlflow-oidc-auth)"
got=$(status_from verify "$pod" "$ML/api/2.0/mlflow/experiments/search?max_results=1"); echo "   anonymous API call: $got (want 401)"; [ "$got" = "401" ]
for u in sam ann alice cara; do
  got=$(kc_login "$ML/login" "$u" "/tmp/mlflow-$u.jar"); echo "   $u logs in to MLflow: $got"
done
# mlflow-auth-sync acts as its own ServiceAccount (a projected token for
# MLflow's audience), which MLflow's init container made an admin: service
# accounts, their tokens, the group patterns -- no human's token involved.
sa_call() { # sa_call <namespace> <method> <path>: as that namespace's default ServiceAccount
  local t
  t=$(kubectl -n "$1" create token default --audience "$ML" --duration 10m)
  in_pod curl -sS -o /dev/null -w '%{http_code}' -X "$2" -H "Authorization: Bearer $t" -H 'Content-Type: application/json' \
    --data '{"username":"verify-intruder","display_name":"x","is_admin":true}' "$ML$3"
}
got=$(sa_call verify GET /api/2.0/mlflow/users/current); echo "   a ServiceAccount outside MLflow's namespace: $got (want 401)"; [ "$got" = "401" ]
got=$(sa_call "${P}mlflow" POST /api/2.0/mlflow/users); echo "   another ServiceAccount in MLflow's namespace creates an admin: $got (want 403)"; [ "$got" = "403" ]
kubectl -n "${P}mlflow" delete job verify-auth-sync --ignore-not-found >/dev/null
kubectl -n "${P}mlflow" create job verify-auth-sync --from=cronjob/mlflow-auth-sync >/dev/null
kubectl -n "${P}mlflow" wait job/verify-auth-sync --for=condition=complete --timeout=3m
kubectl -n "${P}mlflow" logs job/verify-auth-sync | sed 's/^/   sync: /'
out=$(api /tmp/mlflow-ann.jar POST "$ML/api/2.0/mlflow/experiments/create" '{"name":"lab/x"}'); echo "   ann creates lab/x: ${out%% *} (want 200, or already there from an earlier run)"
[ "${out%% *}" = "200" ] || [[ "$out" == *RESOURCE_ALREADY_EXISTS* ]]
for pair in alice:200 sam:200 cara:403; do
  u=${pair%%:*}; want=${pair#*:}
  got=$(api "/tmp/mlflow-$u.jar" GET "$ML/api/2.0/mlflow/experiments/get-by-name?experiment_name=lab%2Fx" | cut -d' ' -f1)
  echo "   $u reads lab/x: $got (want $want)"
  if [ "$want" = "403" ]; then [ "$got" != "200" ]; else [ "$got" = "$want" ]; fi
done
creds=$(kubectl -n t-acme-dagster get secret mlflow-credentials -o jsonpath='{.data.MLFLOW_TRACKING_PASSWORD}' | base64 -d)
got=$(in_pod curl -sS -o /dev/null -w '%{http_code}' -u "svc-acme:$creds" "$ML/api/2.0/mlflow/experiments/search?max_results=1")
echo "   acme's service account (token delivered to t-acme-dagster) calls MLflow: $got (want 200)"; [ "$got" = "200" ]

echo "-- tenants: Ray scales a worker from zero (lab's stamp, head with num-cpus 0)"
head=$(kubectl -n t-lab-ray get pod -l ray.io/node-type=head -o name | head -1)
kubectl -n t-lab-ray exec "$head" -c ray-head -- timeout 420 python -c '
import ray
ray.init()
@ray.remote(num_cpus=1)
def f():
    return "ran on a worker"
print(ray.get(f.remote()))
' | sed 's/^/   /'
[ "$(kubectl -n t-lab-ray get pods -l ray.io/node-type=worker -o name | wc -l | tr -d ' ')" -ge 1 ]

echo "-- tenants: data"
url=$(tofu -chdir="$example" output -json group_role_urls | python3 -c 'import json,sys; print(json.load(sys.stdin)["/lab/authors"])')
# Over TCP with the role's password, from the Postgres pod (it has psql):
# `kubectl run --rm -i` lost the output of a psql that exits this fast.
who=$(kubectl -n postgres exec deploy/postgres -- psql "$url" -tAc 'select current_user' | tr -d '\r' | head -1) || true
echo "   nb_lab__authors connects: $who"; [ "$who" = "nb_lab__authors" ]

s3() { # s3 <namespace> <aws s3 args...>: as the stamp's identity
  kubectl -n "$1" run "s3-$RANDOM" --rm -i --quiet --restart=Never --image=amazon/aws-cli:2.36.49 \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"s3\",\"image\":\"amazon/aws-cli:2.36.49\",\"args\":[\"s3\",\"${2}\",\"${3}\"],\"envFrom\":[{\"secretRef\":{\"name\":\"ray-identity-env\"}}],\"env\":[{\"name\":\"AWS_ENDPOINT_URL\",\"value\":\"http://seaweedfs.seaweedfs.svc.cluster.local:8333\"},{\"name\":\"AWS_REGION\",\"value\":\"us-east-1\"}]}]}}" \
    -- s3 "$2" "$3" >/dev/null 2>&1
}
if s3 t-acme-ray ls s3://data; then echo "   acme's identity listed lab's bucket" >&2; exit 1; fi
echo "   acme's identity cannot list s3://data (lab's)"
s3 t-acme-ray ls s3://tenant-acme && echo "   acme's identity lists s3://tenant-acme"

acme_ray="http://t-acme-ray-cluster-head-svc.t-acme-ray.svc.cluster.local:8265/api/version"
probe_from() { # probe_from <namespace> <url> -> status (000 = refused)
  # The pause lets kubectl attach before a fast answer: `run --rm -i` can drop
  # the output of a pod that has already exited.
  kubectl -n "$1" run "probe-$RANDOM" --rm -i --quiet --restart=Never --image="$CURL_IMAGE" --command -- \
    sh -c "sleep 3; curl -sS -o /dev/null -w '%{http_code}' --max-time 8 '$2'" 2>/dev/null | grep -o '[0-9][0-9][0-9]' | tail -1 || true
}
got=$(probe_from t-lab-ray "$acme_ray"); echo "   lab's namespace -> acme's Ray head: $got (want 000)"; [ "$got" = "000" ]
got=$(probe_from t-acme-dagster "$acme_ray"); echo "   acme's Dagster namespace -> acme's Ray head: $got (want 200)"; [ "$got" = "200" ]

echo "-- tenants: an external tenant on a shared Dagster is refused at plan time"
bad='{"tenants":{"acme":{"trust":"external","groups":{"research":{}},"services":{"dagster":"shared"}}}}'
if out=$(tofu -chdir="$example" plan -input=false -lock=false -var-file=<(printf '%s' "$bad") 2>&1); then
  echo "   the plan accepted it" >&2; exit 1
fi
printf '%s\n' "$out" | grep -q "cannot be isolated" && echo "   refused: $(printf '%s\n' "$out" | grep -o 'acme: dagster[^(]*' | head -1)"
