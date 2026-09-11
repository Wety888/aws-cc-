#!/usr/bin/env bash
# Paste this entire file into EC2 User Data, or run it as root on the EC2 host.
# Replace only the four placeholder values below. Do NOT commit a populated copy.

set -euo pipefail

CF_API_TOKEN="REPLACE_WITH_A_NEW_CLOUDFLARE_API_TOKEN"
CF_ZONE_ID="REPLACE_WITH_YOUR_32_CHARACTER_CLOUDFLARE_ZONE_ID"
FLUX_ADDRESS="REPLACE_WITH_HOST_OR_IP_AND_PORT"
FLUX_SECRET="REPLACE_WITH_A_NEW_FLUX_SECRET"

# 2024.luneza.cc is preconfigured. Set true for a read-only validation.
DOMAIN="2024.luneza.cc"
DRY_RUN=false

SCRIPT_URL="https://raw.githubusercontent.com/Wety888/aws-cc-/main/outputs/cloudflare-ddns-and-flux-user-data.sh"
SCRIPT_FILE="$(mktemp /tmp/ec2-ddns-bootstrap.XXXXXX)"
trap 'rm -f "$SCRIPT_FILE"' EXIT

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
bash "$SCRIPT_FILE"
