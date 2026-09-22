#!/bin/sh
# Log in to a relying party through Dex, from INSIDE the cluster (this runs in
# verify.sh's curl pod: busybox sh + curl), and print the final HTTP status:
# 200 = logged in and admitted, 403 = logged in but refused by the gate.
#
# Usage: oidc-login.sh <start URL> <issuer URL> local    <email> <password>
#        oidc-login.sh <start URL> <issuer URL> mock
#        oidc-login.sh <start URL> <issuer URL> keycloak <username> <password>
#
#   start URL      what begins the login: <proxy>/oauth2/start?rd=%2F for an
#                  oauth2-proxy, <argo>/oauth2/redirect?redirect=/workflows for
#                  Argo, <mlflow>/login for MLflow's plugin
#   JAR            keep the session's cookies in this file (default: a temp
#                  file, removed at exit), for API calls after the login
#   USERINFO_URL   also print what this URL answers with the new session
#
# The dance: the start URL redirects to Dex. With several connectors Dex shows
# a chooser whose links carry the whole authorization request
# (/dex/auth/<connector>?...); with one it redirects straight on. mock logs a
# fixed identity in; local shows Dex's password form; keycloak lands on the
# realm's login form (id="kc-form-login"). The credentials are posted to the
# form's action, and the 30x chain runs back through Dex (skipping /approval,
# or granting it) to the relying party's callback, which sets its session.
set -eu

start="$1"
issuer="$2"
connector="$3"
user="${4:-}"
password="${5:-}"

jar="${JAR:-}"
tmp_jar=""
if [ -z "$jar" ]; then
  jar=$(mktemp)
  tmp_jar="$jar"
fi
last=$(mktemp)
trap 'rm -f "$last" $tmp_jar' EXIT

origin() { printf '%s' "$1" | sed -E 's#^(https?://[^/]+).*#\1#'; }
unescape() { sed -e 's/&amp;/\&/g' -e 's/&#43;/+/g' -e 's/&#x3d;/=/g'; }
absolute() {
  case "$1" in
    http*) printf '%s' "$1" ;;
    *) printf '%s%s' "$(origin "$2")" "$1" ;;
  esac
}

# Follow a chain to its end; print "<status> <final url>", the body in $last.
follow() {
  curl -sS -L -c "$jar" -b "$jar" -o "$last" -w '%{http_code} %{url_effective}' "$@"
}

result=$(follow "$start")
page_url=${result#* }

# Dex's chooser (several connectors): follow the chosen connector's link.
link=$(grep -o "href=\"[^\"]*/auth/$connector?[^\"]*\"" "$last" | head -1 | sed -e 's/^href="//' -e 's/"$//' | unescape || true)
if [ -n "$link" ]; then
  result=$(follow "$(absolute "$link" "$issuer")")
  page_url=${result#* }
fi

post_form() {
  # $1 = form marker, $2 = user field; the rest of the fields are fixed.
  action=$(grep -o "<form[^>]*$1[^>]*>" "$last" | grep -o 'action="[^"]*"' | head -1 | sed -e 's/^action="//' -e 's/"$//' | unescape)
  if [ -z "$action" ]; then
    action=$(grep -o 'action="[^"]*"' "$last" | head -1 | sed -e 's/^action="//' -e 's/"$//' | unescape)
  fi
  if [ -z "$action" ]; then
    echo "oidc-login: no login form at $page_url" >&2
    head -40 "$last" >&2
    exit 1
  fi
  follow --data-urlencode "$2=$user" --data-urlencode "password=$password" "$(absolute "$action" "$page_url")"
}

case "$connector" in
  mock) ;;
  local) result=$(post_form 'method="post"' login) ;;
  keycloak) result=$(post_form 'id="kc-form-login"' username) ;;
  *)
    echo "oidc-login: connector must be local, mock or keycloak" >&2
    exit 2
    ;;
esac

# A Dex that still shows its consent page parks the chain at /approval?req=...
final_url=${result#* }
case "$final_url" in
  */approval\?*)
    req=$(printf '%s' "$final_url" | grep -o 'req=[^&]*' | head -1 | cut -d= -f2)
    result=$(follow --data "req=$req&approval=approve" "$final_url")
    ;;
esac

# Still at the identity provider (a form it wants filled, an error page): the
# login did not complete, whatever the status code says.
final_url=${result#* }
case "$final_url" in
  "$(origin "$issuer")"* | */realms/*/login-actions/* | */realms/*/protocol/*)
    echo "oidc-login: the login stopped at $final_url" >&2
    grep -o '<title>[^<]*' "$last" >&2 || true
    exit 1
    ;;
esac

echo "${result%% *}"
if [ -n "${USERINFO_URL:-}" ]; then
  curl -sS -b "$jar" "$USERINFO_URL" 2>/dev/null || echo "-"
fi
