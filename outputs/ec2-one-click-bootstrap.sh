#!/usr/bin/env bash
# Run with parameters, for example:
# bash <(curl -fsSL URL) --cf-api-token TOKEN --cf-zone-id ZONE_ID \
#   --flux-address HOST:PORT --flux-secret SECRET [--cf-zone-name ZONE_NAME]
# Do NOT commit a command containing real credentials.

set -euo pipefail

CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_ZONE_NAME="${CF_ZONE_NAME:-}"
FLUX_ADDRESS="${FLUX_ADDRESS:-}"
FLUX_SECRET="${FLUX_SECRET:-}"
DOMAIN="${DOMAIN:-host.example.com}"
DRY_RUN="${DRY_RUN:-false}"
PERIODIC_SETUP_ONLY="${PERIODIC_SETUP_ONLY:-false}"

SCRIPT_URL="https://raw.githubusercontent.com/Wety888/aws-cc-/main/outputs/cloudflare-ddns-and-flux-user-data.sh"
SCRIPT_FILE=""

cleanup() {
    [[ -n "$SCRIPT_FILE" ]] && rm -f "$SCRIPT_FILE"
}

trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage:
  bash <(curl -fsSL URL) \
    --cf-api-token TOKEN --flux-address HOST:PORT --flux-secret SECRET \
    [--cf-zone-name ZONE_NAME] [--domain DOMAIN] [--dry-run] [--enable-periodic-only]

--cf-zone-id is optional. When both it and --cf-zone-name are omitted, the
script selects the longest active Cloudflare zone matching --domain.
EOF
}

require_value() {
    [[ $# -ge 2 && -n "$2" ]] || {
        printf 'Missing value for %s\n' "$1" >&2
        exit 2
    }
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --cf-api-token)
                require_value "$@"; CF_API_TOKEN="$2"; shift 2 ;;
            --cf-zone-id)
                require_value "$@"; CF_ZONE_ID="$2"; shift 2 ;;
            --cf-zone-name)
                require_value "$@"; CF_ZONE_NAME="$2"; shift 2 ;;
            --flux-address)
                require_value "$@"; FLUX_ADDRESS="$2"; shift 2 ;;
            --flux-secret)
                require_value "$@"; FLUX_SECRET="$2"; shift 2 ;;
            --domain)
                require_value "$@"; DOMAIN="$2"; shift 2 ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --enable-periodic-only)
                PERIODIC_SETUP_ONLY=true; shift ;;
            --help|-h)
                usage; exit 0 ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                usage
                exit 2 ;;
        esac
    done
}

resolve_zone_id() {
    local encoded_zone response zone_url zone_label

    [[ -n "$CF_ZONE_ID" ]] && return 0

    command -v python3 >/dev/null 2>&1 || {
        printf 'python3 is required to resolve the Cloudflare Zone ID automatically.\n' >&2
        exit 1
    }

    if [[ -n "$CF_ZONE_NAME" ]]; then
        encoded_zone="$(python3 -c 'import sys; from urllib.parse import quote; print(quote(sys.argv[1], safe=""))' "$CF_ZONE_NAME")"
        zone_url="https://api.cloudflare.com/client/v4/zones?name=${encoded_zone}&status=active"
        zone_label="$CF_ZONE_NAME"
    else
        zone_url="https://api.cloudflare.com/client/v4/zones?status=active&per_page=50"
        zone_label="a zone matching ${DOMAIN}"
    fi
    if ! response="$(
        curl --fail --location --silent --show-error \
            --retry 10 --retry-delay 5 --retry-connrefused \
            --connect-timeout 10 --max-time 120 \
            --header "Authorization: Bearer ${CF_API_TOKEN}" \
            "$zone_url"
    )"; then
        printf 'Unable to query Cloudflare for the Zone ID of %s.\n' "$zone_label" >&2
        exit 1
    fi

    if ! CF_ZONE_ID="$(RESPONSE="$response" DOMAIN="$DOMAIN" CF_ZONE_NAME="$CF_ZONE_NAME" python3 -c '
import json
import os
import sys

data = json.loads(os.environ["RESPONSE"])
records = data.get("result") or []
requested_zone = os.environ["CF_ZONE_NAME"].rstrip(".").lower()
domain = os.environ["DOMAIN"].rstrip(".").lower()
if requested_zone:
    matches = [record for record in records if record.get("name", "").rstrip(".").lower() == requested_zone]
else:
    matches = [
        record for record in records
        if domain == record.get("name", "").rstrip(".").lower()
        or domain.endswith("." + record.get("name", "").rstrip(".").lower())
    ]
    matches.sort(key=lambda record: len(record.get("name", "")), reverse=True)
    if len(matches) > 1 and len(matches[0].get("name", "")) == len(matches[1].get("name", "")):
        matches = []
if data.get("success") is not True or len(matches) != 1:
    errors = data.get("errors") or []
    detail = "; ".join(str(item.get("message", "unknown error")) for item in errors)
    raise SystemExit(detail or "expected exactly one matching active zone")
print(matches[0]["id"])
')"; then
        printf 'Cloudflare Zone ID lookup failed for %s.\n' "$zone_label" >&2
        exit 1
    fi
}

main() {
    parse_arguments "$@"
    [[ -n "$CF_API_TOKEN" ]] || { printf 'Missing --cf-api-token\n' >&2; exit 2; }
    resolve_zone_id
    [[ "$CF_ZONE_ID" =~ ^[A-Fa-f0-9]{32}$ ]] || { printf 'Invalid or missing --cf-zone-id\n' >&2; exit 2; }
    if [[ "$PERIODIC_SETUP_ONLY" != "true" ]]; then
        [[ -n "$FLUX_ADDRESS" ]] || { printf 'Missing --flux-address\n' >&2; exit 2; }
        [[ -n "$FLUX_SECRET" ]] || { printf 'Missing --flux-secret\n' >&2; exit 2; }
    fi

    SCRIPT_FILE="$(mktemp /tmp/ec2-ddns-bootstrap.XXXXXX)"

    curl --fail --location --silent --show-error \
        --retry 10 --retry-delay 5 --retry-connrefused \
        --connect-timeout 10 --max-time 120 \
        "$SCRIPT_URL" --output "$SCRIPT_FILE"
    chmod 700 "$SCRIPT_FILE"

    CF_API_TOKEN="$CF_API_TOKEN" \
    CF_ZONE_ID="$CF_ZONE_ID" \
    DOMAIN="$DOMAIN" \
    FLUX_ADDRESS="$FLUX_ADDRESS" \
    FLUX_SECRET="$FLUX_SECRET" \
    DRY_RUN="$DRY_RUN" \
    PERIODIC_SETUP_ONLY="$PERIODIC_SETUP_ONLY" \
    bash "$SCRIPT_FILE"
}

if [[ "${BOOTSTRAP_UNIT_TEST_MODE:-false}" != "true" ]]; then
    main "$@"
fi
