# CLAUDE.md - VPN Manager

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

## Critical Safety Rules

> **DO NOT** connect/disconnect the VPN without SSH protection in place. If the VPN connects and breaks routing, your SSH session will be cut and you lose access to the machine. Always use the `vpn` command framework — never run `tailscale` manually.

- **Always** ensure `setup_ssh_protection()` runs before any Tailscale state changes
- **Never** run `sudo tailscale up/down/set` directly — use `vpn connect/disconnect/start/stop`
- The `--netfilter-mode=nodivert` flag is essential — prevents Tailscale from rewriting iptables
- The `--exit-node-allow-lan-access` flag preserves local network connectivity
- SSH return traffic is protected via policy-based routing (fwmark 0x1 → table `ssh_return`)

## Overview

A Tailscale VPN manager with SSH protection, auto-reconnect, and formatted status output. Designed for headless Linux machines accessed via SSH where VPN route changes could kill connectivity.

## Quick Start

```bash
# 1. Configure
cp vpn.conf.example vpn.conf
# Edit vpn.conf with your Tailscale exit node and hostname

# 2. Setup
./scripts/setup.sh

# 3. Use
vpn status          vpn up              vpn down
vpn connect         vpn disconnect      vpn restart
vpn test            vpn recent [N]      vpn logs
vpn auth-check      vpn enable          vpn disable
vpn package [ver]   # Build distributable zip (dev only)
```

## Configuration

All settings are in `vpn.conf` (gitignored). See `vpn.conf.example` for all options.

**Required:**
- `TS_EXIT_NODE` — Tailscale exit node hostname
- `TS_HOSTNAME` — This machine's Tailscale hostname

**Optional:**
- `TS_HEALTH_CHECK_INTERVAL` — Health check seconds (default: 300)
- `TEST_INTERNAL_IP` — IP for internal connectivity test
- `DEFAULT_GATEWAY` / `DEFAULT_INTERFACE` — Override auto-detected network defaults
- `INSTALL_DIR` / `LOG_FILE` — Custom paths

## Architecture

```
├── vpn.conf.example    # Config template (committed)
├── vpn.conf            # Local config (gitignored)
├── scripts/
│   ├── cli.sh          # Global CLI wrapper
│   ├── manager.sh      # Core manager (connect, monitor, SSH protection, display)
│   ├── setup.sh        # First-time setup (symlink, start)
│   └── package.sh      # Package builder (dev only, excluded from packages)
└── logs/
    └── manager.log     # Activity log (gitignored)
```

All paths are resolved relative to the script location — no hardcoded install paths.

## LAN Protection

When Tailscale sets an exit node, it rewrites the default route. Without protection, return traffic for connections arriving from the local network (SSH, HTTP proxy, ping, etc.) gets routed through the VPN tunnel instead of back through the LAN interface.

Protection works by:
1. iptables mangle PREROUTING: tag all connections arriving on the LAN interface with connmark 0x1
2. iptables mangle OUTPUT: restore connmark on return packets
3. Policy routing: marked packets use table `lan_return` → original gateway
4. State tracked via `/tmp/vpn-manager-ssh-protected` (cleared on reboot, re-created on connect)

## Authentication

- Tailscale OAuth may expire periodically (depends on your Tailscale ACL policy)
- The manager detects "Machine key expired" and backs off rather than looping reconnects
- Run `vpn connect` and visit the auth URL to re-authenticate

## Versioning & Packaging

Git tags with `vX.Y.Z` convention. The `vpn package` command (dev only):
```bash
vpn package patch       # Bump patch
vpn package minor       # Bump minor
vpn package v1.0.0      # Explicit version
```

Produces `dist/vpn-manager-X.Y.Z.zip` with `install.sh` that self-deletes after setup.
The `package`/`build` commands are stripped from packaged builds.
