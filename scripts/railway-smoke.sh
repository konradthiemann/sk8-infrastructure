#!/usr/bin/env bash
# Smoke-tests a running SK8 installation (local compose or Railway) in one call.
#
#   make smoke                      Local compose defaults (see targets below)
#   SK8_BACKEND_URL=... make smoke  Explicit targets, e.g. against Railway
#
# Every check prints one line:
#   PASS  <name>
#   FAIL  <name>: <reason>
#   SKIP  <name>: <reason>
# SKIP is not a failure. Exit code is 0 only if no check FAILed.
#
# Targets (env wins over the default; an explicitly empty value SKIPs that
# target entirely, e.g. SK8_SKATE_URL= when a frontend is not deployed yet):
#   SK8_BACKEND_URL    default http://localhost:8000
#   SK8_DOCS_URL       default http://localhost:8001
#   SK8_SKATE_URL      default http://localhost:5173
#   SK8_NUTRITION_URL  default http://localhost:5174
#   SK8_HABITS_URL     default http://localhost:5175
#   SK8_API_KEY        default dev-key-change-me
#   SK8_CORS_ORIGINS   default: the three set frontend URLs above, comma-separated
#
# SK8_API_KEY never appears in the output, including under `bash -x`: it is
# only ever handed to curl via `--config -` (stdin), never as a `-H` argv
# token, so it never shows up in `ps` output or in a trace of this script's
# own commands (the same pattern `docker login --password-stdin` uses).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# --- Targets -----------------------------------------------------------
# Deliberate `${VAR-default}` (no colon): only a *missing* variable gets the
# default. An explicitly empty value (SK8_SKATE_URL=) stays empty and is
# treated by require_target() as "skip this target" - `${VAR:-default}`
# would also replace an empty value and make that distinction impossible.
SK8_BACKEND_URL="${SK8_BACKEND_URL-http://localhost:8000}"
SK8_DOCS_URL="${SK8_DOCS_URL-http://localhost:8001}"
SK8_SKATE_URL="${SK8_SKATE_URL-http://localhost:5173}"
SK8_NUTRITION_URL="${SK8_NUTRITION_URL-http://localhost:5174}"
SK8_HABITS_URL="${SK8_HABITS_URL-http://localhost:5175}"
SK8_API_KEY="${SK8_API_KEY:-dev-key-change-me}"

# --- Counters / output ---------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_NAMES=()

pass() {
  printf 'PASS  %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
  return 0
}

fail() {
  printf 'FAIL  %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_NAMES+=("$1")
  return 0
}

skip() {
  printf 'SKIP  %s: %s\n' "$1" "$2"
  SKIP_COUNT=$((SKIP_COUNT + 1))
  return 0
}

summary() {
  local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
  printf '\n%d PASS, %d FAIL, %d SKIP (%d Prüfungen insgesamt)\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$total"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf 'Fehlgeschlagen: %s\n' "${FAILED_NAMES[*]}"
  fi
  return 0
}

# require_target <VAR_NAME> <skip-reason> <check-name>...
# Skips every named check with `skip-reason` when VAR_NAME is empty, and
# returns 1 so the caller's block is not entered at all. Returns 0 when the
# target is usable.
require_target() {
  local var_name="$1" reason="$2"
  shift 2
  local value="${!var_name}"
  if [ -z "$value" ]; then
    local name
    for name in "$@"; do
      skip "$name" "$reason"
    done
    return 1
  fi
  return 0
}

# --- Temp files -----------------------------------------------------------
BODY_FILE="$(mktemp)"
HDR_FILE="$(mktemp)"
cleanup() { rm -f "$BODY_FILE" "$HDR_FILE"; }
trap cleanup EXIT

# --- curl helpers -----------------------------------------------------------
# The API key (when present) is passed to curl exclusively via `--config -`
# with a heredoc; it is never an argv token of any process (no leak via
# `ps aux`), and this script sets `set -x` nowhere, so a caller running it
# under `bash -x railway-smoke.sh` only ever traces the curl invocation
# line, never the heredoc's content.
curl_get() {
  local key="$1" url="$2"
  if [ -n "$key" ]; then
    curl -sS -o "$BODY_FILE" -D "$HDR_FILE" -w '%{http_code}' --config - "$url" <<CURLCFG || true
header = "X-Api-Key: ${key}"
CURLCFG
  else
    curl -sS -o "$BODY_FILE" -D "$HDR_FILE" -w '%{http_code}' "$url" || true
  fi
}

curl_post() {
  local key="$1" url="$2" data="$3"
  if [ -n "$key" ]; then
    curl -sS -o "$BODY_FILE" -D "$HDR_FILE" -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' --data-binary "$data" \
      --config - "$url" <<CURLCFG || true
header = "X-Api-Key: ${key}"
CURLCFG
  else
    curl -sS -o "$BODY_FILE" -D "$HDR_FILE" -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' --data-binary "$data" \
      "$url" || true
  fi
}

# host_of <url>: strips scheme and any path/query, leaving host[:port].
host_of() {
  local rest="${1#*://}"
  printf '%s' "${rest%%/*}"
}

# --- Check primitives -------------------------------------------------------
# check_get <name> <url> <expect-status> [--with-key] [--header-check "line"] [body-pattern...]
check_get() {
  local name="$1" url="$2" expect_status="$3"
  shift 3
  local use_key=0 header_check="" patterns=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-key) use_key=1; shift ;;
      --header-check) header_check="$2"; shift 2 ;;
      *) patterns+=("$1"); shift ;;
    esac
  done

  local key=""
  if [ "$use_key" -eq 1 ]; then key="$SK8_API_KEY"; fi

  local status
  status="$(curl_get "$key" "$url")"

  if [ "$status" != "$expect_status" ]; then
    fail "$name" "erwartet HTTP $expect_status, erhalten '${status:-keine Antwort}'"
    return 0
  fi

  if [ "${#patterns[@]}" -gt 0 ]; then
    local pattern
    for pattern in "${patterns[@]}"; do
      if ! grep -qF -- "$pattern" "$BODY_FILE"; then
        fail "$name" "Antwort enthält nicht: $pattern"
        return 0
      fi
    done
  fi

  if [ -n "$header_check" ]; then
    if ! grep -qi -- "$header_check" "$HDR_FILE"; then
      fail "$name" "Header-Zeile fehlt: $header_check"
      return 0
    fi
  fi

  pass "$name"
  return 0
}

# check_post <name> <url> <none|invalid|devkey|valid> <json-body> <expect-status> [body-pattern...]
check_post() {
  local name="$1" url="$2" key_mode="$3" data="$4" expect_status="$5"
  shift 5
  local patterns=("$@")
  local key=""
  case "$key_mode" in
    none) key="" ;;
    invalid) key="smoke-invalid-key" ;;
    devkey) key="dev-key-change-me" ;;
    valid) key="$SK8_API_KEY" ;;
  esac

  local status
  status="$(curl_post "$key" "$url" "$data")"

  if [ "$status" != "$expect_status" ]; then
    fail "$name" "erwartet HTTP $expect_status, erhalten '${status:-keine Antwort}'"
    return 0
  fi

  if [ "${#patterns[@]}" -gt 0 ]; then
    local pattern
    for pattern in "${patterns[@]}"; do
      if ! grep -qF -- "$pattern" "$BODY_FILE"; then
        fail "$name" "Antwort enthält nicht: $pattern"
        return 0
      fi
    done
  fi

  pass "$name"
  return 0
}

# check_preflight <name> <url> <origin> <allow|deny>
check_preflight() {
  local name="$1" url="$2" origin="$3" expect="$4"

  curl -sS -o /dev/null -D "$HDR_FILE" -X OPTIONS \
    -H "Origin: $origin" \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type,x-api-key' \
    "$url" || true

  local allow_origin=""
  if grep -qi '^access-control-allow-origin:' "$HDR_FILE" 2>/dev/null; then
    allow_origin="$(grep -i '^access-control-allow-origin:' "$HDR_FILE" | tail -n1 | tr -d '\r' | cut -d' ' -f2-)"
  fi

  case "$expect" in
    allow)
      if [ "$allow_origin" != "$origin" ]; then
        fail "$name" "Access-Control-Allow-Origin ist '${allow_origin:-keiner}', erwartet '$origin'"
        return 0
      fi
      if ! grep -qi '^access-control-allow-headers:.*x-api-key' "$HDR_FILE"; then
        fail "$name" "Access-Control-Allow-Headers enthält kein X-Api-Key"
        return 0
      fi
      pass "$name"
      ;;
    deny)
      if [ -n "$allow_origin" ]; then
        fail "$name" "unerwartetes Access-Control-Allow-Origin für fremden Origin: $allow_origin"
        return 0
      fi
      pass "$name"
      ;;
  esac
  return 0
}

# --- Frontend check group (checks 12-18 of the ticket, run per app) --------
run_frontend_checks() {
  local slug="$1" url="$2"
  local backend_host
  backend_host="$(host_of "$SK8_BACKEND_URL")"

  check_get "$slug-root" "$url/" 200 '<div id="root">'
  check_get "$slug-manifest" "$url/manifest.webmanifest" 200 '"display":"standalone"' '"lang":"de"'
  check_get "$slug-sw" "$url/sw.js" 200
  check_get "$slug-registersw" "$url/registerSW.js" 200

  local index_body entry
  index_body="$(curl -sS "$url/" || true)"
  entry="$(printf '%s' "$index_body" | grep -o 'src="/assets/[^"]*\.js"' | head -n1 | sed 's/^src="//; s/"$//' || true)"

  if [ -z "$entry" ]; then
    fail "$slug-bundle-apiurl" "kein gehashtes JS-Bundle in index.html gefunden"
  else
    check_get "$slug-bundle-apiurl" "$url$entry" 200 "$backend_host"
  fi

  check_get "$slug-spa-fallback" "$url/smoke-not-found-$RANDOM$RANDOM" 200 '<div id="root">'

  check_get "$slug-cache-root" "$url/" 200 --header-check 'cache-control: no-cache'

  if [ -z "$entry" ]; then
    fail "$slug-cache-assets" "kein /assets/-Pfad bekannt (Bundle-Suche fehlgeschlagen)"
  else
    check_get "$slug-cache-assets" "$url$entry" 200 --header-check 'cache-control: public, max-age=31536000, immutable'
  fi
}

# --- Telemetry payloads ------------------------------------------------------
OCCURRED_AT="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
EVENT_VALID='{"app":"skate","sessionId":"00000000-0000-4000-8000-000000000000","events":[{"type":"screen_view","screen":"smoke-test","occurredAt":"'"$OCCURRED_AT"'"}]}'
EVENT_INVALID='{"app":"skate","sessionId":"00000000-0000-4000-8000-000000000000","events":[{"type":"kaputt","screen":"smoke-test","occurredAt":"'"$OCCURRED_AT"'"}]}'

# --- CORS origins default (only used when SK8_CORS_ORIGINS is unset,
# not when it is explicitly set to an empty string) --------------------------
default_cors_origins() {
  local parts=()
  if [ -n "$SK8_SKATE_URL" ]; then parts+=("$SK8_SKATE_URL"); fi
  if [ -n "$SK8_NUTRITION_URL" ]; then parts+=("$SK8_NUTRITION_URL"); fi
  if [ -n "$SK8_HABITS_URL" ]; then parts+=("$SK8_HABITS_URL"); fi
  if [ "${#parts[@]}" -eq 0 ]; then
    printf ''
    return 0
  fi
  local IFS=','
  printf '%s' "${parts[*]}"
}

if [ -z "${SK8_CORS_ORIGINS+x}" ]; then
  SK8_CORS_ORIGINS="$(default_cors_origins)"
fi

# --- Backend (checks 1-9) ----------------------------------------------------
if require_target SK8_BACKEND_URL "SK8_BACKEND_URL leer gesetzt" \
    health telemetry-no-key telemetry-invalid-key telemetry-devkey-in-prod \
    telemetry-accepted telemetry-validation cors-fremd openapi ai-endpoints; then

  check_get "health" "$SK8_BACKEND_URL/api/health" 200 '"status":"ok"' '"time"'

  check_post "telemetry-no-key" "$SK8_BACKEND_URL/api/telemetry/events" none \
    "$EVENT_VALID" 401 '"error":"unauthorized"'

  check_post "telemetry-invalid-key" "$SK8_BACKEND_URL/api/telemetry/events" invalid \
    "$EVENT_VALID" 401 '"error":"unauthorized"'

  if [ "$SK8_API_KEY" = "dev-key-change-me" ]; then
    skip "telemetry-devkey-in-prod" "SK8_API_KEY ist der Entwicklungsschlüssel (lokaler Lauf)"
  else
    check_post "telemetry-devkey-in-prod" "$SK8_BACKEND_URL/api/telemetry/events" devkey \
      "$EVENT_VALID" 401 '"error":"unauthorized"'
  fi

  check_post "telemetry-accepted" "$SK8_BACKEND_URL/api/telemetry/events" valid \
    "$EVENT_VALID" 202 '"accepted":1'

  check_post "telemetry-validation" "$SK8_BACKEND_URL/api/telemetry/events" valid \
    "$EVENT_INVALID" 422 '"error":"validation_failed"'

  if [ -n "$SK8_CORS_ORIGINS" ]; then
    origins=()
    IFS=',' read -r -a origins <<< "$SK8_CORS_ORIGINS" || true
    for origin in "${origins[@]}"; do
      if [ -n "$origin" ]; then
        check_preflight "cors-$origin" "$SK8_BACKEND_URL/api/telemetry/events" "$origin" allow
      fi
    done
  fi
  check_preflight "cors-fremd" "$SK8_BACKEND_URL/api/telemetry/events" "https://example.invalid" deny

  check_get "openapi" "$SK8_BACKEND_URL/api/doc.json" 200

  ai_paths="$(grep -o '"/api/ai[^"]*"' "$BODY_FILE" 2>/dev/null | tr -d '"' | sort -u || true)"
  if [ -z "$ai_paths" ]; then
    skip "ai-endpoints" "kein /api/ai-Pfad im OpenAPI-Dokument (Stand 9. September 2026: keine KI-Route implementiert)"
  else
    while IFS= read -r ai_path; do
      if [ -n "$ai_path" ]; then
        check_get "ai-$ai_path" "$SK8_BACKEND_URL$ai_path" 503 --with-key
      fi
    done <<< "$ai_paths"
  fi
fi

# --- Docs (checks 10-11) -----------------------------------------------------
if require_target SK8_DOCS_URL "SK8_DOCS_URL leer gesetzt" docs-health docs-index; then
  check_get "docs-health" "$SK8_DOCS_URL/health" 200 '"status":"ok"'
  check_get "docs-index" "$SK8_DOCS_URL/" 200 --header-check 'content-type: text/html'
fi

# --- Frontends (checks 12-18, per app) ---------------------------------------
if require_target SK8_SKATE_URL "SK8_SKATE_URL leer gesetzt" \
    skate-root skate-manifest skate-sw skate-registersw skate-bundle-apiurl \
    skate-spa-fallback skate-cache-root skate-cache-assets; then
  run_frontend_checks skate "$SK8_SKATE_URL"
fi

if require_target SK8_NUTRITION_URL "SK8_NUTRITION_URL leer gesetzt" \
    nutrition-root nutrition-manifest nutrition-sw nutrition-registersw nutrition-bundle-apiurl \
    nutrition-spa-fallback nutrition-cache-root nutrition-cache-assets; then
  run_frontend_checks nutrition "$SK8_NUTRITION_URL"
fi

if require_target SK8_HABITS_URL "SK8_HABITS_URL leer gesetzt" \
    habits-root habits-manifest habits-sw habits-registersw habits-bundle-apiurl \
    habits-spa-fallback habits-cache-root habits-cache-assets; then
  run_frontend_checks habits "$SK8_HABITS_URL"
fi

summary
[ "$FAIL_COUNT" -eq 0 ]
