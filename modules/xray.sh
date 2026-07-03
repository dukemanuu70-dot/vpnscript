#!/usr/bin/env bash
# =============================================================================
# modules/xray.sh - Xray-core installation and protocol management
# =============================================================================

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_USERS_DB="/etc/vpn-manager/users"
XRAY_LOG_DIR="/var/log/xray"
XRAY_SYSTEMD="/etc/systemd/system/xray.service"

# Default ports (auto-selected if in use)
XRAY_VLESS_PORT=443
XRAY_VMESS_WS_PORT=10000
XRAY_TROJAN_PORT=10001
XRAY_SS_PORT=10002
XRAY_GRPC_PORT=10003

# ---------------------------------------------------------------------------
# Install Xray-core
# ---------------------------------------------------------------------------
module_install_xray() {
    log_info "Installing Xray-core..."

    mkdir -p "${XRAY_CONFIG_DIR}" "${XRAY_LOG_DIR}"
    chmod 750 "${XRAY_LOG_DIR}"

    local download_url
    download_url="$(get_xray_download_url latest)"
    local xray_version
    xray_version="$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | jq -r '.tag_name' 2>/dev/null || echo 'v1.8.4')"

    log_info "Downloading Xray ${xray_version}..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local zip_file="${tmp_dir}/xray.zip"

    if ! download_file "${download_url}" "${zip_file}"; then
        log_error "Failed to download Xray"
        rm -rf "${tmp_dir}"
        return 1
    fi

    unzip -q "${zip_file}" -d "${tmp_dir}"
    install -m 755 "${tmp_dir}/xray" "${XRAY_BIN}"
    rm -rf "${tmp_dir}"

    # Install geoip and geosite data
    _install_xray_geodata "${xray_version}"

    # Write initial config
    _write_xray_initial_config

    # Write systemd unit
    _write_xray_systemd

    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray

    if systemctl is-active --quiet xray; then
        log_ok "Xray-core ${xray_version} installed and running"
    else
        log_warn "Xray may not have started. Check: journalctl -u xray"
        return 1
    fi
}

module_remove_xray() {
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    rm -f "${XRAY_BIN}"
    log_info "Xray stopped and removed (rollback)"
}

# ---------------------------------------------------------------------------
# Install geodata
# ---------------------------------------------------------------------------
_install_xray_geodata() {
    local version="${1:-}"
    local base="https://github.com/XTLS/Xray-core/releases"
    local tag="${version:-latest}"
    if [[ "${tag}" != "latest" ]]; then
        base="${base}/download/${tag}"
    else
        base="${base}/latest/download"
    fi

    download_file "${base}/geoip.dat" "${XRAY_CONFIG_DIR}/geoip.dat" || true
    download_file "${base}/geosite.dat" "${XRAY_CONFIG_DIR}/geosite.dat" || true
    log_ok "Xray geodata installed"
}

# ---------------------------------------------------------------------------
# Write Xray systemd unit
# ---------------------------------------------------------------------------
_write_xray_systemd() {
    cat > "${XRAY_SYSTEMD}" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=always
RestartSec=5s
LimitNOFILE=65535
WorkingDirectory=${XRAY_CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${XRAY_SYSTEMD}"
}

# ---------------------------------------------------------------------------
# Write initial Xray config (placeholder)
# ---------------------------------------------------------------------------
_write_xray_initial_config() {
    cat > "${XRAY_CONFIG}" <<'EOF'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
    chmod 640 "${XRAY_CONFIG}"
}

# ---------------------------------------------------------------------------
# Rebuild full Xray config from all users
# ---------------------------------------------------------------------------
xray_rebuild_config() {
    local inbounds_json="[]"

    # Load all protocol configs from users DB
    local vmess_users=()
    local vless_users=()
    local trojan_users=()
    local ss_users=()

    for conf in "${XRAY_USERS_DB}"/*.conf; do
        [[ -f "${conf}" ]] || continue
        local type uuid password domain
        type="$(get_config_value "${conf}" "TYPE")"
        uuid="$(get_config_value "${conf}" "UUID")"
        password="$(get_config_value "${conf}" "PASSWORD")"

        case "${type}" in
            vmess)  vmess_users+=("${uuid}") ;;
            vless)  vless_users+=("${uuid}") ;;
            trojan) trojan_users+=("${password}") ;;
            shadowsocks) ss_users+=("${password}") ;;
        esac
    done

    _regenerate_xray_config \
        "${vmess_users[*]:-}" \
        "${vless_users[*]:-}" \
        "${trojan_users[*]:-}" \
        "${ss_users[*]:-}"

    systemctl restart xray 2>/dev/null || true
    log_ok "Xray configuration rebuilt"
}

# ---------------------------------------------------------------------------
# Regenerate Xray config JSON with all protocols
# ---------------------------------------------------------------------------
_regenerate_xray_config() {
    local domain
    domain="$(get_config_value "${VPN_CONFIG_FILE:-/etc/vpn-manager/vpn.conf}" "DOMAIN" 2>/dev/null || echo '')"

    local tls_section=""
    if [[ -n "${domain}" ]] && [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
        tls_section='"security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/'"${domain}"'/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/'"${domain}"'/privkey.pem"
            }
          ]
        },'
    fi

    local reality_public_key reality_private_key reality_short_id=""
    # Generate REALITY keys if xray supports it
    if "${XRAY_BIN}" x25519 &>/dev/null 2>&1; then
        local keys
        keys="$("${XRAY_BIN}" x25519 2>/dev/null)"
        reality_private_key="$(echo "${keys}" | grep 'Private' | awk '{print $NF}')"
        reality_public_key="$(echo "${keys}" | grep 'Public' | awk '{print $NF}')"
        reality_short_id="$(openssl rand -hex 8)"
    fi

    python3 - <<PYEOF
import json, sys

config = {
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [],
  "outbounds": [
    {"protocol": "freedom", "settings": {}},
    {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}
    ]
  }
}

with open("${XRAY_CONFIG}", "w") as f:
    json.dump(config, f, indent=2)

print("Config written")
PYEOF

    log_ok "Xray config regenerated"
}

# ---------------------------------------------------------------------------
# Create VLESS user
# ---------------------------------------------------------------------------
xray_create_vless() {
    local username="$1"
    local days="${2:-30}"
    local traffic_limit="${3:-0}"
    local ip_limit="${4:-0}"

    validate_username "${username}" || return 1

    local uuid
    uuid="$(generate_uuid)"
    local expiry
    expiry="$(days_from_now "${days}")"
    local domain
    domain="$(get_config_value "/etc/vpn-manager/vpn.conf" "DOMAIN" 2>/dev/null || echo "${SERVER_IPV4:-}")"

    local user_conf="${XRAY_USERS_DB}/${username}_vless.conf"
    cat > "${user_conf}" <<EOF
USERNAME=${username}
TYPE=vless
UUID=${uuid}
DOMAIN=${domain}
PORT=${XRAY_VLESS_PORT}
CREATED=$(date +%Y-%m-%d)
EXPIRY=${expiry}
TRAFFIC_LIMIT=${traffic_limit}
TRAFFIC_USED=0
IP_LIMIT=${ip_limit}
STATUS=active
EOF
    chmod 600 "${user_conf}"

    xray_rebuild_config

    # Generate subscription link
    local sub_link
    sub_link="vless://${uuid}@${domain}:${XRAY_VLESS_PORT}?encryption=none&security=tls&sni=${domain}&type=ws&path=%2Fws#${username}-VLESS"

    log_activity "CREATE_VLESS" "${username} uuid=${uuid}"
    log_ok "VLESS user created: ${username}"

    _xray_print_user_info "VLESS" "${username}" "${uuid}" "${domain}" \
        "${XRAY_VLESS_PORT}" "${expiry}" "${sub_link}"
}

# ---------------------------------------------------------------------------
# Create VMess user
# ---------------------------------------------------------------------------
xray_create_vmess() {
    local username="$1"
    local days="${2:-30}"
    local traffic_limit="${3:-0}"

    validate_username "${username}" || return 1

    local uuid
    uuid="$(generate_uuid)"
    local expiry
    expiry="$(days_from_now "${days}")"
    local domain
    domain="$(get_config_value "/etc/vpn-manager/vpn.conf" "DOMAIN" 2>/dev/null || echo "${SERVER_IPV4:-}")"

    local user_conf="${XRAY_USERS_DB}/${username}_vmess.conf"
    cat > "${user_conf}" <<EOF
USERNAME=${username}
TYPE=vmess
UUID=${uuid}
DOMAIN=${domain}
PORT=${XRAY_VMESS_WS_PORT}
CREATED=$(date +%Y-%m-%d)
EXPIRY=${expiry}
TRAFFIC_LIMIT=${traffic_limit}
TRAFFIC_USED=0
STATUS=active
EOF
    chmod 600 "${user_conf}"

    xray_rebuild_config

    # Generate VMess link
    local vmess_json
    vmess_json="$(python3 -c "
import json, base64
d = {
    'v': '2',
    'ps': '${username}-VMess',
    'add': '${domain}',
    'port': '${XRAY_VMESS_WS_PORT}',
    'id': '${uuid}',
    'aid': '0',
    'scy': 'auto',
    'net': 'ws',
    'type': 'none',
    'host': '${domain}',
    'path': '/ws',
    'tls': 'tls',
    'sni': '${domain}',
    'alpn': ''
}
print('vmess://' + base64.b64encode(json.dumps(d).encode()).decode())
" 2>/dev/null || echo "vmess://[encoding error]")"

    log_activity "CREATE_VMESS" "${username} uuid=${uuid}"
    log_ok "VMess user created: ${username}"

    _xray_print_user_info "VMess" "${username}" "${uuid}" "${domain}" \
        "${XRAY_VMESS_WS_PORT}" "${expiry}" "${vmess_json}"
}

# ---------------------------------------------------------------------------
# Create Trojan user
# ---------------------------------------------------------------------------
xray_create_trojan() {
    local username="$1"
    local days="${2:-30}"
    local traffic_limit="${3:-0}"

    validate_username "${username}" || return 1

    local password
    password="$(generate_simple_password 16)"
    local expiry
    expiry="$(days_from_now "${days}")"
    local domain
    domain="$(get_config_value "/etc/vpn-manager/vpn.conf" "DOMAIN" 2>/dev/null || echo "${SERVER_IPV4:-}")"

    local user_conf="${XRAY_USERS_DB}/${username}_trojan.conf"
    cat > "${user_conf}" <<EOF
USERNAME=${username}
TYPE=trojan
PASSWORD=${password}
DOMAIN=${domain}
PORT=${XRAY_TROJAN_PORT}
CREATED=$(date +%Y-%m-%d)
EXPIRY=${expiry}
TRAFFIC_LIMIT=${traffic_limit}
TRAFFIC_USED=0
STATUS=active
EOF
    chmod 600 "${user_conf}"

    xray_rebuild_config

    local sub_link="trojan://${password}@${domain}:${XRAY_TROJAN_PORT}?sni=${domain}#${username}-Trojan"

    log_activity "CREATE_TROJAN" "${username}"
    log_ok "Trojan user created: ${username}"

    _xray_print_user_info "Trojan" "${username}" "${password}" "${domain}" \
        "${XRAY_TROJAN_PORT}" "${expiry}" "${sub_link}"
}

# ---------------------------------------------------------------------------
# Create Shadowsocks user
# ---------------------------------------------------------------------------
xray_create_shadowsocks() {
    local username="$1"
    local days="${2:-30}"
    local traffic_limit="${3:-0}"
    local method="${4:-chacha20-poly1305}"

    validate_username "${username}" || return 1

    local password
    password="$(generate_simple_password 20)"
    local expiry
    expiry="$(days_from_now "${days}")"
    local domain
    domain="$(get_config_value "/etc/vpn-manager/vpn.conf" "DOMAIN" 2>/dev/null || echo "${SERVER_IPV4:-}")"
    local port
    port="$(get_random_port 20000 30000)"

    local user_conf="${XRAY_USERS_DB}/${username}_ss.conf"
    cat > "${user_conf}" <<EOF
USERNAME=${username}
TYPE=shadowsocks
METHOD=${method}
PASSWORD=${password}
DOMAIN=${domain}
PORT=${port}
CREATED=$(date +%Y-%m-%d)
EXPIRY=${expiry}
TRAFFIC_LIMIT=${traffic_limit}
TRAFFIC_USED=0
STATUS=active
EOF
    chmod 600 "${user_conf}"

    xray_rebuild_config

    local ss_b64
    ss_b64="$(echo -n "${method}:${password}" | base64 | tr -d '=')"
    local sub_link="ss://${ss_b64}@${domain}:${port}#${username}-SS"

    log_activity "CREATE_SS" "${username}"
    log_ok "Shadowsocks user created: ${username}"

    _xray_print_user_info "Shadowsocks" "${username}" "${password}" "${domain}" \
        "${port}" "${expiry}" "${sub_link}"
}

# ---------------------------------------------------------------------------
# Delete Xray user
# ---------------------------------------------------------------------------
xray_delete_user() {
    local username="$1"
    local protocol="${2:-}"  # vless, vmess, trojan, shadowsocks

    if [[ -n "${protocol}" ]]; then
        local conf="${XRAY_USERS_DB}/${username}_${protocol}.conf"
        if [[ -f "${conf}" ]]; then
            rm -f "${conf}"
            log_ok "Deleted ${protocol} user: ${username}"
        else
            log_error "User config not found: ${conf}"
            return 1
        fi
    else
        # Delete all protocols for this user
        local found=0
        for conf in "${XRAY_USERS_DB}/${username}_"*.conf; do
            [[ -f "${conf}" ]] || continue
            rm -f "${conf}"
            (( found++ ))
        done
        if [[ "${found}" -eq 0 ]]; then
            log_error "No Xray configs found for user: ${username}"
            return 1
        fi
        log_ok "Deleted all Xray configs for: ${username} (${found} removed)"
    fi

    xray_rebuild_config
    log_activity "DELETE_XRAY_USER" "${username} protocol=${protocol:-all}"
}

# ---------------------------------------------------------------------------
# Extend Xray user
# ---------------------------------------------------------------------------
xray_extend_user() {
    local username="$1"
    local days="${2:-30}"
    local protocol="${3:-}"

    local pattern="${XRAY_USERS_DB}/${username}_${protocol:-*}.conf"

    for conf in ${pattern}; do
        [[ -f "${conf}" ]] || continue
        local current_expiry
        current_expiry="$(get_config_value "${conf}" "EXPIRY")"
        local new_expiry
        if [[ -n "${current_expiry}" ]]; then
            new_expiry="$(date -d "${current_expiry} +${days} days" +%Y-%m-%d 2>/dev/null || days_from_now "${days}")"
        else
            new_expiry="$(days_from_now "${days}")"
        fi
        sed -i "s/^EXPIRY=.*/EXPIRY=${new_expiry}/" "${conf}"
        log_ok "Extended $(basename "${conf}" .conf) to: ${new_expiry}"
    done

    log_activity "EXTEND_XRAY_USER" "${username} +${days}days"
}

# ---------------------------------------------------------------------------
# Print user info with QR code
# ---------------------------------------------------------------------------
_xray_print_user_info() {
    local protocol="$1"
    local username="$2"
    local credential="$3"
    local domain="$4"
    local port="$5"
    local expiry="$6"
    local sub_link="$7"

    echo ""
    print_color "${GREEN}" "  ┌────────────────────────────────────────────┐"
    print_color "${GREEN}" "  │         ${protocol} User Created                   │"
    print_color "${GREEN}" "  ├────────────────────────────────────────────┤"
    print_key_value "  Username" "${username}"
    print_key_value "  ${protocol} ID/Pass" "${credential}" "${CYAN}" "${YELLOW}"
    print_key_value "  Server" "${domain}"
    print_key_value "  Port" "${port}"
    print_key_value "  Expires" "${expiry}"
    print_color "${GREEN}" "  ├────────────────────────────────────────────┤"
    print_color "${CYAN}" "  Link:"
    echo "  ${sub_link}"
    echo ""

    # Generate QR code if qrencode is available
    if command -v qrencode &>/dev/null; then
        print_color "${CYAN}" "  QR Code:"
        qrencode -t ansiutf8 "${sub_link}" 2>/dev/null || true
    fi

    print_color "${GREEN}" "  └────────────────────────────────────────────┘"
    echo ""
}

# ---------------------------------------------------------------------------
# Update Xray
# ---------------------------------------------------------------------------
xray_update() {
    log_info "Updating Xray-core..."
    local current_version="unknown"
    [[ -x "${XRAY_BIN}" ]] && current_version="$("${XRAY_BIN}" version 2>/dev/null | head -1 | awk '{print $2}')"

    local new_version
    new_version="$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | jq -r '.tag_name' 2>/dev/null || echo '')"

    if [[ -z "${new_version}" ]]; then
        log_error "Could not fetch latest Xray version"
        return 1
    fi

    if [[ "${current_version}" == "${new_version}" ]]; then
        log_ok "Xray is already up to date: ${current_version}"
        return 0
    fi

    log_info "Updating ${current_version} → ${new_version}"

    # Backup current binary
    [[ -f "${XRAY_BIN}" ]] && cp "${XRAY_BIN}" "${XRAY_BIN}.bak"

    local download_url
    download_url="$(get_xray_download_url "${new_version}")"
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    if download_file "${download_url}" "${tmp_dir}/xray.zip"; then
        unzip -q "${tmp_dir}/xray.zip" -d "${tmp_dir}"
        install -m 755 "${tmp_dir}/xray" "${XRAY_BIN}"
        systemctl restart xray
        log_ok "Xray updated to ${new_version}"
    else
        log_error "Xray update failed. Restoring backup."
        [[ -f "${XRAY_BIN}.bak" ]] && mv "${XRAY_BIN}.bak" "${XRAY_BIN}"
        return 1
    fi

    rm -rf "${tmp_dir}"
}

# ---------------------------------------------------------------------------
# List Xray users
# ---------------------------------------------------------------------------
xray_list_users() {
    local filter_type="${1:-}"

    echo ""
    print_header "Xray Users"
    echo ""
    printf "  ${CYAN}%-20s %-15s %-15s %-10s${RESET}\n" "Username" "Protocol" "Expires" "Status"
    print_separator "-" 65 "${GRAY}"

    for conf in "${XRAY_USERS_DB}"/*_*.conf; do
        [[ -f "${conf}" ]] || continue
        local username type expiry status
        username="$(get_config_value "${conf}" "USERNAME")"
        type="$(get_config_value "${conf}" "TYPE")"
        expiry="$(get_config_value "${conf}" "EXPIRY")"
        status="$(get_config_value "${conf}" "STATUS")"

        [[ "${type}" == "ssh" ]] && continue
        [[ -n "${filter_type}" && "${type}" != "${filter_type}" ]] && continue

        local color="${WHITE}"
        [[ "${status}" == "expired" ]] && color="${RED}"

        printf "  ${color}%-20s %-15s %-15s %-10s${RESET}\n" \
            "${username}" "${type}" "${expiry:-N/A}" "${status:-active}"
    done
    echo ""
}
