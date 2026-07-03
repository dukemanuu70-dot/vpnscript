#!/usr/bin/env bash
# =============================================================================
# modules/bbr.sh - BBR congestion control management
# =============================================================================

BBR_SYSCTL_FILE="/etc/sysctl.d/98-bbr.conf"

# ---------------------------------------------------------------------------
# Check if BBR is supported
# ---------------------------------------------------------------------------
bbr_is_supported() {
    # BBR requires kernel 4.9+
    local kernel_major kernel_minor
    kernel_major="$(uname -r | cut -d. -f1)"
    kernel_minor="$(uname -r | cut -d. -f2)"

    if [[ "${kernel_major}" -lt 4 ]]; then
        return 1
    fi
    if [[ "${kernel_major}" -eq 4 && "${kernel_minor}" -lt 9 ]]; then
        return 1
    fi

    # Check if module is available
    if [[ "${IS_CONTAINER:-0}" -eq 1 ]]; then
        log_warn "Container environment. BBR may not be available."
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Check if BBR is currently active
# ---------------------------------------------------------------------------
bbr_is_active() {
    local current_cc
    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'cubic')"
    local current_qdisc
    current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'pfifo_fast')"

    [[ "${current_cc}" == "bbr" ]] && [[ "${current_qdisc}" == "fq" ]]
}

# ---------------------------------------------------------------------------
# Enable BBR
# ---------------------------------------------------------------------------
module_enable_bbr() {
    log_info "Enabling BBR congestion control..."

    if ! bbr_is_supported; then
        log_warn "BBR not supported on kernel $(uname -r). Minimum: 4.9"
        log_warn "Skipping BBR configuration."
        return 0
    fi

    # Load tcp_bbr module
    if ! lsmod | grep -q "^tcp_bbr"; then
        modprobe tcp_bbr 2>/dev/null || true
        # Persist module load
        echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf 2>/dev/null || true
    fi

    cat > "${BBR_SYSCTL_FILE}" <<'EOF'
# BBR Congestion Control - Managed by VPN Manager
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl -p "${BBR_SYSCTL_FILE}" 2>&1 | tee -a "${LOG_FILE:-/dev/null}" || true

    if bbr_is_active; then
        log_ok "BBR enabled and active"
    else
        log_warn "BBR may not be active. Current: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    fi
}

# ---------------------------------------------------------------------------
# Disable BBR (revert to cubic)
# ---------------------------------------------------------------------------
module_disable_bbr() {
    log_info "Disabling BBR (reverting to cubic)..."

    cat > "${BBR_SYSCTL_FILE}" <<'EOF'
# Congestion control - managed by VPN Manager (BBR disabled)
net.core.default_qdisc = pfifo_fast
net.ipv4.tcp_congestion_control = cubic
EOF

    sysctl -p "${BBR_SYSCTL_FILE}" 2>/dev/null || true
    log_ok "BBR disabled. Using cubic."
}

# ---------------------------------------------------------------------------
# Show BBR status
# ---------------------------------------------------------------------------
bbr_status() {
    local current_cc
    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'unknown')"
    local current_qdisc
    current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'unknown')"
    local kernel
    kernel="$(uname -r)"

    echo ""
    print_header "BBR Status"
    echo ""
    print_key_value "  Kernel" "${kernel}"
    print_key_value "  TCP Congestion" "${current_cc}"
    print_key_value "  Default QDisc" "${current_qdisc}"

    if bbr_is_active; then
        print_key_value "  BBR Status" "${GREEN}ACTIVE${RESET}"
    else
        print_key_value "  BBR Status" "${YELLOW}INACTIVE${RESET}"
    fi

    echo ""
    # Available algorithms
    if [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        print_key_value "  Available" "$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
    fi
    echo ""
}
