#!/usr/bin/env bash
# =============================================================================
# modules/wireguard.sh - WireGuard VPN installation and management
# =============================================================================

WG_INTERFACE="wg0"
WG_CONFIG="/etc/wireguard/${WG_INTERFACE}.conf"
WG_CLIENTS_DIR="/etc/vpn-manager/wireguard"
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET="10.8.0.0/24"
WG_SERVER_IP="10.8.0.1"
WG_DNS="1.1.1.1,8.8.8.8"

# ---------------------------------------------------------------------------
# Install WireGuard
# ---------------------------------------------------------------------------
module_install_wireguard() {
    log_info "Installing WireGuard..."

    if [[ "${IS_CONTAINER:-0}" -eq 1 ]] && [[ "${VIRT_TYPE:-}" == "lxc" ]]; then
        log_warn "LXC container detected. WireGuard kernel module may not be available."
        log_warn "Skipping WireGuard installation in LXC."
        return 0
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard wireguard-tools 2>&1 | \
        tee -a "${INSTALL_LOG:-/dev/null}"

    # Enable IPv4 forwarding
    _enable_ip_forwarding

    mkdir -p "${WG_CLIENTS_DIR}"
    chmod 700 "${WG_CLIENTS_DIR}"
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    # Generate server keys
    if [[ ! -f /etc/wireguard/server_private.key ]]; then
        wg genkey | tee /etc/wireguard/server_private.key | \
            wg pubkey > /etc/wireguard/server_public.key
        chmod 600 /etc/wireguard/server_private.key
        chmod 644 /etc/wireguard/server_public.key
        log_ok "WireGuard server keys generated"
    fi

    _write_wireguard_server_config

    # Install systemd override
    local override_dir="/etc/systemd/system/wg-quick@${WG_INTERFACE}.service.d"
    mkdir -p "${override_dir}"
    cat > "${override_dir}/override.conf" <<EOF
[Service]
Restart=always
RestartSec=5s
EOF

    systemctl daemon-reload
    systemctl enable "wg-quick@${WG_INTERFACE}"
    systemctl start "wg-quick@${WG_INTERFACE}"

    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
        log_ok "WireGuard running on port ${WG_PORT}"
    else
        log_warn "WireGuard may not have started. Check: journalctl -u wg-quick@${WG_INTERFACE}"
    fi
}

module_remove_wireguard() {
    systemctl stop "wg-quick@${WG_INTERFACE}" 2>/dev/null || true
    systemctl disable "wg-quick@${WG_INTERFACE}" 2>/dev/null || true
    log_info "WireGuard stopped (rollback)"
}

# ---------------------------------------------------------------------------
# Enable IP forwarding
# ---------------------------------------------------------------------------
_enable_ip_forwarding() {
    local sysctl_file="/etc/sysctl.d/99-vpn-manager.conf"
    cat > "${sysctl_file}" <<EOF
# VPN Manager - IP Forwarding
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
EOF
    sysctl -p "${sysctl_file}" &>/dev/null || true
    log_ok "IP forwarding enabled"
}

# ---------------------------------------------------------------------------
# Write WireGuard server config
# ---------------------------------------------------------------------------
_write_wireguard_server_config() {
    local private_key
    private_key="$(cat /etc/wireguard/server_private.key)"
    local primary_iface
    primary_iface="$(get_primary_interface)"

    cat > "${WG_CONFIG}" <<EOF
# WireGuard Server Config - Managed by VPN Manager
# Generated: $(date)

[Interface]
PrivateKey = ${private_key}
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
DNS = ${WG_DNS}

# NAT rules
PostUp   = iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o ${primary_iface} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o ${primary_iface} -j MASQUERADE
PostUp   = ip6tables -t nat -A POSTROUTING -s fd42:42:42::/64 -o ${primary_iface} -j MASQUERADE
PostDown = ip6tables -t nat -D POSTROUTING -s fd42:42:42::/64 -o ${primary_iface} -j MASQUERADE

# Clients will be appended below
EOF
    chmod 600 "${WG_CONFIG}"
    log_ok "WireGuard server config written"
}

# ---------------------------------------------------------------------------
# Add WireGuard client
# ---------------------------------------------------------------------------
wg_add_client() {
    local username="$1"
    local days="${2:-30}"
    local traffic_limit="${3:-0}"

    validate_username "${username}" || return 1

    local client_dir="${WG_CLIENTS_DIR}/${username}"
    mkdir -p "${client_dir}"
    chmod 700 "${client_dir}"

    # Generate client keys
    wg genkey | tee "${client_dir}/private.key" | \
        wg pubkey > "${client_dir}/public.key"
    wg genpsk > "${client_dir}/preshared.key"
    chmod 600 "${client_dir}/private.key" "${client_dir}/preshared.key"

    # Assign client IP
    local client_ip
    client_ip="$(_get_next_wg_ip)"

    local server_public_key
    server_public_key="$(cat /etc/wireguard/server_public.key)"
    local client_private_key
    client_private_key="$(cat "${client_dir}/private.key")"
    local client_public_key
    client_public_key="$(cat "${client_dir}/public.key")"
    local preshared_key
    preshared_key="$(cat "${client_dir}/preshared.key")"
    local expiry
    expiry="$(days_from_now "${days}")"

    local server_endpoint
    server_endpoint="${SERVER_IPV4:-$(get_local_ip)}:${WG_PORT}"

    # Write client config file
    local client_conf="${client_dir}/wg-${username}.conf"
    cat > "${client_conf}" <<EOF
[Interface]
PrivateKey = ${client_private_key}
Address = ${client_ip}/32
DNS = ${WG_DNS}

[Peer]
PublicKey = ${server_public_key}
PresharedKey = ${preshared_key}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${server_endpoint}
PersistentKeepalive = 25
EOF
    chmod 600 "${client_conf}"

    # Append peer to server config
    cat >> "${WG_CONFIG}" <<EOF

# Client: ${username} | IP: ${client_ip} | Expires: ${expiry}
[Peer]
PublicKey = ${client_public_key}
PresharedKey = ${preshared_key}
AllowedIPs = ${client_ip}/32
EOF

    # Reload WireGuard
    wg addconf "${WG_INTERFACE}" <(grep -A4 "^# Client: ${username}" "${WG_CONFIG}" | tail -4) 2>/dev/null || \
        systemctl restart "wg-quick@${WG_INTERFACE}" 2>/dev/null || true

    # Store metadata
    cat > "${WG_CLIENTS_DIR}/${username}.conf" <<EOF
USERNAME=${username}
TYPE=wireguard
CLIENT_IP=${client_ip}
EXPIRY=${expiry}
TRAFFIC_LIMIT=${traffic_limit}
TRAFFIC_USED=0
STATUS=active
EOF

    log_activity "CREATE_WG_CLIENT" "${username} ip=${client_ip}"
    log_ok "WireGuard client created: ${username} (${client_ip})"

    echo ""
    print_color "${GREEN}" "  ┌──────────────────────────────────────┐"
    print_color "${GREEN}" "  │      WireGuard Client Created         │"
    print_color "${GREEN}" "  ├──────────────────────────────────────┤"
    print_key_value "  Username" "${username}"
    print_key_value "  Client IP" "${client_ip}"
    print_key_value "  Expires" "${expiry}"
    print_key_value "  Config" "${client_conf}"
    print_color "${GREEN}" "  └──────────────────────────────────────┘"
    echo ""

    if command -v qrencode &>/dev/null; then
        print_color "${CYAN}" "  WireGuard QR Code:"
        qrencode -t ansiutf8 < "${client_conf}" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Remove WireGuard client
# ---------------------------------------------------------------------------
wg_remove_client() {
    local username="$1"
    local client_dir="${WG_CLIENTS_DIR}/${username}"

    if [[ ! -d "${client_dir}" ]]; then
        log_error "WireGuard client not found: ${username}"
        return 1
    fi

    local client_public_key
    client_public_key="$(cat "${client_dir}/public.key" 2>/dev/null || echo '')"

    # Remove peer from server config
    if [[ -n "${client_public_key}" ]]; then
        # Remove the peer block from config
        python3 - <<PYEOF
import re

with open("${WG_CONFIG}", "r") as f:
    content = f.read()

# Remove the peer block for this client
pattern = r'\n# Client: ${username}.*?(?=\n# Client:|\Z)'
content = re.sub(pattern, '', content, flags=re.DOTALL)

# Also remove via wg command
with open("${WG_CONFIG}", "w") as f:
    f.write(content)
PYEOF
        wg set "${WG_INTERFACE}" peer "${client_public_key}" remove 2>/dev/null || true
    fi

    rm -rf "${client_dir}"
    rm -f "${WG_CLIENTS_DIR}/${username}.conf"

    log_activity "DELETE_WG_CLIENT" "${username}"
    log_ok "WireGuard client deleted: ${username}"
}

# ---------------------------------------------------------------------------
# Get next available WireGuard IP
# ---------------------------------------------------------------------------
_get_next_wg_ip() {
    local used_ips
    used_ips="$(grep -oP '10\.8\.0\.\K[0-9]+' "${WG_CONFIG}" 2>/dev/null | sort -n || echo "")"

    for i in {2..254}; do
        if ! echo "${used_ips}" | grep -q "^${i}$"; then
            echo "10.8.0.${i}"
            return 0
        fi
    done

    log_error "No available WireGuard IPs in range 10.8.0.2-254"
    return 1
}

# ---------------------------------------------------------------------------
# Show WireGuard status
# ---------------------------------------------------------------------------
wg_status() {
    echo ""
    print_header "WireGuard Status"
    echo ""
    wg show 2>/dev/null || log_warn "WireGuard interface not active"
    echo ""
}
