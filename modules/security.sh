#!/usr/bin/env bash
# =============================================================================
# modules/security.sh - Firewall, Fail2Ban, and system hardening
# =============================================================================

FAIL2BAN_CONFIG_DIR="/etc/fail2ban"
FAIL2BAN_JAIL_LOCAL="${FAIL2BAN_CONFIG_DIR}/jail.local"
FAIL2BAN_VPN_FILTER="${FAIL2BAN_CONFIG_DIR}/filter.d/vpn-manager.conf"
UFW_RULES_FILE="/etc/ufw/applications.d/vpn-manager"
SECURITY_CONFIG="/etc/vpn-manager/security.conf"

# ---------------------------------------------------------------------------
# Main security configuration
# ---------------------------------------------------------------------------
module_configure_security() {
    log_info "Configuring security components..."

    _configure_ufw
    _configure_fail2ban
    _configure_sysctl_security
    _configure_auto_updates
    _write_security_config

    log_ok "Security configuration complete"
}

# ---------------------------------------------------------------------------
# UFW Firewall
# ---------------------------------------------------------------------------
_configure_ufw() {
    log_info "Configuring UFW firewall..."

    # Default policies
    ufw --force reset 2>/dev/null || true
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH (OpenSSH)
    local ssh_port="${SSHD_PORT:-22}"
    ufw allow "${ssh_port}/tcp" comment "OpenSSH"

    # Allow Dropbear
    local dropbear_port="${DROPBEAR_PORT:-444}"
    ufw allow "${dropbear_port}/tcp" comment "Dropbear"

    # Allow HTTP/HTTPS
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    ufw allow 443/udp comment "HTTPS UDP (QUIC)"

    # Allow WireGuard
    local wg_port="${WG_PORT:-51820}"
    ufw allow "${wg_port}/udp" comment "WireGuard"

    # Allow Hysteria2
    local hy2_port="${HY2_PORT:-8443}"
    ufw allow "${hy2_port}/udp" comment "Hysteria2"

    # Allow VMess WS port (internal, proxied via Nginx)
    # These are local-only, not opened in firewall

    # Enable UFW
    ufw --force enable
    log_ok "UFW firewall configured and enabled"

    # Write UFW rules summary
    ufw status verbose 2>&1 | tee -a "${LOG_FILE:-/dev/null}" || true
}

# ---------------------------------------------------------------------------
# Open a specific port in UFW
# ---------------------------------------------------------------------------
security_open_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local comment="${3:-VPN Manager}"

    ufw allow "${port}/${proto}" comment "${comment}"
    log_ok "Port opened: ${port}/${proto}"
}

# ---------------------------------------------------------------------------
# Close a specific port in UFW
# ---------------------------------------------------------------------------
security_close_port() {
    local port="$1"
    local proto="${2:-tcp}"

    ufw delete allow "${port}/${proto}" 2>/dev/null || true
    log_ok "Port closed: ${port}/${proto}"
}

# ---------------------------------------------------------------------------
# Fail2Ban configuration
# ---------------------------------------------------------------------------
_configure_fail2ban() {
    log_info "Configuring Fail2Ban..."

    # Write jail.local
    cat > "${FAIL2BAN_JAIL_LOCAL}" <<EOF
# Fail2Ban Configuration - Managed by VPN Manager
[DEFAULT]
bantime   = 3600
findtime  = 600
maxretry  = 5
backend   = systemd
banaction = ufw

[sshd]
enabled  = true
port     = ${SSHD_PORT:-22},${DROPBEAR_PORT:-444}
maxretry = 4
bantime  = 7200
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s

[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/error.log
maxretry = 5

[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/error.log
maxretry = 10

[vpn-manager]
enabled  = true
port     = ${SSHD_PORT:-22},${DROPBEAR_PORT:-444}
filter   = vpn-manager
logpath  = /var/log/vpn-manager/activity.log
maxretry = 10
bantime  = 3600
EOF

    # Write custom filter
    cat > "${FAIL2BAN_VPN_FILTER}" <<'EOF'
[Definition]
failregex = .*\[<HOST>\].*(FAILED|failed|error|ERROR).*
ignoreregex =
EOF

    # Systemd override
    local f2b_override="/etc/systemd/system/fail2ban.service.d"
    mkdir -p "${f2b_override}"
    cat > "${f2b_override}/override.conf" <<EOF
[Service]
Restart=always
RestartSec=5s
EOF

    systemctl daemon-reload
    systemctl enable fail2ban
    systemctl restart fail2ban

    if systemctl is-active --quiet fail2ban; then
        log_ok "Fail2Ban configured and running"
    else
        log_warn "Fail2Ban may not have started. Check: journalctl -u fail2ban"
    fi
}

# ---------------------------------------------------------------------------
# Sysctl security hardening
# ---------------------------------------------------------------------------
_configure_sysctl_security() {
    local sysctl_file="/etc/sysctl.d/99-vpn-manager.conf"

    cat > "${sysctl_file}" <<'EOF'
# VPN Manager - Security sysctl settings

# IP forwarding (required for VPN)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Disable IP source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Enable reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Log suspicious packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# TCP SYN cookies (SYN flood protection)
net.ipv4.tcp_syncookies = 1

# Increase file descriptor limits
fs.file-max = 1000000

# Increase connection tracking table
net.netfilter.nf_conntrack_max = 1048576

# TCP performance
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_max_syn_backlog = 30000
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_mtu_probing = 1
EOF

    sysctl -p "${sysctl_file}" 2>&1 | grep -v "No such file" | tee -a "${LOG_FILE:-/dev/null}" || true
    log_ok "Sysctl security settings applied"
}

# ---------------------------------------------------------------------------
# Automatic security updates
# ---------------------------------------------------------------------------
_configure_auto_updates() {
    log_info "Configuring automatic security updates..."

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades apt-listchanges 2>/dev/null || true

    local auto_upgrades_file="/etc/apt/apt.conf.d/20auto-upgrades"
    cat > "${auto_upgrades_file}" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    local unattended_file="/etc/apt/apt.conf.d/50unattended-upgrades"
    if [[ -f "${unattended_file}" ]]; then
        # Enable security updates
        sed -i 's|//.*"${distro_id}:${distro_codename}-security";|"${distro_id}:${distro_codename}-security";|g' \
            "${unattended_file}" 2>/dev/null || true
    fi

    log_ok "Automatic security updates configured"
}

# ---------------------------------------------------------------------------
# Write security config
# ---------------------------------------------------------------------------
_write_security_config() {
    cat > "${SECURITY_CONFIG}" <<EOF
# VPN Manager Security Config
FIREWALL=ufw
FAIL2BAN=enabled
AUTO_UPDATES=enabled
SSH_PORT=${SSHD_PORT:-22}
DROPBEAR_PORT=${DROPBEAR_PORT:-444}
WG_PORT=${WG_PORT:-51820}
HY2_PORT=${HY2_PORT:-8443}
EOF
    chmod 600 "${SECURITY_CONFIG}"
}

# ---------------------------------------------------------------------------
# Show firewall status
# ---------------------------------------------------------------------------
security_show_status() {
    echo ""
    print_header "Security Status"
    echo ""
    print_key_value "  UFW Status" "$(ufw status | head -1 | awk '{print $2}')"
    print_key_value "  Fail2Ban" "$(service_status fail2ban)"
    echo ""
    ufw status numbered 2>/dev/null || true
    echo ""
    if systemctl is-active --quiet fail2ban; then
        fail2ban-client status 2>/dev/null | head -20 || true
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# List banned IPs
# ---------------------------------------------------------------------------
security_list_banned() {
    echo ""
    print_header "Banned IPs (Fail2Ban)"
    echo ""
    if systemctl is-active --quiet fail2ban; then
        fail2ban-client status sshd 2>/dev/null || true
    else
        log_warn "Fail2Ban is not running"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Unban IP
# ---------------------------------------------------------------------------
security_unban_ip() {
    local ip="$1"
    validate_ip "${ip}" || return 1
    fail2ban-client unban "${ip}" 2>/dev/null && log_ok "Unbanned: ${ip}" || log_warn "Could not unban: ${ip}"
}
