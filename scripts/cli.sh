#!/bin/bash

# VPN CLI - Global command interface

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
VPN_DIR="$(dirname "$SCRIPT_DIR")"
MANAGER_SCRIPT="$VPN_DIR/scripts/manager.sh"
SETUP_SCRIPT="$VPN_DIR/scripts/setup.sh"
TOP_SCRIPT="$VPN_DIR/scripts/top.sh"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

show_help() {
    echo "VPN Manager CLI"
    echo "==============="
    echo ""
    echo "Usage: vpn [command] [options]"
    echo ""
    echo "Commands:"
    echo "  up                  Start VPN and manager"
    echo "  down                Stop VPN and manager"
    echo "  restart             Restart VPN"
    echo "  connect             One-time connect (no background manager)"
    echo "  disconnect          Disconnect exit node"
    echo "  status              Show connection status"
    echo "  top                 Live monitor (htop-style, q to quit)"
    echo "  test                Test connectivity"
    echo "  recent [N]          Show last N log entries (default: 10)"
    echo "  logs                Follow live logs"
    echo "  auth-check          Check authentication status"
    echo "  provider [name]     Show or switch active provider"
    echo "  enable              Enable auto-startup (cron)"
    echo "  disable             Disable auto-startup"
    echo "  setup               Run initial setup"
}

# Check if scripts exist
if [ ! -f "$MANAGER_SCRIPT" ]; then
    echo -e "${RED}Error: VPN scripts not found at $VPN_DIR${NC}"
    echo "Please ensure the VPN service is properly installed."
    exit 1
fi

# Main command routing
case "${1:-help}" in
    # Service management commands
    status)
        "$MANAGER_SCRIPT" status
        ;;
    top|monitor)
        exec "$TOP_SCRIPT"
        ;;
    up|start)
        "$MANAGER_SCRIPT" up
        ;;
    down|stop)
        "$MANAGER_SCRIPT" down
        ;;
    restart)
        "$MANAGER_SCRIPT" restart
        ;;
    connect)
        "$MANAGER_SCRIPT" connect
        ;;
    disconnect)
        "$MANAGER_SCRIPT" disconnect
        ;;
    enable)
        "$MANAGER_SCRIPT" enable
        ;;
    disable)
        "$MANAGER_SCRIPT" disable
        ;;
    logs)
        "$MANAGER_SCRIPT" logs
        ;;
    recent)
        shift
        "$MANAGER_SCRIPT" recent "$@"
        ;;
    test)
        "$MANAGER_SCRIPT" test
        ;;
    auth-check|auth)
        "$MANAGER_SCRIPT" auth-check
        ;;
    provider)
        shift
        "$MANAGER_SCRIPT" provider "$@"
        ;;
    setup)
        "$SETUP_SCRIPT"
        ;;

    # Help
    help|-h|--help)
        show_help
        ;;

# --- PACKAGE-ONLY-START ---
    package|build)
        shift
        "$VPN_DIR/scripts/package.sh" "$@"
        ;;
# --- PACKAGE-ONLY-END ---

    *)
        echo -e "${RED}Unknown command: $1${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac