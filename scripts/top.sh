#!/bin/bash
# vpn top — htop-style live VPN monitor.
#
# Background probes update cached state at per-component cadences; a single
# render thread repaints from cache @ 10 Hz with cursor-home + line-clear so
# CPU stays near zero in steady state. Probes wake early on SIGUSR1 (the `r`
# key broadcasts it to all probes for instant refresh).

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── ANSI ─────────────────────────────────────────────────────────────────
ESC=$'\033'
ALT_ON="${ESC}[?1049h"; ALT_OFF="${ESC}[?1049l"
CUR_HIDE="${ESC}[?25l"; CUR_SHOW="${ESC}[?25h"
WRAP_OFF="${ESC}[?7l"; WRAP_ON="${ESC}[?7h"
HOME="${ESC}[H"; CLR_EOL="${ESC}[K"; CLR_SCR="${ESC}[2J"
B="${ESC}[1m"; D="${ESC}[2m"; R="${ESC}[0m"
FG_RED="${ESC}[31m"; FG_GRN="${ESC}[32m"; FG_YEL="${ESC}[33m"
FG_CYA="${ESC}[36m"; FG_MAG="${ESC}[35m"; FG_BLU="${ESC}[34m"
# Manual pulse pair — alternated each second from the render loop because
# most modern terminals (kitty/alacritty/vscode/tmux) silently drop the ANSI
# blink attribute (\e[5m). High-contrast pair so the flash is unmistakable
# in any color scheme: white-on-red alarm box vs bright red on default bg.
FG_PULSE_A="${ESC}[1;97;41m"   # bold + white fg + red bg (alarm box)
FG_PULSE_B="${ESC}[1;91m"      # bold + bright red fg, default bg

# Move cursor to (row, col), 1-indexed.
move() { printf '%s[%d;%dH' "$ESC" "$1" "$2"; }

# ─── Terminal geometry ────────────────────────────────────────────────────
COLS=80; LINES=24
update_dims() {
    COLS=$(tput cols 2>/dev/null || echo 80)
    LINES=$(tput lines 2>/dev/null || echo 24)
    # Reserve a 1-col right gutter. Some terminals (varies by emulator + alt-
    # screen interactions) silently drop characters written to the rightmost
    # cell, eating the right border. Shaving 1 col makes the right edge land
    # at COLS-1 where it always renders cleanly.
    COLS=$((COLS - 1))
    NEED_REPAINT=1
}
update_dims
NEED_REPAINT=1
trap update_dims WINCH

# ─── State dir ────────────────────────────────────────────────────────────
STATE_DIR=$(mktemp -d /tmp/vpn-top.XXXXXX)
PROBE_PIDS=()
PAUSED=0
SHOW_LOG=1
SHOW_HELP=0
RENDER_FRAME=0

s_set() { printf '%s' "$2" > "$STATE_DIR/$1.tmp" && mv "$STATE_DIR/$1.tmp" "$STATE_DIR/$1"; }
s_get() { [ -f "$STATE_DIR/$1" ] && cat "$STATE_DIR/$1" || printf '%s' "${2:-}"; }
s_paused() { [ -f "$STATE_DIR/paused" ]; }

# Append a numeric sample to a circular history. Cap at 256 so the renderer
# always has enough samples to fill the sparkline column on wide terminals;
# the actual visible width is computed per-frame from the layout.
hist_push() {
    local f="$STATE_DIR/$1.hist" v="$2"
    { [ -f "$f" ] && cat "$f"; echo "$v"; } | tail -n 256 > "$f.tmp" && mv "$f.tmp" "$f"
}

# ─── Probes ───────────────────────────────────────────────────────────────
# Each probe: do work, write small files via s_set. Cheap, idempotent.

probe_clock() {
    s_set clock "$(date +%H:%M:%S)"
}

# Derive VPN uptime from the manager log's most recent connect event. The
# log format is "YYYY-MM-DD HH:MM:SS [VPN] Tailscale connected successfully!"
# so we grab the timestamp prefix and convert to epoch.
probe_vpn_since() {
    [ -f "$LOG_FILE" ] || { s_set vpn_since ""; return; }
    local line ts epoch
    line=$(grep "Tailscale connected successfully" "$LOG_FILE" 2>/dev/null | tail -1)
    [ -z "$line" ] && { s_set vpn_since ""; return; }
    ts="${line:0:19}"
    epoch=$(date -d "$ts" +%s 2>/dev/null)
    s_set vpn_since "${epoch:-}"
}

probe_route() {
    local rt; rt=$(ip route show default 2>/dev/null | grep -v tailscale | head -1)
    local gw if_; gw=$(awk '{print $3}' <<<"$rt"); if_=$(awk '{print $5}' <<<"$rt")
    s_set route "${gw:-?} via ${if_:-?}"
}

probe_manager() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        s_set mgr "running:$(cat "$PID_FILE")"
    else
        s_set mgr "stopped"
    fi
}

probe_tailscale() {
    # Use --json: the text `tailscale status` lists the peer hostname whether
    # or not it's the active exit node, so a hostname-grep falsely reports
    # "up" after a manual `tailscale set --exit-node=` from another tab.
    # ExitNodeStatus.ID is the canonical "exit node currently routing" flag.
    local json; json=$(sudo -n tailscale status --json 2>/dev/null)
    local new_state
    if [ -z "$json" ]; then
        new_state="down:unknown"
    else
        local backend exit_id
        backend=$(yq -p json -r '.BackendState // ""' <<<"$json" 2>/dev/null)
        exit_id=$(yq -p json -r '.ExitNodeStatus.ID // ""' <<<"$json" 2>/dev/null)
        case "$backend" in
            Running)
                if [ -n "$exit_id" ]; then new_state="up"
                else                       new_state="down:no-exit"
                fi ;;
            Stopped|NoState)               new_state="down:stopped" ;;
            NeedsLogin)                    new_state="down:loggedout" ;;
            NeedsMachineAuth)              new_state="down:expired" ;;
            Starting)                      new_state="down:starting" ;;
            *)                             new_state="down:unknown" ;;
        esac
    fi

    # Disconnect alarm: arm a 60-second beep window on transition out of "up".
    # Auto-clear any prior mute so a new disconnect always alerts. Also fire
    # a one-shot desktop notification via OSC 9/777 escape sequences which
    # cmux, iTerm2, kitty, and urxvt translate to native OS notifications
    # (other terminals ignore them silently — safe everywhere).
    local prev; prev=$(s_get vpn '')
    if [[ "$prev" == "up" && "$new_state" != "up" ]]; then
        local until_us=$(( ${EPOCHREALTIME/./} + 60000000 ))
        s_set alarm_until_us "$until_us"
        rm -f "$STATE_DIR/muted"
        {
            printf '\033]9;VPN disconnected — exit node dropped\a'
            printf '\033]777;notify;VPN disconnected;Exit node %s dropped\a' "$TS_EXIT_NODE"
        } > /dev/tty 2>/dev/null
    fi

    s_set vpn "$new_state"

    # Cosmetic: capture the peer line + count from text output.
    local out; out=$(sudo -n tailscale status 2>/dev/null)
    local line; line=$(grep "$TS_EXIT_NODE" <<<"$out" | head -1)
    [ -n "$line" ] && s_set exit_node_line "$line"
    local peers; peers=$(grep -cE '^[0-9]+\.' <<<"$out")
    s_set peers "${peers:-0}"
}

# Beeps the terminal bell once per probe tick while a disconnect alarm is
# armed and not muted. Bell goes to /dev/tty so SSH forwards it to the
# user's local terminal (audible bell must be enabled there).
probe_alarm() {
    local until_us; until_us=$(s_get alarm_until_us '')
    [ -z "$until_us" ] && return
    local now_us=${EPOCHREALTIME/./}
    if (( now_us < until_us )); then
        [ -f "$STATE_DIR/muted" ] || printf '\a' > /dev/tty 2>/dev/null
    else
        # Window ended — clear state so the title-bar indicator drops out
        # and the mute flag resets for the next event.
        rm -f "$STATE_DIR/alarm_until_us" "$STATE_DIR/muted"
    fi
}

probe_ts_ip() {
    local ip; ip=$(tailscale ip -4 2>/dev/null | head -1)
    s_set ts_ip "${ip:-—}"
}

# Resolve the LAN gateway: prefer the snapshot taken at LAN-protection setup
# (canonical pre-VPN value), fall back to a live read that excludes the
# tailscale-installed default route.
gateway_addr() {
    local gw=""
    [ -f "$SSH_PROTECTION_MARKER" ] && gw=$(grep -m1 '^DEFAULT_GW=' "$SSH_PROTECTION_MARKER" | cut -d= -f2)
    [ -z "$gw" ] && gw=$(ip route show default 2>/dev/null | grep -v tailscale | head -1 | awk '{print $3}')
    printf '%s' "$gw"
}

# Single coordinator: fires gateway + internal + external pings in parallel
# and only appends to history once all complete. Guarantees all .hist files
# always have identical length so the sparklines stay visually balanced even
# during the initial 64-sample fill.
probe_pings() {
    local gw_raw="$STATE_DIR/.ping_gw.raw"
    local int_raw="$STATE_DIR/.ping_int.raw"
    local ext_raw="$STATE_DIR/.ping_ext.raw"
    rm -f "$gw_raw" "$int_raw" "$ext_raw"

    local gw; gw=$(gateway_addr)
    if [ -n "$gw" ]; then
        ( ping -c 1 -W 2 "$gw" >"$gw_raw" 2>/dev/null ) &
    fi
    if [ -n "$TEST_INTERNAL_IP" ]; then
        ( ping -c 1 -W 2 "$TEST_INTERNAL_IP" >"$int_raw" 2>/dev/null ) &
    fi
    ( ping -c 1 -W 2 google.com >"$ext_raw" 2>/dev/null ) &
    wait

    local gw_ms int_ms ext_ms
    gw_ms=$(grep -oP 'time=\K[0-9.]+'  "$gw_raw"  2>/dev/null | head -1)
    int_ms=$(grep -oP 'time=\K[0-9.]+' "$int_raw" 2>/dev/null | head -1)
    ext_ms=$(grep -oP 'time=\K[0-9.]+' "$ext_raw" 2>/dev/null | head -1)
    rm -f "$gw_raw" "$int_raw" "$ext_raw"

    s_set gw_addr "$gw"
    if [ -z "$gw" ]; then
        s_set ping_gw "skip"
    elif [ -n "$gw_ms" ]; then
        s_set ping_gw "ok:$gw_ms"; hist_push ping_gw "$gw_ms"
    else
        s_set ping_gw "fail"; hist_push ping_gw 0
    fi

    if [ -z "$TEST_INTERNAL_IP" ]; then
        s_set ping_int "skip"
    elif [ -n "$int_ms" ]; then
        s_set ping_int "ok:$int_ms"; hist_push ping_int "$int_ms"
    else
        s_set ping_int "fail"; hist_push ping_int 0
    fi

    if [ -n "$ext_ms" ]; then
        s_set ping_ext "ok:$ext_ms"; hist_push ping_ext "$ext_ms"
    else
        s_set ping_ext "fail"; hist_push ping_ext 0
    fi
}

probe_lan() {
    if sudo -n ip rule list 2>/dev/null | grep -q lan_return; then
        s_set lan_rule "ok"
    else
        s_set lan_rule "missing"
    fi
    local n; n=$(sudo -n iptables -t mangle -L -n 2>/dev/null | grep -c "vpn-mgr")
    s_set lan_marks "${n:-0}"
}

probe_cron() {
    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        s_set cron "enabled"
    else
        s_set cron "disabled"
    fi
}

# Tailscale node-key expiry — when the tailnet ACL has key expiry enabled,
# Self.KeyExpiry holds the next re-auth deadline. A Go zero-date sentinel
# (year 0001) means expiry is disabled for this node.
probe_auth_expiry() {
    local raw epoch
    raw=$(sudo -n tailscale status --json 2>/dev/null \
          | yq -p json -r '.Self.KeyExpiry // ""' 2>/dev/null)
    if [ -z "$raw" ] || [ "$raw" = "null" ] || [[ "$raw" == 0001-* ]]; then
        s_set auth_expiry "none"
        return
    fi
    epoch=$(date -d "$raw" +%s 2>/dev/null)
    s_set auth_expiry "${epoch:-}"
}

probe_log() {
    [ -f "$LOG_FILE" ] || { s_set log ""; return; }
    # Buffer enough recent lines that the renderer can fill the log pane on
    # tall terminals; the renderer slices to whatever fits.
    tail -n 500 "$LOG_FILE" > "$STATE_DIR/log.tmp" && mv "$STATE_DIR/log.tmp" "$STATE_DIR/log"
}

# ─── Probe loops ──────────────────────────────────────────────────────────
# Each loop: trap SIGUSR1 to break out of `sleep` early, then re-probe.
# Pause is checked by file marker — keeps last cached value visible.

probe_loop() {
    local fn="$1" period="$2"
    trap 'true' USR1
    while true; do
        s_paused || "$fn"
        # Sleep until the next wall-clock boundary aligned to `period` so all
        # probes with the same period stay phase-locked regardless of how
        # long their work took. awk handles fractional periods (e.g. 0.5).
        local now sleep_for
        now=$(date +%s.%N)
        sleep_for=$(awk -v n="$now" -v p="$period" \
            'BEGIN{ s=(int(n/p)+1)*p - n; if (s<0.001) s+=p; printf "%.3f", s }')
        sleep "$sleep_for" &
        wait $! 2>/dev/null
    done
}

start_probes() {
    probe_loop probe_clock     1   & PROBE_PIDS+=($!)
    probe_loop probe_route     1   & PROBE_PIDS+=($!)
    probe_loop probe_manager   1   & PROBE_PIDS+=($!)
    probe_loop probe_tailscale 2   & PROBE_PIDS+=($!)
    probe_loop probe_log       1   & PROBE_PIDS+=($!)
    probe_loop probe_vpn_since 5   & PROBE_PIDS+=($!)
    probe_loop probe_pings     1   & PROBE_PIDS+=($!)
    probe_loop probe_ts_ip     5   & PROBE_PIDS+=($!)
    probe_loop probe_lan         15 & PROBE_PIDS+=($!)
    probe_loop probe_cron        60 & PROBE_PIDS+=($!)
    probe_loop probe_auth_expiry 60 & PROBE_PIDS+=($!)
    probe_loop probe_alarm        1 & PROBE_PIDS+=($!)
}

wake_probes() {
    local pid
    for pid in "${PROBE_PIDS[@]}"; do kill -USR1 "$pid" 2>/dev/null; done
}

stop_probes() {
    local pid
    for pid in "${PROBE_PIDS[@]}"; do kill "$pid" 2>/dev/null; done
    wait 2>/dev/null
    PROBE_PIDS=()
}

# ─── Render helpers ───────────────────────────────────────────────────────
# Sparkline from a history file: reads numbers, scales to ▁..█.
SPARK_CHARS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

sparkline() {
    local f="$STATE_DIR/$1.hist"
    [ -f "$f" ] || { printf ''; return; }
    local vals; mapfile -t vals < "$f"
    [ ${#vals[@]} -eq 0 ] && return
    local min max v out=""
    min=999999; max=0
    for v in "${vals[@]}"; do
        # bash arith on floats fails; truncate via printf
        local i; i=${v%.*}; i=${i:-0}
        (( i < min )) && min=$i
        (( i > max )) && max=$i
    done
    local range=$((max - min))
    if (( range == 0 )); then
        # Flat history → flat midline rather than a row of ▁ or █.
        for v in "${vals[@]}"; do out+="${SPARK_CHARS[3]}"; done
    else
        # Map min→▁ (idx 0), max→▇ (idx 6). Reserve █ as headroom so the
        # highest sample never touches the visual ceiling.
        for v in "${vals[@]}"; do
            local i; i=${v%.*}; i=${i:-0}
            local idx=$(( (i - min) * 6 / range ))
            (( idx < 0 )) && idx=0; (( idx > 6 )) && idx=6
            out+="${SPARK_CHARS[$idx]}"
        done
    fi
    printf '%s' "$out"
}

fmt_uptime() {
    local s=$1 h m
    h=$((s/3600)); m=$(((s%3600)/60)); s=$((s%60))
    if (( h > 0 )); then printf '%dh %02dm' "$h" "$m"
    elif (( m > 0 )); then printf '%dm %02ds' "$m" "$s"
    else printf '%ds' "$s"; fi
}

# Format a future epoch as "in 12d 3h" / "in 4h 22m" / "EXPIRED".
fmt_until() {
    local target=$1 now diff d h m
    now=$(date +%s); diff=$((target - now))
    if (( diff <= 0 )); then printf 'EXPIRED'; return; fi
    d=$((diff / 86400)); h=$(((diff % 86400) / 3600)); m=$(((diff % 3600) / 60))
    if   (( d > 30 )); then printf 'in %dd' "$d"
    elif (( d > 0 ));  then printf 'in %dd %dh' "$d" "$h"
    elif (( h > 0 ));  then printf 'in %dh %dm' "$h" "$m"
    else                    printf 'in %dm' "$m"
    fi
}

# Color a status word.
sw() {
    case "$1" in
        ok|up|ON|active|enabled|running|Configured|OK)  printf '%s●%s %s' "$FG_GRN" "$R" "$2" ;;
        warn|partial)                                   printf '%s●%s %s' "$FG_YEL" "$R" "$2" ;;
        *)                                              printf '%s●%s %s' "$FG_RED" "$R" "$2" ;;
    esac
}

# Visible char count: strips ANSI CSI escapes (\e[…m / \e[…H etc.) and counts
# remaining unicode chars (assumes UTF-8 locale, so box-drawing is 1 char).
shopt -s extglob
vlen() {
    local s="${1//$'\e['*([0-9;])[a-zA-Z]/}"
    printf '%d' "${#s}"
}

# Right-pad to exactly N visible chars.
pad_r() {
    local n=$1 s=$2 v
    v=$(vlen "$s")
    local p=$((n - v))
    (( p < 0 )) && { printf '%s' "$s"; return; }
    printf '%s%*s' "$s" "$p" ''
}

# Truncate to N visible chars (preserves leading ANSI; no attempt at perfect
# mid-escape preservation since we keep the source short anyway).
trunc_v() {
    local n=$1 s=$2 v
    v=$(vlen "$s")
    (( v <= n )) && { printf '%s' "$s"; return; }
    # Strip ANSI then slice. Loses color but keeps layout sane on overflow.
    local plain="${s//$'\e['*([0-9;])[a-zA-Z]/}"
    printf '%s%s' "${plain:0:$((n-1))}" '…'
}

# Repeat a single (possibly multi-byte) character N times.
hr() {
    local n=$1 c="${2:-─}" out=""
    local i; for ((i=0; i<n; i++)); do out+="$c"; done
    printf '%s' "$out"
}

# ─── Box drawing helpers ──────────────────────────────────────────────────
# All boxes use Unicode light box drawing. Width is total width including
# both vertical borders. Inner content area = width - 4 (│ + space + space + │).

# Box top with embedded title: ┌─ Title ─────────┐
box_top() {
    local title="$1" w=$2
    local right=$((w - ${#title} - 5))
    (( right < 1 )) && right=1
    printf '%s┌─ %s%s %s%s%s┐%s' \
        "$D" "$R" \
        "$B$FG_CYA$title$R" \
        "$D" "$(hr "$right")" "" "$R"
}

box_bot() {
    local w=$1
    printf '%s└%s┘%s' "$D" "$(hr $((w - 2)))" "$R"
}

# Box content row: │ <padded content> │
box_row() {
    local w=$1 content=$2
    local inner=$((w - 4))
    local v; v=$(vlen "$content")
    if (( v > inner )); then
        content=$(trunc_v "$inner" "$content")
    fi
    printf '%s│%s %s %s│%s' "$D" "$R" "$(pad_r "$inner" "$content")" "$D" "$R"
}

# Sparkline from a history file: reads numbers, scales to ▁..█.
SPARK_CHARS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

# ─── Cell builders ────────────────────────────────────────────────────────
# Each builder returns a single colored string for one row of a section.
# Layout widths are passed in from render() so cells fit their column.

cell_kv() {  # label_w, label, value
    printf '%-*s %s' "$1" "$2" "$3"
}

build_connection_rows() {
    local lw=14
    local clk vpn_state ts_ip mgr cron exit_line peers vpn_since auth_expiry
    vpn_state=$(s_get vpn 'unknown')
    ts_ip=$(s_get ts_ip '—')
    mgr=$(s_get mgr 'unknown')
    cron=$(s_get cron 'unknown')
    exit_line=$(s_get exit_node_line '')
    peers=$(s_get peers '0')
    auth_expiry=$(s_get auth_expiry '')

    CONN_ROWS=()
    case "$vpn_state" in
        up)             CONN_ROWS+=("$(cell_kv $lw 'VPN' "$(sw ok Connected)")") ;;
        down:stopped)   CONN_ROWS+=("$(cell_kv $lw 'VPN' "$(sw fail 'Tailscale stopped')")") ;;
        down:expired)   CONN_ROWS+=("$(cell_kv $lw 'VPN' "$(sw fail 'Auth expired')")") ;;
        down:loggedout) CONN_ROWS+=("$(cell_kv $lw 'VPN' "$(sw fail 'Not authenticated')")") ;;
        down:no-exit)   CONN_ROWS+=("$(cell_kv $lw 'VPN' "$(sw fail 'No exit node')")") ;;
        down:starting)  CONN_ROWS+=("$(cell_kv $lw 'VPN' "${FG_YEL}● Starting…$R")") ;;
        down:*)         CONN_ROWS+=("$(cell_kv $lw 'VPN' "$(sw fail Disconnected)")") ;;
        *)              CONN_ROWS+=("$(cell_kv $lw 'VPN' "$D— probing —$R")") ;;
    esac
    CONN_ROWS+=("$(cell_kv $lw 'Tailscale IP' "$FG_CYA$ts_ip$R")")
    CONN_ROWS+=("$(cell_kv $lw 'Exit Node' "$FG_CYA$TS_EXIT_NODE$R   ${D}peers:$R $peers")")
    case "$mgr" in
        running:*) CONN_ROWS+=("$(cell_kv $lw 'Manager' "$(sw ok Running)   ${D}PID ${mgr#running:}$R")") ;;
        stopped)   CONN_ROWS+=("$(cell_kv $lw 'Manager' "$(sw fail Stopped)")") ;;
        *)         CONN_ROWS+=("$(cell_kv $lw 'Manager' "$D—$R")") ;;
    esac
    if [ -n "$auth_expiry" ]; then
        if [ "$auth_expiry" = "none" ]; then
            CONN_ROWS+=("$(cell_kv $lw 'Auth expires' "${D}no expiry set$R")")
        else
            local _diff color
            _diff=$(($auth_expiry - $(date +%s)))
            # Tiers:
            #   < 1h   → pulse  (flashing alarm)
            #   1h-12h → FG_RED
            #   12h-24h→ FG_YEL
            #   ≥ 24h  → FG_GRN
            if   (( _diff < 3600 )); then
                # Wallclock-driven phase. 500 000 µs half-period = 1 Hz blink,
                # which renders smoothly even when full frames take 100-200 ms.
                local _us=${EPOCHREALTIME/./}
                if (( _us / 500000 % 2 == 0 )); then color="$FG_PULSE_A"
                else                                 color="$FG_PULSE_B"
                fi
            elif (( _diff < 43200 )); then color="$FG_RED"
            elif (( _diff < 86400 )); then color="$FG_YEL"
            else                          color="$FG_GRN"
            fi
            CONN_ROWS+=("$(cell_kv $lw 'Auth expires' "$color$(fmt_until "$auth_expiry")$R")")
        fi
    fi
    case "$cron" in
        enabled)  CONN_ROWS+=("$(cell_kv $lw 'Auto-startup' "$(sw ok Enabled)")") ;;
        disabled) CONN_ROWS+=("$(cell_kv $lw 'Auto-startup' "${D}Disabled$R")") ;;
        *)        CONN_ROWS+=("$(cell_kv $lw 'Auto-startup' "$D—$R")") ;;
    esac
}

build_network_rows() {
    local lw=18
    local route lan_rule lan_marks
    route=$(s_get route '—')
    lan_rule=$(s_get lan_rule 'unknown')
    lan_marks=$(s_get lan_marks '0')

    NET_ROWS=()
    NET_ROWS+=("$(cell_kv $lw 'Default route' "$D$route$R")")
    case "$lan_rule" in
        ok)      NET_ROWS+=("$(cell_kv $lw 'LAN return path' "$(sw ok Configured)")")
                 NET_ROWS+=("$(cell_kv $lw '' "${D}fwmark 0x1 → table lan_return$R")") ;;
        missing) NET_ROWS+=("$(cell_kv $lw 'LAN return path' "$(sw fail Missing)")") ;;
        *)       NET_ROWS+=("$(cell_kv $lw 'LAN return path' "$D—$R")") ;;
    esac
    if [ "$lan_marks" -gt 0 ] 2>/dev/null; then
        NET_ROWS+=("$(cell_kv $lw 'Connmark rules' "$FG_GRN$lan_marks active$R")")
    else
        NET_ROWS+=("$(cell_kv $lw 'Connmark rules' "${FG_RED}None$R")")
    fi
}

# Build a probe row that aligns with the Connection|Network boxes above:
# the left content (label/target/ms) fits in left_w, then a 4-col gap (mirrors
# the │+space×2+│ transition between the two boxes), then the sparkline fills
# spark_w. So the sparkline's left and right edges line up exactly with the
# Network box's content area above.
build_probe_row() {
    local label=$1 val=$2 hist_key=$3 target=$4 left_w=$5 spark_w=$6
    local target_w=22

    # Left half: label + target + latency.
    local left
    case "$val" in
        ok:*)
            local ms="${val#ok:}"
            left=$(printf '%-9s %s%-*s%s  %s%6s ms%s' \
                "$label" "$D" "$target_w" "$target" "$R" "$FG_GRN" "$ms" "$R") ;;
        fail)
            left=$(printf '%-9s %s%-*s%s  %sFAIL%s' \
                "$label" "$D" "$target_w" "$target" "$R" "$FG_RED" "$R") ;;
        skip)
            left=$(printf '%-9s %s(not configured)%s' "$label" "$D" "$R") ;;
        *)
            left=$(printf '%-9s %s%-*s%s  %s—%s' \
                "$label" "$D" "$target_w" "$target" "$R" "$D" "$R") ;;
    esac
    left=$(pad_r "$left_w" "$left")

    # Sparkline padded/truncated to spark_w. Right-align so the freshest
    # samples sit at the same column as the right edge of Network above.
    local spark; spark=$(sparkline "$hist_key")
    local spark_v; spark_v=$(vlen "$spark")
    if (( spark_v < spark_w )); then
        spark=$(printf '%*s%s' $((spark_w - spark_v)) '' "$spark")
    elif (( spark_v > spark_w )); then
        local plain="${spark//$'\e['*([0-9;])[a-zA-Z]/}"
        spark="${plain: -$spark_w}"
    fi

    # 4-col gap mirrors the box-edge transition between Connection and Network.
    printf '%s    %s%s%s' "$left" "$FG_CYA" "$spark" "$R"
}

# Build a single colored log line shaped to width `w`.
build_log_line() {
    local line=$1 w=$2
    if [[ "$line" == *"[VPN]"* ]]; then
        local ts="${line:0:19}" msg="${line#*\[VPN\] }"
        local lower="${msg,,}" color="$D"
        case "$lower" in
            *error*|*fail*|*expired*) color="$FG_RED" ;;
            *connected*|*success*|*authenticated*) color="$FG_GRN" ;;
            *stop*|*disconnect*) color="$FG_YEL" ;;
        esac
        printf '%s%s%s  %s%s%s' "$D" "$ts" "$R" "$color" "$msg" "$R"
    else
        # Raw tee'd output (e.g. tailscale's own "Success." lines).
        printf '                     %s%s%s' "$D" "$line" "$R"
    fi
}

# ─── Frame render ─────────────────────────────────────────────────────────
# Layout (top-down, 1-indexed rows):
#   1     header band (title, provider, clock, vpn-uptime, paused)
#   2     hr divider
#   3..N1 Connection box | Network box (two columns when COLS>=100)
#   N1+1.. Probes box (full width, 5 lines: top + 3 + bot)
#   ..    Log box (full width, fills remaining)
#   LINES keybar
#
# Repaint clears only what each row writes (line-clear), no full screen
# clears in steady state.

render() {
    ((RENDER_FRAME++))
    if (( NEED_REPAINT == 1 )); then
        printf '%s' "$CLR_SCR"
        NEED_REPAINT=0
    fi

    # Read state (small, all from cache).
    local clk vpn_state vpn_since pause_lbl up_lbl
    clk=$(s_get clock '--:--:--')
    vpn_state=$(s_get vpn 'unknown')
    vpn_since=$(s_get vpn_since '')
    (( PAUSED == 1 )) && pause_lbl="${FG_YEL}[PAUSED]${R}" || pause_lbl=""
    up_lbl=""
    if [[ "$vpn_state" == "up" ]] && [ -n "$vpn_since" ]; then
        up_lbl=$(printf '%sup:%s %s' "$D" "$R" "$(fmt_uptime $(( $(date +%s) - vpn_since )))")
    fi

    # Disconnect-alarm banner. Pulses the same way as auth-expires; shows
    # remaining seconds and a [MUTED] tag if the user pressed m.
    local alarm_lbl=""
    local alarm_end; alarm_end=$(s_get alarm_until_us '')
    if [ -n "$alarm_end" ]; then
        local _now_us=${EPOCHREALTIME/./}
        local remain_us=$((alarm_end - _now_us))
        if (( remain_us > 0 )); then
            local remain_s=$((remain_us / 1000000 + 1))
            local _color
            if (( _now_us / 500000 % 2 == 0 )); then _color="$FG_PULSE_A"
            else                                     _color="$FG_PULSE_B"
            fi
            local muted_tag=""
            [ -f "$STATE_DIR/muted" ] && muted_tag="$D [MUTED]$R"
            alarm_lbl=$(printf '%s 🚨 DISCONNECT %ss%s%s' "$_color" "$remain_s" "$R" "$muted_tag")
        fi
    fi

    build_connection_rows
    build_network_rows

    # ─── Geometry ──
    local two_col=0; (( COLS >= 100 )) && two_col=1
    local left_w right_w
    if (( two_col == 1 )); then
        left_w=$((COLS / 2))
        right_w=$((COLS - left_w))
    else
        left_w=$COLS; right_w=0
    fi

    # Number of rows in Connection/Network area.
    local conn_n=${#CONN_ROWS[@]} net_n=${#NET_ROWS[@]}
    local top_n
    if (( two_col == 1 )); then
        top_n=$(( conn_n > net_n ? conn_n : net_n ))
    else
        top_n=$(( conn_n + net_n + 1 ))  # +1 for separator title
    fi
    local top_h=$((top_n + 2))   # box top + content + box bot
    local probes_h=5             # box top + 3 probes + box bot
    local keybar_h=1
    local hdr_h=2                # title line + divider
    local log_h=$((LINES - hdr_h - top_h - probes_h - keybar_h))
    (( log_h < 3 )) && log_h=3

    # ─── 1. Header band ──
    move 1 1
    printf '%s%svpn top%s   %sprovider:%s %s   %sclock:%s %s   %s   %s%s%s' \
        "$B" "$FG_MAG" "$R" "$D" "$R" "$PROVIDER_TYPE" "$D" "$R" "$clk" \
        "$up_lbl" "$pause_lbl" "$alarm_lbl" "$CLR_EOL"
    move 2 1
    printf '%s%s%s%s' "$D" "$(hr "$COLS")" "$R" "$CLR_EOL"

    # ─── 2. Connection | Network ──
    local row_y=3
    if (( two_col == 1 )); then
        move $row_y 1; printf '%s%s%s' "$(box_top 'Connection' "$left_w")" "$(box_top 'Network' "$right_w")" "$CLR_EOL"
        ((row_y++))
        local i
        for ((i=0; i<top_n; i++)); do
            move $row_y 1
            printf '%s%s%s' \
                "$(box_row "$left_w"  "${CONN_ROWS[i]:-}")" \
                "$(box_row "$right_w" "${NET_ROWS[i]:-}")" \
                "$CLR_EOL"
            ((row_y++))
        done
        move $row_y 1; printf '%s%s%s' "$(box_bot "$left_w")" "$(box_bot "$right_w")" "$CLR_EOL"
        ((row_y++))
    else
        move $row_y 1; printf '%s%s' "$(box_top 'Connection' "$COLS")" "$CLR_EOL"; ((row_y++))
        for r in "${CONN_ROWS[@]}"; do move $row_y 1; printf '%s%s' "$(box_row "$COLS" "$r")" "$CLR_EOL"; ((row_y++)); done
        move $row_y 1; printf '%s%s%s' "$D├$(hr $((COLS - 2)))┤$R" "" "$CLR_EOL"; ((row_y++))
        for r in "${NET_ROWS[@]}"; do move $row_y 1; printf '%s%s' "$(box_row "$COLS" "$r")" "$CLR_EOL"; ((row_y++)); done
        move $row_y 1; printf '%s%s' "$(box_bot "$COLS")" "$CLR_EOL"; ((row_y++))
    fi

    # ─── 3. Probes (full width) ──
    local pg pi pe gw_addr
    pg=$(s_get ping_gw '—'); pi=$(s_get ping_int '—'); pe=$(s_get ping_ext '—')
    gw_addr=$(s_get gw_addr '—')

    # Align probe row internals with the Connection|Network split above:
    # left content fits in left_w-4 cols (matches Connection content), 4-col
    # gap mirrors the │ │ box transition, sparkline fills right_w-4 cols
    # (matches Network content). In single-column mode there is no Network
    # to mirror, so split the available width 50/50 between content and spark.
    local probe_left_w probe_spark_w
    if (( two_col == 1 )); then
        probe_left_w=$((left_w - 4))
        probe_spark_w=$((right_w - 4))
    else
        probe_left_w=$(((COLS - 4) / 2 - 2))
        probe_spark_w=$((COLS - 4 - probe_left_w - 4))
    fi
    (( probe_spark_w < 8 )) && probe_spark_w=8

    move $row_y 1; printf '%s%s' "$(box_top 'Probes' "$COLS")" "$CLR_EOL"; ((row_y++))
    move $row_y 1; printf '%s%s' "$(box_row "$COLS" "$(build_probe_row 'gateway'  "$pg" ping_gw  "$gw_addr"          "$probe_left_w" "$probe_spark_w")")" "$CLR_EOL"; ((row_y++))
    move $row_y 1; printf '%s%s' "$(box_row "$COLS" "$(build_probe_row 'internal' "$pi" ping_int "$TEST_INTERNAL_IP" "$probe_left_w" "$probe_spark_w")")" "$CLR_EOL"; ((row_y++))
    move $row_y 1; printf '%s%s' "$(box_row "$COLS" "$(build_probe_row 'external' "$pe" ping_ext 'google.com'        "$probe_left_w" "$probe_spark_w")")" "$CLR_EOL"; ((row_y++))
    move $row_y 1; printf '%s%s' "$(box_bot "$COLS")" "$CLR_EOL"; ((row_y++))

    # ─── 4. Log (bottom-anchored) ──
    if (( SHOW_LOG == 1 )); then
        move $row_y 1; printf '%s%s' "$(box_top 'Log' "$COLS")" "$CLR_EOL"; ((row_y++))
        local log; log=$(s_get log '')
        local -a lines=()
        if [ -n "$log" ]; then mapfile -t lines <<< "$log"; fi
        local visible=$((log_h - 2))
        # Show the most recent N lines.
        local start=0; (( ${#lines[@]} > visible )) && start=$(( ${#lines[@]} - visible ))
        local i
        for ((i=0; i<visible; i++)); do
            move $row_y 1
            local idx=$((start + i))
            if (( idx < ${#lines[@]} )); then
                printf '%s%s' "$(box_row "$COLS" "$(build_log_line "${lines[idx]}" "$COLS")")" "$CLR_EOL"
            else
                printf '%s%s' "$(box_row "$COLS" "")" "$CLR_EOL"
            fi
            ((row_y++))
        done
        move $row_y 1; printf '%s%s' "$(box_bot "$COLS")" "$CLR_EOL"; ((row_y++))
    fi

    # ─── 5. Keybar (last line) ──
    move $LINES 1
    local kb=""
    kb+="$B$FG_BLU q $R${D}quit$R  "
    kb+="$B$FG_BLU r $R${D}refresh$R  "
    kb+="$B$FG_BLU space $R${D}pause$R  "
    kb+="$B$FG_BLU l $R${D}log$R  "
    kb+="$B$FG_BLU c $R${D}connect$R  "
    kb+="$B$FG_BLU d $R${D}disconnect$R  "
    kb+="$B$FG_BLU m $R${D}mute$R  "
    kb+="$B$FG_BLU ? $R${D}help$R"
    printf '%s%s' "$kb" "$CLR_EOL"

    # Help overlay (centered banner — toggled with ?).
    if (( SHOW_HELP == 1 )); then
        local hy=$((LINES / 2 - 4))
        (( hy < 3 )) && hy=3
        local hx=$((COLS / 2 - 24))
        (( hx < 1 )) && hx=1
        local helps=(
            "q / Esc       quit"
            "r             refresh now (wake all probes)"
            "space         pause / resume probes"
            "l             toggle log pane"
            "c             connect VPN (with confirm)"
            "d             disconnect VPN (with confirm)"
            "m             mute disconnect alarm beep"
            "? / h         toggle this help"
        )
        move $hy $hx; printf '%s%s' "$(box_top 'Help' 50)" ''
        local i
        for ((i=0; i<${#helps[@]}; i++)); do
            move $((hy + 1 + i)) $hx
            printf '%s' "$(box_row 50 "${helps[i]}")"
        done
        move $((hy + 1 + ${#helps[@]})) $hx
        printf '%s' "$(box_bot 50)"
    fi
}

# ─── Confirm prompt (footer) ──────────────────────────────────────────────
# Returns 0 on yes, 1 on no/cancel. Reads a single key.
confirm() {
    local msg="$1" key
    printf '%s' "$HOME"
    # Move cursor to last line
    printf '%s[%d;1H' "$ESC" "$(tput lines)"
    printf '%s%s %s [y/N]%s ' "$B$FG_YEL" "$msg" "$R" "$CLR_EOL"
    IFS= read -rsn1 key
    [[ "$key" == "y" || "$key" == "Y" ]]
}

# ─── Run a manager command outside alt-screen ─────────────────────────────
# Lets the user see auth URLs, sudo prompts, etc.
run_managed() {
    printf '%s%s%s%s' "$WRAP_ON" "$CUR_SHOW" "$ALT_OFF" "$R"
    "$SCRIPT_DIR/manager.sh" "$@"
    printf '\n%spress any key to return…%s' "$D" "$R"
    IFS= read -rsn1 _
    printf '%s%s%s' "$ALT_ON" "$CUR_HIDE" "$WRAP_OFF"
    NEED_REPAINT=1
    wake_probes
}

# ─── Cleanup ──────────────────────────────────────────────────────────────
cleanup() {
    stop_probes
    rm -rf "$STATE_DIR"
    printf '%s%s%s' "$WRAP_ON" "$CUR_SHOW" "$ALT_OFF"
    stty echo 2>/dev/null
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

# ─── Main ─────────────────────────────────────────────────────────────────
main() {
    # Sanity: stdout must be a TTY for alt-screen to make sense.
    if [ ! -t 1 ]; then
        echo "vpn top requires a TTY. Use 'vpn status' for one-shot output." >&2
        exit 1
    fi

    printf '%s%s%s%s' "$ALT_ON" "$CUR_HIDE" "$WRAP_OFF" "$CLR_SCR"
    stty -echo 2>/dev/null

    start_probes
    # Prime: trigger one immediate probe of each so first frame isn't empty.
    sleep 0.05
    wake_probes

    while true; do
        render
        local key=""
        IFS= read -rsn1 -t 0.1 key
        case "$key" in
            q|Q) break ;;
            $'\e')
                local rest=""; IFS= read -rsn2 -t 0.01 rest
                [ -z "$rest" ] && break
                ;;
            r|R) wake_probes ;;
            ' ')
                if (( PAUSED == 0 )); then
                    PAUSED=1; touch "$STATE_DIR/paused"
                else
                    PAUSED=0; rm -f "$STATE_DIR/paused"; wake_probes
                fi
                ;;
            l|L) SHOW_LOG=$((1 - SHOW_LOG)); NEED_REPAINT=1 ;;
            m|M)
                # Mute the disconnect-alarm sound; visual countdown stays.
                [ -f "$STATE_DIR/alarm_until_us" ] && touch "$STATE_DIR/muted"
                ;;
            '?'|h|H) SHOW_HELP=$((1 - SHOW_HELP)); NEED_REPAINT=1 ;;
            c|C)
                if confirm "Connect VPN to $TS_EXIT_NODE?"; then
                    run_managed connect
                fi
                NEED_REPAINT=1
                ;;
            d|D)
                if confirm "Disconnect VPN?"; then
                    run_managed disconnect
                fi
                NEED_REPAINT=1
                ;;
        esac
    done
}

main "$@"
