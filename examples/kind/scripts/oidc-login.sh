#!/bin/sh
# Log in to one oauth2-proxy through Dex, from INSIDE the cluster (this runs in
# verify.sh's curl pod: busybox sh + curl), and print two lines:
#   <final HTTP status>     200 = logged in and admitted to the upstream,
#                           403 = logged in but refused by the service's gate
#   <userinfo JSON or ->    oauth2-proxy's /oauth2/userinfo for the new session
#
# Usage: oidc-login.sh <proxy base URL> <issuer URL> local <email> <password>
#        oidc-login.sh <proxy base URL> <issuer URL> mock
#
# The dance: GET /oauth2/start -> Dex's connector chooser, whose links carry
# the whole authorization request (/dex/auth/<connector>?client_id=...) ->
# follow the connector's link: the mock connector logs in a fixed identity
# straight away; the local one shows its password form, whose action is
# /dex/auth/local/login?back=&state=<auth request id>, and gets the
# credentials posted -> Dex 303s through /approval (skipped) to the proxy's
# /oauth2/callback -> cookie set, 302 to the page first asked for -> the
# upstream answers, or the proxy answers 403.
set -eu

base="$1"
issuer="$2"
connector="$3"
email="${4:-}"
password="${5:-}"

jar=$(mktemp)
trap 'rm -f "$jar"' EXIT

# Dex's origin (scheme://host:port), for the root-relative links it renders.
origin=$(printf '%s' "$issuer" | sed -E 's#^(https?://[^/]+).*#\1#')

chooser=$(curl -sS -L -c "$jar" -b "$jar" "$base/oauth2/start?rd=%2F")
# href="/dex/auth/<connector>?...": HTML-unescape &amp; and &#43; (a literal +).
link=$(printf '%s' "$chooser" | grep -o "href=\"[^\"]*/auth/$connector?[^\"]*\"" | head -1 |
  sed -e 's/^href="//' -e 's/"$//' -e 's/&amp;/\&/g' -e 's/&#43;/+/g')
if [ -z "$link" ]; then
  echo "oidc-login: no link to connector '$connector' in Dex's response" >&2
  printf '%s\n' "$chooser" | grep -o 'href="[^"]*"' >&2 || true
  exit 1
fi

last=$(mktemp)
trap 'rm -f "$jar" "$last"' EXIT

# Follow the chain to its end; print "<status> <final url>".
follow() {
  curl -sS -L -c "$jar" -b "$jar" -o "$last" -w '%{http_code} %{url_effective}' "$@"
}

case "$connector" in
  local)
    # The form page: its action carries the auth request id Dex just created.
    form=$(curl -sS -L -c "$jar" -b "$jar" "$origin$link")
    action=$(printf '%s' "$form" | grep -o 'action="[^"]*"' | head -1 | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
    if [ -z "$action" ]; then
      echo "oidc-login: no password form at $link" >&2
      printf '%s\n' "$form" | head -30 >&2
      exit 1
    fi
    case "$action" in
      http*) post_url="$action" ;;
      *) post_url="$origin$action" ;;
    esac
    # -L turns the 303s into GETs down the rest of the chain.
    result=$(follow --data-urlencode "login=$email" --data-urlencode "password=$password" "$post_url")
    ;;
  mock)
    result=$(follow "$origin$link")
    ;;
  *)
    echo "oidc-login: connector must be local or mock" >&2
    exit 2
    ;;
esac

# A Dex that still shows its consent page (skipApprovalScreen off, or a client
# forcing approval_prompt) parks the chain at /approval?req=...; grant it.
final_url=${result#* }
case "$final_url" in
  */approval\?*)
    req=$(printf '%s' "$final_url" | grep -o 'req=[^&]*' | head -1 | cut -d= -f2)
    result=$(follow --data "req=$req&approval=approve" "$final_url")
    ;;
esac

echo "${result%% *}"
curl -sS -b "$jar" "$base/oauth2/userinfo" 2>/dev/null || echo "-"
