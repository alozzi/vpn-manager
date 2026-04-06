#!/bin/bash

_VPN_SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
_VPN_INSTALL_DIR="$(dirname "$_VPN_SCRIPT_DIR")"
_VPN_CONF="$_VPN_INSTALL_DIR/vpn.conf.yaml"

if [ ! -f "$_VPN_CONF" ]; then
    echo "ERROR: Config not found: $_VPN_CONF"
    echo "  cp vpn.conf.example.yaml vpn.conf.yaml"
    exit 1
fi

if ! command -v yq &>/dev/null; then
    echo "ERROR: yq is required but not installed."
    echo "  See https://github.com/mikefarah/yq#install"
    exit 1
fi

_yaml() {
    local raw
    raw=$(yq -r "$1 // \"\"" "$_VPN_CONF")
    [ "$raw" = "null" ] && raw=""
    echo "$raw" | envsubst
}

# Runtime state (.state file, managed by vpn commands)
_STATE_FILE="$_VPN_INSTALL_DIR/.state"

_state() {
    [ -f "$_STATE_FILE" ] && grep -m1 "^$1=" "$_STATE_FILE" 2>/dev/null | cut -d= -f2-
}

_state_set() {
    if [ -f "$_STATE_FILE" ] && grep -q "^$1=" "$_STATE_FILE" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" "$_STATE_FILE"
    else
        echo "$1=$2" >> "$_STATE_FILE"
    fi
}

PROVIDER_TYPE=$(_state provider)
if [ -z "$PROVIDER_TYPE" ]; then
    PROVIDER_TYPE=$(_yaml '.providers[0].name')
fi
PROVIDER_TYPE="${PROVIDER_TYPE:-tailscale}"
_P=".providers[] | select(.name == \"$PROVIDER_TYPE\")"

TS_EXIT_NODE=$(_yaml "${_P}.exit-node")
TS_HOSTNAME=$(_yaml "${_P}.hostname")
TS_HEALTH_CHECK_INTERVAL=$(_yaml "${_P}.health-check-interval")
TS_HEALTH_CHECK_INTERVAL="${TS_HEALTH_CHECK_INTERVAL:-300}"

DEFAULT_GATEWAY=$(_yaml '.network.gateway')
DEFAULT_INTERFACE=$(_yaml '.network.interface')
TEST_INTERNAL_IP=$(_yaml '.network.test-ip')

INSTALL_DIR=$(_yaml '.paths.install-dir')
INSTALL_DIR="${INSTALL_DIR:-$_VPN_INSTALL_DIR}"
LOG_FILE=$(_yaml '.paths.log-file')
LOG_FILE="${LOG_FILE:-$INSTALL_DIR/logs/manager.log}"

PID_FILE="/var/run/vpn-manager.pid"
STOPPED_FILE="/tmp/vpn-manager.stopped"
SSH_PROTECTION_MARKER="/tmp/vpn-manager-ssh-protected"
CRON_TAG="vpn-manager"

mkdir -p "$(dirname "$LOG_FILE")"

_config_errors=0

_require() {
    local var="$1" label="$2"
    local val="${!var}"
    if [ -z "$val" ] || [[ "$val" == your-* ]]; then
        echo "ERROR: $label ($var) not configured in vpn.conf.yaml"
        _config_errors=$((_config_errors + 1))
    fi
}

_require TS_EXIT_NODE "Provider exit node"
_require TS_HOSTNAME  "Provider hostname"

if [ "$_config_errors" -gt 0 ]; then
    exit 1
fi

export _STATE_FILE PROVIDER_TYPE TS_EXIT_NODE TS_HOSTNAME TS_HEALTH_CHECK_INTERVAL
export DEFAULT_GATEWAY DEFAULT_INTERFACE TEST_INTERNAL_IP
export INSTALL_DIR LOG_FILE
export PID_FILE STOPPED_FILE SSH_PROTECTION_MARKER CRON_TAG
