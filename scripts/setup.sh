#!/bin/bash

# VPN Manager Setup Script

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
VPN_DIR="$(dirname "$SCRIPT_DIR")"

echo "========================================"
echo "VPN Manager Setup"
echo "========================================"
echo ""

# --- Dependency check ---

_ok=0
_warn=0

check_dep() {
    local cmd="$1" name="$2" url="$3" required="${4:-true}"
    printf "  %-20s" "$name"
    if command -v "$cmd" &>/dev/null || sudo which "$cmd" &>/dev/null; then
        local ver
        ver=$("$cmd" --version 2>/dev/null | head -1) || ver="installed"
        echo "OK  ($ver)"
    elif [ "$required" = "true" ]; then
        echo "MISSING (required)"
        echo "    Install: $url"
        _ok=1
    else
        echo "MISSING (optional)"
        echo "    Install: $url"
        _warn=$((_warn + 1))
    fi
}

check_yq() {
    printf "  %-20s" "yq (mikefarah)"
    if command -v yq &>/dev/null; then
        local ver=$(yq --version 2>&1 | head -1)
        if echo "$ver" | grep -q "github.com/mikefarah/yq"; then
            echo "OK  ($ver)"
        else
            echo "WRONG VERSION"
            echo "    Found: $ver"
            echo "    The apt 'yq' package is a jq wrapper and won't work."
            echo "    Install mikefarah/yq: https://github.com/mikefarah/yq#install"
            _ok=1
        fi
    else
        echo "MISSING (required)"
        echo "    Install: https://github.com/mikefarah/yq#install"
        _ok=1
    fi
}

echo "Checking dependencies..."
echo ""
check_dep tailscale   "Tailscale"    "https://tailscale.com/download/linux"
check_yq
check_dep envsubst    "envsubst"     "Part of gettext — install gettext or gettext-base"
check_dep nc          "netcat"       "Install netcat or ncat via your package manager"  false
check_dep ping        "ping"         "Install iputils-ping or inetutils-ping"           false
check_dep sudo        "sudo"         "Install sudo and configure your user"
check_dep iptables    "iptables"     "Install iptables via your package manager"

echo ""

if [ "$_ok" -gt 0 ]; then
    echo "ERROR: Required dependencies missing. Install them and re-run setup."
    exit 1
fi

if [ "$_warn" -gt 0 ]; then
    echo "WARNING: Optional dependencies missing. Some features may not work."
    echo ""
fi

# --- Config check ---

if [ ! -f "$VPN_DIR/vpn.conf.yaml" ]; then
    echo "ERROR: vpn.conf.yaml not found."
    echo "  cp $VPN_DIR/vpn.conf.example.yaml $VPN_DIR/vpn.conf.yaml"
    echo "  Then edit vpn.conf.yaml with your values."
    exit 1
fi

# Load config (validates required settings)
source "$SCRIPT_DIR/config.sh"

# --- Install global CLI ---

echo "Installing global 'vpn' command..."
if [ ! -L /usr/local/bin/vpn ]; then
    sudo ln -sf "$VPN_DIR/scripts/cli.sh" /usr/local/bin/vpn
    echo "  Symlinked to /usr/local/bin/vpn"
else
    echo "  Already installed"
fi

# --- Start VPN ---

echo ""
echo "Starting VPN manager..."
"$VPN_DIR/scripts/manager.sh" down 2>/dev/null
sleep 2
"$VPN_DIR/scripts/manager.sh" up

echo ""
echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo ""
echo "Use 'vpn' command to manage:"
echo "  vpn status    - Check connection"
echo "  vpn enable    - Enable auto-startup"
echo "  vpn logs      - View live logs"
