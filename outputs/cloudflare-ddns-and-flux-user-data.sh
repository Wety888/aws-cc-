#!/usr/bin/env bash
# AWS EC2 User Data: Cloudflare DNS-only DDNS + Flux Panel installer
# Supports Ubuntu 22.04/24.04 and Debian 12.
#
# SECURITY: This file contains placeholders only. Do not commit a populated
# version to source control. EC2 User Data can be read by privileged instance
# users and principals that can inspect launch-template/user-data settings.

set -euo pipefail

###############################################################################
# Required configuration -- replace every placeholder before deployment.
###############################################################################
CF_API_TOKEN="${CF_API_TOKEN:-REPLACE_WITH_A_NEW_CLOUDFLARE_API_TOKEN}"
CF_ZONE_ID="${CF_ZONE_ID:-REPLACE_WITH_YOUR_32_CHARACTER_CLOUDFLARE_ZONE_ID}"
DOMAIN="${DOMAIN:-2024.luneza.cc}"

# Flux Panel installation. Keep this disabled only if DDNS is all you need.
FLUX_INSTALL_ENABLED="${FLUX_INSTALL_ENABLED:-true}"
FLUX_INSTALL_URL="${FLUX_INSTALL_URL:-https://github.com/bqlpfy/flux-panel/releases/download/1.4.3/install.sh}"
FLUX_ADDRESS="${FLUX_ADDRESS:-REPLACE_WITH_HOST_OR_IP_AND_PORT}" # Example: 203.0.113.10:6365
FLUX_SECRET="${FLUX_SECRET:-REPLACE_WITH_A_NEW_FLUX_SECRET}"

###############################################################################
# Optional configuration
###############################################################################
DNS_TTL=300
RETRY_COUNT=10
RETRY_INTERVAL=5
CONNECT_TIMEOUT=3
MAX_TIME=10
FLUX_INSTALL_MAX_TIME=600
LOG_FILE="/var/log/cloudflare-ddns.log"
SYSCTL_FILE="/etc/sysctl.d/99-ec2-bbr-tuning.conf"
DDNS_SCRIPT_FILE="/usr/local/sbin/cloudflare-ddns-sync"
DDNS_ENV_FILE="/etc/cloudflare-ddns.env"
DDNS_SERVICE_FILE="/etc/systemd/system/cloudflare-ddns.service"
DDNS_TIMER_FILE="/etc/systemd/system/cloudflare-ddns.timer"
DDNS_TIMER_RUN="${DDNS_TIMER_RUN:-false}"
PERIODIC_SETUP_ONLY="${PERIODIC_SETUP_ONLY:-false}"
DRY_RUN="${DRY_RUN:-false}" # true: never change sysctl/DNS or install Flux

if [[ "${DDNS_UNIT_TEST_MODE:-false}" != "true" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

log() {
    printf '[%s] %s\n' "$(date -Is)" "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_valid_ipv4() {
    IP_TO_VALIDATE="$1" python3 -c '
import ipaddress
import os
import sys
try:
    ipaddress.IPv4Address(os.environ["IP_TO_VALIDATE"])
except ValueError:
    sys.exit(1)
'
}

cf_success() {
    RESPONSE="$1" python3 -c '
import json
import os
try:
    print("true" if json.loads(os.environ["RESPONSE"]).get("success") is True else "false")
except Exception:
    print("false")
'
}

cf_error_message() {
    RESPONSE="$1" python3 -c '
import json
import os

raw = os.environ["RESPONSE"]
try:
    data = json.loads(raw)
    details = data.get("errors") or data.get("messages") or []
    if details:
        print("; ".join(
            "[{}] {}".format(item.get("code", "unknown"), item.get("message", "unknown error"))
            for item in details
        ))
    else:
        print("Cloudflare returned success=false without a detailed error.")
except Exception:
    print("Non-JSON API response: " + raw[:500].replace("\n", " "))
'
}

get_imdsv2_public_ipv4() {
    local token ip

    if ! token="$(
        curl --silent --show-error \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            --request PUT \
            --header "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
            "http://169.254.169.254/latest/api/token"
    )"; then
        return 1
    fi

    [[ -n "$token" ]] || return 1

    if ! ip="$(
        curl --silent --show-error \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            --header "X-aws-ec2-metadata-token: $token" \
            "http://169.254.169.254/latest/meta-data/public-ipv4"
    )"; then
        return 1
    fi

    printf '%s' "$ip"
}

get_fallback_public_ipv4() {
    local service ip
    local -a services=(
        "https://checkip.amazonaws.com"
        "https://api.ipify.org"
    )

    for service in "${services[@]}"; do
        if ip="$(
            curl --silent --show-error \
                --connect-timeout "$CONNECT_TIMEOUT" \
                --max-time "$MAX_TIME" \
                "$service"
        )"; then
            ip="${ip//$'\r'/}"
            ip="${ip//$'\n'/}"
            if is_valid_ipv4 "$ip"; then
                printf '%s' "$ip"
                return 0
            fi
        fi
    done

    return 1
}

get_current_public_ipv4() {
    local attempt ip

    for ((attempt = 1; attempt <= RETRY_COUNT; attempt++)); do
        if ip="$(get_imdsv2_public_ipv4)" && is_valid_ipv4 "$ip"; then
            log "Public IPv4 source: AWS IMDSv2"
            printf '%s' "$ip"
            return 0
        fi

        if ip="$(get_fallback_public_ipv4)" && is_valid_ipv4 "$ip"; then
            log "Public IPv4 source: fallback public-IP service"
            printf '%s' "$ip"
            return 0
        fi

        log "Unable to obtain a valid public IPv4 (attempt ${attempt}/${RETRY_COUNT})."
        if (( attempt < RETRY_COUNT )); then
            sleep "$RETRY_INTERVAL"
        fi
    done

    return 1
}

cf_api() {
    local method="$1"
    local url="$2"
    local payload="${3:-}"
    local attempt response
    local -a args

    for ((attempt = 1; attempt <= RETRY_COUNT; attempt++)); do
        args=(
            --silent
            --show-error
            --connect-timeout "$CONNECT_TIMEOUT"
            --max-time "$MAX_TIME"
            --request "$method"
            --header "Authorization: Bearer ${CF_API_TOKEN}"
            --header "Content-Type: application/json"
        )
        [[ -n "$payload" ]] && args+=(--data "$payload")

        if response="$(curl "${args[@]}" "$url")"; then
            if [[ "$(cf_success "$response")" == "true" ]]; then
                printf '%s' "$response"
                return 0
            fi
            log "Cloudflare API failure (attempt ${attempt}/${RETRY_COUNT}): $(cf_error_message "$response")"
        else
            log "Cloudflare API connection failure (attempt ${attempt}/${RETRY_COUNT})."
        fi

        if (( attempt < RETRY_COUNT )); then
            sleep "$RETRY_INTERVAL"
        fi
    done

    return 1
}

apply_tcp_tuning() {
    local available_cc interface attempt

    if [[ "$DRY_RUN" == "true" ]]; then
        log "Dry run: TCP/BBR tuning skipped."
        return 0
    fi

    require_command sysctl
    require_command ip
    require_command tc

    # These modules may already be built into the Ubuntu/Debian kernel.
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr 2>/dev/null || true
        modprobe sch_fq 2>/dev/null || true
    fi

    if ! available_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control)"; then
        die "Unable to read the available TCP congestion-control algorithms."
    fi
    if ! grep -qw bbr <<< "$available_cc"; then
        die "The running kernel does not provide BBR; refusing to apply incomplete TCP tuning."
    fi

    cat > "$SYSCTL_FILE" <<'EOF'
# Managed by cloudflare-ddns-and-flux-user-data.sh
# AWS EC2 TCP tuning: BBR + FQ
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Per-socket buffer ceilings: 16 MiB
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_moderate_rcvbuf = 1

# Path and connection behaviour
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# Connection and packet queues
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 8192
EOF

    if ! sysctl --load="$SYSCTL_FILE"; then
        die "Failed to load TCP tuning from $SYSCTL_FILE."
    fi

    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] ||
        die "BBR was not enabled after loading sysctl settings."
    [[ "$(sysctl -n net.core.default_qdisc)" == "fq" ]] ||
        die "FQ was not set as the default queue discipline."

    # net.core.default_qdisc affects future interfaces. Apply FQ immediately to
    # the already-created EC2 primary interface as well.
    interface=""
    for ((attempt = 1; attempt <= RETRY_COUNT; attempt++)); do
        interface="$(ip -o route show default 2>/dev/null | awk 'NR==1 {print $5}')"
        if [[ -n "$interface" ]]; then
            break
        fi
        if (( attempt < RETRY_COUNT )); then
            sleep "$RETRY_INTERVAL"
        fi
    done
    [[ -n "$interface" ]] || die "Could not determine the default EC2 network interface."

    if ! tc qdisc replace dev "$interface" root fq; then
        die "Could not apply the FQ queue discipline to interface $interface."
    fi
    if ! tc qdisc show dev "$interface" | grep -q '^qdisc fq '; then
        die "FQ is not active on interface $interface after applying TCP tuning."
    fi

    log "TCP tuning applied: BBR + FQ on ${interface}; settings persist in ${SYSCTL_FILE}."
}

install_periodic_ddns() {
    if [[ "$DDNS_TIMER_RUN" == "true" ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "Dry run: periodic DDNS systemd timer setup skipped."
        return 0
    fi

    require_command install
    require_command systemctl

    # Only values needed by the periodic DNS-only process are persisted. The
    # Flux secret is deliberately not saved because timer runs never install Flux.
    [[ "$CF_API_TOKEN" != *$'\n'* && "$CF_ZONE_ID" != *$'\n'* && "$DOMAIN" != *$'\n'* ]] ||
        die "DDNS configuration values must not contain newlines."

    install -m 700 "$0" "$DDNS_SCRIPT_FILE"
    (
        umask 077
        cat > "$DDNS_ENV_FILE" <<EOF
CF_API_TOKEN=${CF_API_TOKEN}
CF_ZONE_ID=${CF_ZONE_ID}
DOMAIN=${DOMAIN}
DRY_RUN=false
EOF
    )
    chmod 600 "$DDNS_ENV_FILE"

    cat > "$DDNS_SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare DDNS synchronization for EC2 public IPv4
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${DDNS_ENV_FILE}
Environment=DDNS_TIMER_RUN=true
Environment=FLUX_INSTALL_ENABLED=false
ExecStart=${DDNS_SCRIPT_FILE}
EOF

    cat > "$DDNS_TIMER_FILE" <<'EOF'
[Unit]
Description=Periodically synchronize EC2 public IPv4 to Cloudflare DNS

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
Persistent=true
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now cloudflare-ddns.timer
    log "Periodic DDNS enabled: starts about 30 seconds after boot, then every 1 minute."
}

install_flux_panel() {
    local installer_file attempt

    if [[ "$DRY_RUN" == "true" ]]; then
        log "Dry run: Flux installer execution skipped."
        return 0
    fi

    [[ "$FLUX_INSTALL_ENABLED" == "true" ]] || {
        log "Flux installation: skipped (FLUX_INSTALL_ENABLED=false)"
        return 0
    }

    [[ -n "$FLUX_ADDRESS" && "$FLUX_ADDRESS" != "REPLACE_WITH_HOST_OR_IP_AND_PORT" ]] ||
        die "Set FLUX_ADDRESS before enabling Flux installation."
    [[ -n "$FLUX_SECRET" && "$FLUX_SECRET" != "REPLACE_WITH_A_NEW_FLUX_SECRET" ]] ||
        die "Set FLUX_SECRET before enabling Flux installation."

    installer_file="$(mktemp /tmp/flux-panel-install.XXXXXX)"
    for ((attempt = 1; attempt <= RETRY_COUNT; attempt++)); do
        if curl --fail --location --silent --show-error \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time 120 \
            "$FLUX_INSTALL_URL" \
            --output "$installer_file"; then
            break
        fi

        log "Flux installer download failed (attempt ${attempt}/${RETRY_COUNT})."
        if (( attempt < RETRY_COUNT )); then
            sleep "$RETRY_INTERVAL"
        fi
    done

    if [[ ! -s "$installer_file" ]]; then
        rm -f "$installer_file"
        die "Flux installer could not be downloaded."
    fi
    chmod 700 "$installer_file"

    log "Flux installation: starting non-interactive installer."
    if ! timeout "$FLUX_INSTALL_MAX_TIME" \
        bash "$installer_file" -a "$FLUX_ADDRESS" -s "$FLUX_SECRET" < /dev/null; then
        rm -f "$installer_file"
        die "Flux installation failed or exceeded ${FLUX_INSTALL_MAX_TIME} seconds."
    fi

    rm -f "$installer_file"
    log "Flux installation: completed successfully."
}

main() {
    local dns_name encoded_dns_name current_ip api_base query_response
    local record_count record_info record_id cf_current_ip cf_proxied record_payload

    require_command curl
    require_command python3
    require_command timeout

    [[ -n "$CF_API_TOKEN" && "$CF_API_TOKEN" != "REPLACE_WITH_A_NEW_CLOUDFLARE_API_TOKEN" ]] ||
        die "Set CF_API_TOKEN before running this script."
    [[ "$CF_ZONE_ID" =~ ^[A-Fa-f0-9]{32}$ ]] ||
        die "CF_ZONE_ID must be a 32-character hexadecimal Cloudflare Zone ID."
    [[ -n "$DOMAIN" ]] || die "Set DOMAIN before running this script."
    [[ "$DNS_TTL" =~ ^[0-9]+$ && "$DNS_TTL" -ge 60 ]] ||
        die "DNS_TTL must be a supported positive DNS-only TTL, such as 300."
    [[ "$DRY_RUN" == "true" || "$DRY_RUN" == "false" ]] ||
        die "DRY_RUN must be either true or false."
    [[ "$PERIODIC_SETUP_ONLY" == "true" || "$PERIODIC_SETUP_ONLY" == "false" ]] ||
        die "PERIODIC_SETUP_ONLY must be either true or false."

    if [[ "$DDNS_TIMER_RUN" == "true" || "$PERIODIC_SETUP_ONLY" == "true" ]]; then
        log "Periodic DDNS mode: skipping one-time TCP tuning and Flux installation."
    else
        apply_tcp_tuning
    fi

    if ! dns_name="$(python3 -c 'import sys; print(sys.argv[1].rstrip(".").encode("idna").decode("ascii").lower())' "$DOMAIN")"; then
        die "DOMAIN is invalid: $DOMAIN"
    fi
    encoded_dns_name="$(python3 -c 'import sys; from urllib.parse import quote; print(quote(sys.argv[1], safe=""))' "$dns_name")"

    if ! current_ip="$(get_current_public_ipv4)"; then
        die "Could not obtain a valid public IPv4 after ${RETRY_COUNT} attempts."
    fi
    is_valid_ipv4 "$current_ip" || die "The obtained public IP is invalid: $current_ip"
    log "Current EC2 public IPv4: $current_ip"

    record_payload="$(
        DNS_NAME="$dns_name" RECORD_IP="$current_ip" RECORD_TTL="$DNS_TTL" python3 -c '
import json
import os
print(json.dumps({
    "type": "A",
    "name": os.environ["DNS_NAME"],
    "content": os.environ["RECORD_IP"],
    "ttl": int(os.environ["RECORD_TTL"]),
    "proxied": False,
}))
'
    )"

    api_base="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records"
    if ! query_response="$(cf_api GET "${api_base}?type=A&name=${encoded_dns_name}&per_page=100")"; then
        die "Unable to query the Cloudflare A record."
    fi

    if ! record_count="$(
        RESPONSE="$query_response" python3 -c '
import json
import os
records = json.loads(os.environ["RESPONSE"]).get("result")
if not isinstance(records, list):
    raise ValueError("Cloudflare response has no result list")
print(len(records))
'
    )"; then
        die "Unable to parse Cloudflare DNS query response."
    fi

    case "$record_count" in
        0)
            log "Cloudflare current IP: <A record does not exist>"
            log "Update required: yes (creating A record)"
            if [[ "$DRY_RUN" == "true" ]]; then
                log "Dry run: would create ${dns_name} -> ${current_ip} (proxied=false)."
            else
                cf_api POST "$api_base" "$record_payload" >/dev/null ||
                    die "Cloudflare A-record creation failed."
                log "Cloudflare A-record creation: success (${dns_name} -> ${current_ip}, proxied=false)"
            fi
            ;;
        1)
            record_info="$(
                RESPONSE="$query_response" python3 -c '
import json
import os
record = json.loads(os.environ["RESPONSE"])["result"][0]
print("{}\t{}\t{}".format(record["id"], record["content"], str(bool(record.get("proxied"))).lower()))
'
            )"
            IFS=$'\t' read -r record_id cf_current_ip cf_proxied <<< "$record_info"
            log "Cloudflare current IP: $cf_current_ip"

            # No API write if both the address and DNS-only setting are already correct.
            if [[ "$cf_current_ip" == "$current_ip" && "$cf_proxied" == "false" ]]; then
                log "Update required: no"
                log "Cloudflare A record is already correct; no update API call was made."
            else
                if [[ "$cf_current_ip" == "$current_ip" ]]; then
                    log "Update required: yes (IP unchanged; correcting proxied=true to proxied=false)"
                else
                    log "Update required: yes"
                fi
                if [[ "$DRY_RUN" == "true" ]]; then
                    log "Dry run: would update ${dns_name} -> ${current_ip} (proxied=false)."
                else
                    cf_api PUT "${api_base}/${record_id}" "$record_payload" >/dev/null ||
                        die "Cloudflare A-record update failed."
                    log "Cloudflare A-record update: success (${dns_name} -> ${current_ip}, proxied=false)"
                fi
            fi
            ;;
        *)
            die "Found ${record_count} A records for ${dns_name}; refusing ambiguous multi-record configuration."
            ;;
    esac

    if [[ "$DDNS_TIMER_RUN" != "true" ]]; then
        install_periodic_ddns
        if [[ "$PERIODIC_SETUP_ONLY" != "true" ]]; then
            install_flux_panel
        fi
    fi
    log "All requested startup tasks completed successfully."
}

if [[ "${DDNS_UNIT_TEST_MODE:-false}" != "true" ]]; then
    main "$@"
fi
