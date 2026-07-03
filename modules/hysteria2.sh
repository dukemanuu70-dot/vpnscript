#!/usr/bin/env bash
# =============================================================================
# modules/hysteria2.sh - Hysteria2 protocol installation and management
# =============================================================================

HY2_BIN="/usr/local/bin/hysteria"
HY2_CONFIG_DIR="/etc/hysteria"
HY2_CONFIG="${HY2_CONFIG_DIR}/config.yaml"
HY2_SYSTEMD="/etc/systemd/system/hysteria-server.service"
HY2_PORT="${HY2_PORT:-8443}"
HY2_LOG="/var/log/vpn-manager/hysteria.log"

# ---------------------------------------------------------------------------
# Install Hysteria2
# ---------------------------------------------------------------------------
module_install_hysteria2() {
    log_info "Installing Hysteria2..."

    # Hysteria2 requires UDP, check if available
    if [[ "${IS_CONTAINER:-0}" -eq 1 ]]; then
        log_warn "Container detected. Hysteria2 (QUIC/UDP) may not work in all container environments."
    fi

    mkdir -p "${HY2_CONFIG_DIR}"

    local download_url
    download_url="$(get_hysteria2_download_url)"

    if ! download_file "${download_url}" "${HY2_BIN}"; then
        log_warn "Failed to download Hysteria2. Skipping."
        return 0
    fi

    chmod 755 "${HY2_BIN}"

    # Write config after domain/SSL is set up
    _write_hysteria2_config

    _write_hysteria2_systemd

    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl start hysteria-server 2>/dev/null || log_warn "Hysteria2 will start after SSL setup"

    log_ok "Hysteria2 installed"
}

module_remove_hysteria2() {
    systemctl stop hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server 2>/dev/null || true
    rm -f "${HY2_BIN}"
    log_info "Hysteria2 stopped and removed (rollback)"
}

# ---------------------------------------------------------------------------
# Write Hysteria2 config
# ---------------------------------------------------------------------------
_write_hysteria2_config() {
    local domain
    domain="$(get_config_value "/etc/vpn-manager/vpn.conf" "DOMAIN" 2>/dev/null || echo '')"

    local obfs_password
    obfs_password="$(generate_simple_password 24)"

    cat > "${HY2_CONFIG}" <<EOF
# Hysteria2 Configuration - Managed by VPN Manager
listen: :${HY2_PORT}

tls:
  cert: /etc/letsencrypt/live/${domain:-self-signed}/fullchain.pem
  key:  /etc/letsencrypt/live/${domain:-self-signed}/privkey.pem

obfs:
  type: salamander
  salamander:
    password: ${obfs_password}

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

bandwidth:
  up: 1 gbps
  down: 1 gbps

ignoreClientBandwidth: false

logging:
  level: warn
  output: ${HY2_LOG}

auth:
  type: userpass
  userpass: {}

outbounds:
  - name: default
    type: direct
    direct:
      mode: auto
EOF
    chmod 640 "${HY2_CONFIG}"
    log_ok "Hysteria2 config written"
}

# ---------------------------------------------------------------------------
# Write systemd unit
# ---------------------------------------------------------------------------
_write_hysteria2_systemd() {
    cat > "${HY2_SYSTEMD}" <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
User=nobody
ExecStart=${HY2_BIN} server --config ${HY2_CONFIG}
Restart=always
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${HY2_SYSTEMD}"
}

# ---------------------------------------------------------------------------
# Create Hysteria2 user
# ---------------------------------------------------------------------------
hy2_create_user() {
    local username="$1"
    local days="${2:-30}"
    local password="${3:-}"

    validate_username "${username}" || return 1

    if [[ -z "${password}" ]]; then
        password="$(generate_simple_password 16)"
    fi

    local expiry
    expiry="$(days_from_now "${days}")"

    # Add to config userpass section
    python3 - <<PYEOF
import yaml, sys

try:
    with open("${HY2_CONFIG}", "r") as f:
        config = yaml.safe_load(f)
except Exception as e:
    print(f"Error reading config: {e}", file=sys.stderr)
    sys.exit(1)

if "auth" not in config:
    config["auth"] = {"type": "userpass", "userpass": {}}
if "userpass" not in config["auth"]:
    config["auth"]["userpass"] = {}

config["auth"]["userpass"]["${username}"] = "${password}"

with open("${HY2_CONFIG}", "w") as f:
    yaml.dump(config, f, default_flow_style=False)

print("OK")
PYEOF

    # Install python3-yaml if needed
    if ! python3 -c "import yaml" 2>/dev/null; then
        apt-get install -y -qq python3-yaml 2>/dev/null || true
        hy2_create_user "$@"
        return
    fi

    systemctl reload hysteria-server 2>/dev/null || systemctl restart hysteria-server 2>/dev/null || true

    # Save to users DB
    local user_conf="/etc/vpn-manager/users/${username}_hy2.conf"
    cat > "${user_conf}" <<EOF
USERNAME=${username}
TYPE=hysteria2
PASSWORD=${password}
PORT=${HY2_PORT}
EXPIRY=${expiry}
STATUS=active
EOF
    chmod 600 "${user_conf}"

    local domain
    domain="$(get_config_value "/etc/vpn-manager/vpn.conf" "DOMAIN" 2>/dev/null || echo "${SERVER_IPV4:-localhost}")"
    local sub_link="hysteria2://${username}:${password}@${domain}:${HY2_PORT}?insecure=0#${username}-HY2"

    log_activity "CREATE_HY2_USER" "${username}"
    log_ok "Hysteria2 user created: ${username}"

    echo ""
    print_key_value "  Username" "${username}"
    print_key_value "  Password" "${password}" "${CYAN}" "${YELLOW}"
    print_key_value "  Server" "${domain}:${HY2_PORT}"
    print_key_value "  Expires" "${expiry}"
    echo "  Link: ${sub_link}"
    echo ""
}

# ---------------------------------------------------------------------------
# Delete Hysteria2 user
# ---------------------------------------------------------------------------
hy2_delete_user() {
    local username="$1"

    python3 - <<PYEOF
import yaml

try:
    with open("${HY2_CONFIG}", "r") as f:
        config = yaml.safe_load(f)
    if "auth" in config and "userpass" in config["auth"]:
        config["auth"]["userpass"].pop("${username}", None)
    with open("${HY2_CONFIG}", "w") as f:
        yaml.dump(config, f, default_flow_style=False)
    print("OK")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    rm -f "/etc/vpn-manager/users/${username}_hy2.conf"
    systemctl restart hysteria-server 2>/dev/null || true
    log_activity "DELETE_HY2_USER" "${username}"
    log_ok "Hysteria2 user deleted: ${username}"
}
