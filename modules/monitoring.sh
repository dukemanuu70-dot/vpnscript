#!/usr/bin/env bash
# =============================================================================
# modules/monitoring.sh - System monitoring and statistics
# =============================================================================

# ---------------------------------------------------------------------------
# Setup monitoring (vnstat, etc.)
# ---------------------------------------------------------------------------
module_configure_monitoring() {
    log_info "Setting up monitoring..."

    # vnstat for bandwidth
    if command -v vnstat &>/dev/null; then
        local primary_iface
        primary_iface="$(get_primary_interface)"
        vnstat --add -i "${primary_iface}" 2>/dev/null || true
        systemctl enable vnstat 2>/dev/null || true
        systemctl start vnstat 2>/dev/null || true
        log_ok "vnstat configured on ${primary_iface}"
    fi

    # Setup monitoring cron
    _write_monitoring_cron

    log_ok "Monitoring configured"
}

# ---------------------------------------------------------------------------
# Cron for user expiry checks and traffic monitoring
# ---------------------------------------------------------------------------
_write_monitoring_cron() {
    local cron_file="/etc/cron.d/vpn-manager"
    mkdir -p /etc/cron.d

    cat > "${cron_file}" <<'EOF'
# VPN Manager Cron Jobs
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Check user expiry every hour
0 * * * * root /usr/local/bin/vpn-manager-cron expiry >> /var/log/vpn-manager/cron.log 2>&1

# Traffic monitoring every 5 minutes
*/5 * * * * root /usr/local/bin/vpn-manager-cron traffic >> /var/log/vpn-manager/cron.log 2>&1

# SSL renewal check twice daily
0 2,14 * * * root certbot renew --quiet 2>&1 && systemctl reload nginx 2>/dev/null | tee -a /var/log/vpn-manager/ssl.log

# Log rotation
0 0 * * 0 root logrotate /etc/logrotate.d/vpn-manager
EOF
    chmod 644 "${cron_file}"

    # Write the cron helper script
    cat > /usr/local/bin/vpn-manager-cron <<'CRONSCRIPT'
#!/usr/bin/env bash
SCRIPT_DIR="/opt/vpn-manager"
source "${SCRIPT_DIR}/lib/colors.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/logger.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/utils.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/validate.sh" 2>/dev/null || true

case "${1:-}" in
    expiry)
        source "${SCRIPT_DIR}/modules/ssh.sh" 2>/dev/null || true
        ssh_check_expiry 2>/dev/null || true
        ;;
    traffic)
        # Traffic monitoring placeholder
        true
        ;;
esac
CRONSCRIPT
    chmod 755 /usr/local/bin/vpn-manager-cron
}

# ---------------------------------------------------------------------------
# Show system info dashboard
# ---------------------------------------------------------------------------
monitoring_show_system_info() {
    echo ""
    print_header "System Information"
    echo ""

    # OS info
    local os_info="${OS_ID:-$(. /etc/os-release && echo "${ID}")} ${OS_VERSION:-$(. /etc/os-release && echo "${VERSION_ID}")}"
    print_key_value "  OS" "${os_info}"
    print_key_value "  Kernel" "$(uname -r)"
    print_key_value "  Arch" "$(uname -m)"
    print_key_value "  Hostname" "$(hostname)"
    print_key_value "  Uptime" "$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}' | tr -d ',')"
    echo ""

    # CPU
    local cpu_model cpu_cores cpu_usage
    cpu_model="$(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    cpu_cores="$(nproc)"
    cpu_usage="$(top -bn1 | grep 'Cpu(s)' | awk '{print $2}' | tr -d '%us,' 2>/dev/null || echo 'N/A')"
    print_key_value "  CPU" "${cpu_model}"
    print_key_value "  Cores" "${cpu_cores}"
    print_key_value "  CPU Usage" "${cpu_usage}%"
    echo ""

    # Memory
    local total_ram used_ram free_ram
    total_ram="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)MB"
    used_ram="$(awk '/MemAvailable/{avail=$2} /MemTotal/{total=$2} END{print int((total-avail)/1024)}' /proc/meminfo)MB"
    free_ram="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)MB"
    print_key_value "  Total RAM" "${total_ram}"
    print_key_value "  Used RAM" "${used_ram}"
    print_key_value "  Free RAM" "${free_ram}"
    echo ""

    # Disk
    local disk_info
    disk_info="$(df -h / | tail -1 | awk '{print "Total:"$2" Used:"$3" Free:"$4" ("$5" used)"}')"
    print_key_value "  Disk" "${disk_info}"
    echo ""

    # Network
    print_key_value "  IPv4" "${SERVER_IPV4:-$(curl -4 -s --max-time 5 https://ipv4.icanhazip.com 2>/dev/null || echo 'N/A')}"
    print_key_value "  IPv6" "${SERVER_IPV6:-N/A}"
    print_key_value "  Interface" "$(get_primary_interface 2>/dev/null || echo 'N/A')"
    echo ""

    # Load average
    local load
    load="$(cat /proc/loadavg | awk '{print $1,$2,$3}')"
    print_key_value "  Load Average" "${load}"
    echo ""
}

# ---------------------------------------------------------------------------
# Show service status
# ---------------------------------------------------------------------------
monitoring_show_services() {
    echo ""
    print_header "Service Status"
    echo ""

    local services=("ssh:OpenSSH" "dropbear:Dropbear" "nginx:Nginx"
                     "xray:Xray-core" "fail2ban:Fail2Ban" "ufw:UFW"
                     "wg-quick@wg0:WireGuard" "hysteria-server:Hysteria2")

    for entry in "${services[@]}"; do
        local svc label status color
        svc="${entry%%:*}"
        label="${entry##*:}"
        status="$(service_status "${svc}" 2>/dev/null || echo 'unknown')"

        case "${status}" in
            running) color="${GREEN}"; symbol="●" ;;
            stopped) color="${YELLOW}"; symbol="○" ;;
            *)       color="${GRAY}";   symbol="○" ;;
        esac

        printf "  ${color}${symbol}${RESET} %-20s ${color}%s${RESET}\n" "${label}" "${status}"
    done
    echo ""
}

# ---------------------------------------------------------------------------
# CPU usage
# ---------------------------------------------------------------------------
monitoring_cpu() {
    echo ""
    print_header "CPU Usage"
    echo ""
    print_key_value "  Load Average" "$(cat /proc/loadavg | awk '{print $1,$2,$3}')"
    print_key_value "  Cores" "$(nproc)"
    echo ""
    top -bn1 | head -20
    echo ""
}

# ---------------------------------------------------------------------------
# RAM usage
# ---------------------------------------------------------------------------
monitoring_ram() {
    echo ""
    print_header "Memory Usage"
    echo ""
    free -h
    echo ""
}

# ---------------------------------------------------------------------------
# Disk usage
# ---------------------------------------------------------------------------
monitoring_disk() {
    echo ""
    print_header "Disk Usage"
    echo ""
    df -h
    echo ""
    print_header "Largest Directories (top 10)"
    du -sh /var/* /etc/* /opt/* 2>/dev/null | sort -rh | head -10
    echo ""
}

# ---------------------------------------------------------------------------
# Bandwidth usage
# ---------------------------------------------------------------------------
monitoring_bandwidth() {
    echo ""
    print_header "Bandwidth Usage"
    echo ""

    local iface
    iface="$(get_primary_interface)"

    if command -v vnstat &>/dev/null; then
        vnstat -i "${iface}" 2>/dev/null || log_warn "vnstat data not available yet"
    else
        # Fallback: show /proc/net/dev
        local rx_bytes tx_bytes
        rx_bytes="$(awk '/'"${iface}"'/{print $2}' /proc/net/dev 2>/dev/null | head -1 || echo 0)"
        tx_bytes="$(awk '/'"${iface}"'/{print $10}' /proc/net/dev 2>/dev/null | head -1 || echo 0)"
        print_key_value "  RX" "$(human_size "${rx_bytes}")"
        print_key_value "  TX" "$(human_size "${tx_bytes}")"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Network information
# ---------------------------------------------------------------------------
monitoring_network_info() {
    echo ""
    print_header "Network Information"
    echo ""
    print_key_value "  Public IPv4" "${SERVER_IPV4:-N/A}"
    print_key_value "  Public IPv6" "${SERVER_IPV6:-N/A}"
    print_key_value "  Gateway" "$(ip route | awk '/default/{print $3}' | head -1)"
    print_key_value "  Interface" "$(get_primary_interface)"
    echo ""
    ip addr show "$(get_primary_interface)" 2>/dev/null | head -20
    echo ""
}

# ---------------------------------------------------------------------------
# Speed test
# ---------------------------------------------------------------------------
monitoring_speedtest() {
    echo ""
    print_header "Speed Test"
    echo ""
    if command -v speedtest-cli &>/dev/null; then
        log_info "Running speed test (this may take a moment)..."
        speedtest-cli --simple 2>&1 || log_warn "Speed test failed"
    elif command -v speedtest &>/dev/null; then
        speedtest 2>&1 || log_warn "Speed test failed"
    else
        log_warn "speedtest-cli not found. Install: apt-get install speedtest-cli"
    fi
    echo ""
}
