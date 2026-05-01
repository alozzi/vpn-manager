#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/config.sh"

log_message() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [VPN] $1" >> "$LOG_FILE"
    echo "[VPN] $1"
}

setup_ssh_protection() {
    if [ -f "$SSH_PROTECTION_MARKER" ]; then
        log_message "LAN protection already configured"
        return 0
    fi

    log_message "Setting up LAN return-path protection..."

    local default_route=$(ip route show default | grep -v tailscale | head -1)
    local default_gw=$(echo "$default_route" | awk '{print $3}')
    local default_if=$(echo "$default_route" | awk '{print $5}')
    local local_ip=$(ip -4 addr show "$default_if" | grep inet | awk '{print $2}' | cut -d/ -f1)

    default_gw="${DEFAULT_GATEWAY:-$default_gw}"
    default_if="${DEFAULT_INTERFACE:-$default_if}"

    if [ -z "$default_gw" ] || [ -z "$default_if" ]; then
        log_message "ERROR: Cannot detect network gateway. Set DEFAULT_GATEWAY and DEFAULT_INTERFACE in vpn.conf.yaml"
        return 1
    fi

    echo "DEFAULT_GW=$default_gw" > "$SSH_PROTECTION_MARKER"
    echo "DEFAULT_IF=$default_if" >> "$SSH_PROTECTION_MARKER"
    echo "LOCAL_IP=$local_ip" >> "$SSH_PROTECTION_MARKER"

    log_message "Network state saved: gw=$default_gw if=$default_if ip=$local_ip"

    # Remove only our rules (tagged with "vpn-mgr"), not the entire chain
    local rule_nums
    rule_nums=$(sudo iptables -t mangle -L PREROUTING --line-numbers -n 2>/dev/null | grep "vpn-mgr" | awk '{print $1}' | sort -rn)
    for n in $rule_nums; do sudo iptables -t mangle -D PREROUTING "$n" 2>/dev/null; done
    rule_nums=$(sudo iptables -t mangle -L OUTPUT --line-numbers -n 2>/dev/null | grep "vpn-mgr" | awk '{print $1}' | sort -rn)
    for n in $rule_nums; do sudo iptables -t mangle -D OUTPUT "$n" 2>/dev/null; done
    sudo ip rule del fwmark 0x1 table lan_return 2>/dev/null

    # Ensure routing table exists
    sudo mkdir -p /etc/iproute2
    grep -q "100 lan_return" /etc/iproute2/rt_tables 2>/dev/null || echo "100 lan_return" | sudo tee -a /etc/iproute2/rt_tables >/dev/null

    # Route table: return traffic via original gateway
    sudo ip route flush table lan_return 2>/dev/null
    sudo ip route add default via $default_gw dev $default_if table lan_return
    sudo ip route add $local_ip dev $default_if table lan_return

    sudo iptables -t mangle -A PREROUTING -i $default_if -m comment --comment "vpn-mgr" -j CONNMARK --set-mark 0x1
    sudo iptables -t mangle -A OUTPUT -m connmark --mark 0x1 -m comment --comment "vpn-mgr" -j CONNMARK --restore-mark

    # Docker: return traffic from containers goes through FORWARD, but routing
    # happens before mangle FORWARD. Mark in PREROUTING so lan_return applies.
    for bridge in $(ip -o link show type bridge 2>/dev/null | grep -oP '(docker0|br-[a-f0-9]+)'); do
        sudo iptables -t mangle -I PREROUTING -i "$bridge" -m connmark --mark 0x1 -m comment --comment "vpn-mgr" -j MARK --set-mark 0x1
        log_message "Docker bridge $bridge added to LAN protection"
    done

    # Policy: marked packets use lan_return table
    sudo ip rule add fwmark 0x1 table lan_return prio 100

    log_message "LAN return-path protection configured (interface=$default_if, gw=$default_gw)"
    return 0
}

is_vpn_connected() {  # accepts optional pre-fetched status text as $1
    local ts_status="${1:-$(sudo tailscale status 2>&1)}"

    # Fast text-based bailouts.
    if echo "$ts_status" | grep -q "Tailscale is stopped"; then
        return 1
    fi
    if echo "$ts_status" | grep -q "Logged out"; then
        return 1
    fi

    # Authoritative check: ExitNodeStatus.ID from --json. The text status
    # always lists the peer hostname whether or not it's the active exit
    # node, so a hostname grep is a false positive after a manual
    # `tailscale set --exit-node=`. Without this, the daemon's monitoring
    # loop thinks "still connected" and skips reconnects indefinitely.
    local exit_id
    exit_id=$(sudo tailscale status --json 2>/dev/null \
              | yq -p json -r '.ExitNodeStatus.ID // ""' 2>/dev/null)
    [ -n "$exit_id" ]
}

kill_vpn() {
    log_message "Stopping VPN connections safely..."
    sudo tailscale set --exit-node= 2>/dev/null
    log_message "Tailscale exit node disconnected"
    return 0
}

connect_vpn() {
    log_message "Connecting Tailscale VPN..."
    setup_ssh_protection

    echo ""
    echo "=========================================="
    echo "TAILSCALE SAFE CONNECTION"
    echo "=========================================="
    echo "Exit Node: $TS_EXIT_NODE"
    echo "LAN Protection: ACTIVE"
    echo ""

    local ts_status=$(sudo tailscale status 2>&1)

    if echo "$ts_status" | grep -q "Tailscale is stopped"; then
        log_message "Tailscale is stopped, starting..."
        sudo tailscale up \
            --hostname="$TS_HOSTNAME" \
            --accept-routes \
            --netfilter-mode=nodivert \
            --reset 2>&1 | tee -a "$LOG_FILE"
        sleep 2
        ts_status=$(sudo tailscale status 2>&1)
    fi

    if echo "$ts_status" | grep -q "Machine key expired"; then
        log_message "ERROR: Tailscale authentication expired"
        echo ">>> AUTHENTICATION EXPIRED <<<"
        echo "Starting re-authentication process..."
        ts_status="Logged out"
    fi

    if echo "$ts_status" | grep -q "Logged out"; then
        log_message "Need authentication first..."
        sudo tailscale up \
            --hostname="$TS_HOSTNAME" \
            --accept-routes \
            --netfilter-mode=nodivert \
            --reset 2>&1 | tee -a "$LOG_FILE" | \
        while IFS= read -r line; do
            if echo "$line" | grep -q "https://login.tailscale.com"; then
                echo ""
                echo ">>> AUTHENTICATION REQUIRED <<<"
                echo "Visit: $(echo "$line" | grep -o "https://[^ ]*")"
                echo ""
            fi
        done

        echo "Waiting for authentication..."
        local waited=0
        while [ $waited -lt 60 ]; do
            ts_status=$(sudo tailscale status 2>&1)
            if ! echo "$ts_status" | grep -q "Logged out"; then
                log_message "Authenticated successfully"
                break
            fi
            sleep 1
            waited=$((waited + 1))
            echo -n "."
        done
        echo ""
    fi

    log_message "Setting exit node: $TS_EXIT_NODE"
    sudo tailscale set \
        --exit-node="$TS_EXIT_NODE" \
        --exit-node-allow-lan-access=true 2>&1 | tee -a "$LOG_FILE"

    sleep 3

    if is_vpn_connected; then
        log_message "Tailscale connected successfully!"
        echo "VPN Connected"
        echo "  Tailscale IP: $(tailscale ip -4 2>/dev/null)"
        echo "  Exit Node: $TS_EXIT_NODE"

        if nc -zv 127.0.0.1 22 2>&1 | grep -q open; then
            echo "  SSH: Protected"
        else
            echo "  SSH: WARNING - May need manual fix"
        fi
        return 0
    else
        log_message "ERROR: Connection failed"
        echo "ERROR: Failed to connect properly"
        return 1
    fi
}

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_GREEN='\033[32m'
C_RED='\033[31m'
C_YELLOW='\033[33m'
C_CYAN='\033[36m'

BOX_W=60
printf -v HR_LINE '%*s' $BOX_W ''
HR_LINE=${HR_LINE// /─}
printf -v DOT_LINE '%*s' 57 ''
DOT_LINE=${DOT_LINE// /┈}

print_header() {
    local title="$1"
    local inner=$((BOX_W - 2))
    local pad=$(( (inner - ${#title}) / 2 ))
    printf "${C_BOLD}"
    printf '┌%s┐\n' "$HR_LINE"
    printf '│%*s%s%*s  │\n' $pad '' "$title" $(( inner - pad - ${#title} )) ''
    printf '├%s┤\n' "$HR_LINE"
    printf "${C_RESET}"
}

print_row() {
    local label="$1"
    local value="$2"
    local color="${3:-$C_RESET}"
    printf "│  %-24s ${color}%-32s${C_RESET} │\n" "$label" "$value"
}

print_section() {
    local title="$1"
    printf "│  ${C_BOLD}${C_CYAN}%-57s${C_RESET} │\n" "$title"
    printf '│  %s │\n' "$DOT_LINE"
}

print_footer() {
    printf '└%s┘\n' "$HR_LINE"
}

run_test() {
    local label="$1"
    local host="$2"
    local result
    result=$(ping -c 1 -W 2 "$host" 2>/dev/null)
    if [ $? -eq 0 ]; then
        local ms=$(echo "$result" | grep -oP 'time=\K[0-9.]+')
        print_row "$label" "OK  (${ms}ms)" "$C_GREEN"
    else
        print_row "$label" "FAILED" "$C_RED"
    fi
}

test_connectivity() {
    print_section "Connectivity"
    if [ -n "$TEST_INTERNAL_IP" ]; then
        run_test "Internal ($TEST_INTERNAL_IP)" "$TEST_INTERNAL_IP"
    fi
    run_test "External (google.com)" "google.com"

    if nc -zv 127.0.0.1 22 2>&1 | grep -q open; then
        print_row "Local SSH" "OK" "$C_GREEN"
    else
        print_row "Local SSH" "FAILED" "$C_RED"
    fi

    printf '│  %-57s │\n' ""
    print_section "Routing"

    local default_rt=$(ip route | grep default | head -1)
    print_row "Default route" "$(echo "$default_rt" | awk '{print $3, "via", $5}')" "$C_DIM"

    if sudo ip rule list 2>/dev/null | grep -q lan_return; then
        print_row "LAN return path" "Configured" "$C_GREEN"
    else
        print_row "LAN return path" "Missing" "$C_RED"
    fi

    local mangle_rules=$(sudo iptables -t mangle -L -n 2>/dev/null | grep -c "vpn-mgr")
    if [ "$mangle_rules" -gt 0 ]; then
        print_row "LAN connmark rules" "${mangle_rules} active" "$C_GREEN"
    else
        print_row "LAN connmark rules" "None" "$C_RED"
    fi
}

run_continuous() {
    log_message "Starting VPN manager..."
    setup_ssh_protection

    while [ ! -f "$STOPPED_FILE" ]; do
        local ts_status=$(sudo tailscale status 2>&1)

        if echo "$ts_status" | grep -q "Machine key expired"; then
            log_message "ERROR: Tailscale authentication expired - needs manual reauth"
            sleep 300
            continue
        fi

        if ! is_vpn_connected "$ts_status"; then
            log_message "VPN disconnected, reconnecting..."
            connect_vpn
        fi

        sleep ${TS_HEALTH_CHECK_INTERVAL:-300}
    done

    log_message "Manager stopped by user"
}

case "$1" in
    up|start)
        rm -f "$STOPPED_FILE"
        log_message "Starting VPN manager service..."

        nohup bash -c "$(readlink -f "$0") continuous" > /dev/null 2>&1 &
        echo $! > "$PID_FILE"

        echo "VPN manager started (PID: $(cat $PID_FILE))"
        sleep 2
        "$0" status
        ;;

    down|stop)
        touch "$STOPPED_FILE"
        log_message "Stopping VPN manager..."
        if [ -f "$PID_FILE" ]; then
            kill $(cat $PID_FILE) 2>/dev/null
            rm -f "$PID_FILE"
        fi
        kill_vpn
        echo "VPN manager stopped"
        ;;

    restart)
        "$0" down
        sleep 2
        "$0" up
        ;;

    connect)
        connect_vpn
        ;;

    disconnect)
        kill_vpn
        ;;

    status)
        ts_status=$(sudo tailscale status 2>&1)

        print_header "VPN STATUS"

        print_section "Service"
        if is_vpn_connected "$ts_status"; then
            print_row "VPN" "Connected" "$C_GREEN"
            print_row "Tailscale IP" "$(tailscale ip -4 2>/dev/null)" "$C_CYAN"
            print_row "Exit Node" "$TS_EXIT_NODE" "$C_CYAN"
        else
            print_row "VPN" "Disconnected" "$C_RED"
            if echo "$ts_status" | grep -q "Tailscale is stopped"; then
                print_row "Reason" "Tailscale stopped" "$C_YELLOW"
            elif echo "$ts_status" | grep -q "Machine key expired"; then
                print_row "Reason" "Auth expired" "$C_YELLOW"
            elif echo "$ts_status" | grep -q "Logged out"; then
                print_row "Reason" "Not authenticated" "$C_YELLOW"
            fi
        fi

        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
            print_row "Manager" "Running (PID $(cat "$PID_FILE"))" "$C_GREEN"
        else
            print_row "Manager" "Stopped" "$C_DIM"
        fi

        if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
            print_row "Auto-startup" "Enabled" "$C_GREEN"
        else
            print_row "Auto-startup" "Disabled" "$C_DIM"
        fi

        if [ -f "$SSH_PROTECTION_MARKER" ]; then
            print_row "LAN Protection" "Active" "$C_GREEN"
        else
            print_row "LAN Protection" "Not configured" "$C_YELLOW"
        fi

        printf '│  %-57s │\n' ""
        test_connectivity
        print_footer
        ;;

    test)
        print_header "VPN TEST"
        test_connectivity
        print_footer
        ;;

    continuous)
        run_continuous
        ;;

    protect-ssh)
        setup_ssh_protection
        echo "LAN protection configured"
        ;;

    logs)
        tail -f "$LOG_FILE"
        ;;

    recent)
        count=${2:-10}
        print_header "RECENT ACTIVITY"
        tail -n "$count" "$LOG_FILE" | while IFS= read -r line; do
            ts="${line:0:19}"
            msg="${line#*\[VPN\] }"
            msg="${msg:0:32}"
            lower="${msg,,}"
            case "$lower" in
                *error*|*fail*|*expired*)  print_row "$ts" "$msg" "$C_RED" ;;
                *connected*|*success*|*authenticated*) print_row "$ts" "$msg" "$C_GREEN" ;;
                *stop*|*disconnect*)       print_row "$ts" "$msg" "$C_YELLOW" ;;
                *)                         print_row "$ts" "$msg" "$C_DIM" ;;
            esac
        done
        print_footer
        ;;

    enable)
        log_message "Enabling auto-startup cron jobs..."
        SCRIPT_PATH=$(readlink -f "$0")
        (crontab -l 2>/dev/null | grep -v "$CRON_TAG"; \
         echo "*/5 * * * * $SCRIPT_PATH start >/dev/null 2>&1 # $CRON_TAG"; \
         echo "@reboot sleep 30 && $SCRIPT_PATH start >/dev/null 2>&1 # $CRON_TAG") | crontab -
        echo "Auto-startup enabled (cron every 5 min + reboot)"
        ;;

    disable)
        log_message "Disabling auto-startup cron jobs..."
        crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
        echo "Auto-startup disabled"
        ;;

    auth-check)
        ts_status=$(sudo tailscale status 2>&1)
        if echo "$ts_status" | grep -q "Machine key expired"; then
            echo "Auth: EXPIRED - run 'vpn connect' to re-authenticate"
        elif echo "$ts_status" | grep -q "Logged out"; then
            echo "Auth: NOT AUTHENTICATED"
        elif echo "$ts_status" | grep -q "Tailscale is stopped"; then
            echo "Auth: Tailscale stopped"
        else
            echo "Auth: Valid"
        fi
        ;;

    provider)
        if [ -z "$2" ]; then
            echo "Active: $PROVIDER_TYPE"
            echo ""
            echo "Available:"
            yq -r '.providers[].name' "$INSTALL_DIR/vpn.conf.yaml" | while read -r p; do
                if [ "$p" = "$PROVIDER_TYPE" ]; then
                    echo "  * $p"
                else
                    echo "    $p"
                fi
            done
        else
            if yq -e ".providers[] | select(.name == \"$2\")" "$INSTALL_DIR/vpn.conf.yaml" &>/dev/null; then
                _state_set provider "$2"
                echo "Switched to: $2"
                echo "Run 'vpn restart' to apply"
            else
                echo "ERROR: Provider '$2' not found in vpn.conf.yaml"
                exit 1
            fi
        fi
        ;;

    update|reconnect)
        "$0" restart
        ;;

    *)
        echo "Usage: $0 {up|down|restart|connect|disconnect|status|test|recent|logs|enable|disable|auth-check|provider|protect-ssh}"
        exit 1
        ;;
esac

exit 0
