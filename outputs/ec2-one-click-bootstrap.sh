#!/usr/bin/env bash
# Run with parameters, for example:
# bash <(curl -fsSL URL) --cf-api-token TOKEN --cf-zone-id ZONE_ID \
#   --flux-address HOST:PORT --flux-secret SECRET
# Do NOT commit a command containing real credentials.

set -euo pipefail

CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
FLUX_ADDRESS="${FLUX_ADDRESS:-}"
FLUX_SECRET="${FLUX_SECRET:-}"
DOMAIN="${DOMAIN:-2024.luneza.cc}"
DRY_RUN="${DRY_RUN:-false}"

SCRIPT_URL="https://raw.githubusercontent.com/Wety888/aws-cc-/main/outputs/cloudflare-ddns-and-flux-user-data.sh"

usage() {
    cat <<'EOF'
Usage:
  bash <(curl -fsSL URL) \
    --cf-api-token TOKEN --cf-zone-id ZONE_ID \
    --flux-address HOST:PORT --flux-secret SECRET [--domain DOMAIN] [--dry-run]
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
            --flux-address)
                require_value "$@"; FLUX_ADDRESS="$2"; shift 2 ;;
            --flux-secret)
                require_value "$@"; FLUX_SECRET="$2"; shift 2 ;;
            --domain)
                require_value "$@"; DOMAIN="$2"; shift 2 ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --help|-h)
                usage; exit 0 ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                usage
                exit 2 ;;
        esac
    done
}

main() {
    local script_file

    parse_arguments "$@"
    [[ -n "$CF_API_TOKEN" ]] || { printf 'Missing --cf-api-token\n' >&2; exit 2; }
    [[ "$CF_ZONE_ID" =~ ^[A-Fa-f0-9]{32}$ ]] || { printf 'Invalid or missing --cf-zone-id\n' >&2; exit 2; }
    [[ -n "$FLUX_ADDRESS" ]] || { printf 'Missing --flux-address\n' >&2; exit 2; }
    [[ -n "$FLUX_SECRET" ]] || { printf 'Missing --flux-secret\n' >&2; exit 2; }

    script_file="$(mktemp /tmp/ec2-ddns-bootstrap.XXXXXX)"
    trap 'rm -f "$script_file"' EXIT

    curl --fail --location --silent --show-error \
        --retry 10 --retry-delay 5 --retry-connrefused \
        --connect-timeout 10 --max-time 120 \
        "$SCRIPT_URL" --output "$script_file"
    chmod 700 "$script_file"

    CF_API_TOKEN="$CF_API_TOKEN" \
    CF_ZONE_ID="$CF_ZONE_ID" \
    DOMAIN="$DOMAIN" \
    FLUX_ADDRESS="$FLUX_ADDRESS" \
    FLUX_SECRET="$FLUX_SECRET" \
    DRY_RUN="$DRY_RUN" \
    bash "$script_file"
}

if [[ "${BOOTSTRAP_UNIT_TEST_MODE:-false}" != "true" ]]; then
    main "$@"
fi
