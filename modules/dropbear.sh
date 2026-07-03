#!/usr/bin/env bash
# =============================================================================
# modules/dropbear.sh - Dropbear SSH server installation and configuration
# =============================================================================

DROPBEAR_PORT="${DROPBEAR_PORT:-444}"
DROPBEAR_CONFIG="/etc/default/dropbear"
DROPBEAR_SYSTEMD="/etc/systemd/system/dropbear.service"

# ---------------------------------------------------------------------------
# Install Dropbear
# ---------------------------------------------------------------------------
module_install_dropbear() {
    log_info "Installing Dropbear..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dropbear 2>&1 | \
        tee -a "${INSTALL_LOG:-/dev/null}"

    _write_dropbear_config
    _write_dropbear_systemd
    _write_dropbear_default

    systemctl daemon-reload
    systemctl enable dropbear
    systemctl restart dropbear

    if systemctl is-active --quiet dropbear; then
        log_ok "Dropbear running on port ${DROPBEAR_PORT}"
    else
        log_warn "Dropbear may not have started. Check: journalctl -u dropbear"
    fi
}

module_remove_dropbear() {
    systemctl stop dropbear 2>/dev/null || true
    systemctl disable dropbear 2>/dev/null || true
    log_info "Dropbear stopped and disabled"
}

# ---------------------------------------------------------------------------
# Write /etc/default/dropbear
# ---------------------------------------------------------------------------
_write_dropbear_default() {
    cat > "${DROPBEAR_CONFIG}" <<EOF
# Dropbear Configuration - Managed by VPN Manager

# Set to NO to disable dropbear service
NO_START=0

# Port
DROPBEAR_PORT=${DROPBEAR_PORT}

# Extra arguments
DROPBEAR_EXTRA_ARGS="-w -s"

# Banner file
DROPBEAR_BANNER=/etc/vpn-manager/ssh_banner

# Receive window size
DROPBEAR_RECEIVE_WINDOW=65536
EOF
    chmod 644 "${DROPBEAR_CONFIG}"
}

# ---------------------------------------------------------------------------
# Write secure Dropbear config options
# ---------------------------------------------------------------------------
_write_dropbear_config() {
    # Ensure host keys exist
    if [[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]]; then
        mkdir -p /etc/dropbear
        dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key -s 521 2>/dev/null || true
        dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null || true
        dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key -s 4096 2>/dev/null || true
        log_ok "Dropbear host keys generated"
    fi
}

# ---------------------------------------------------------------------------
# Write systemd unit for Dropbear
# ---------------------------------------------------------------------------
_write_dropbear_systemd() {
    cat > "${DROPBEAR_SYSTEMD}" <<EOF
[Unit]
Description=Dropbear SSH Daemon
Documentation=man:dropbear(8)
After=network.target auditd.service
ConditionPathExists=!/etc/ssh/sshd_not_to_be_run

[Service]
EnvironmentFile=-/etc/default/dropbear
ExecStartPre=/bin/mkdir -p /run/dropbear
ExecStart=/usr/sbin/dropbear -F -E \
  -p ${DROPBEAR_PORT} \
  -w \
  -s \
  -r /etc/dropbear/dropbear_ecdsa_host_key \
  -r /etc/dropbear/dropbear_ed25519_host_key \
  -r /etc/dropbear/dropbear_rsa_host_key
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=always
RestartSec=5s
Type=simple

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${DROPBEAR_SYSTEMD}"
}

# ---------------------------------------------------------------------------
# Change Dropbear port
# ---------------------------------------------------------------------------
dropbear_change_port() {
    local new_port="$1"

    validate_port "${new_port}" || return 1

    DROPBEAR_PORT="${new_port}"
    _write_dropbear_default
    _write_dropbear_systemd

    systemctl daemon-reload
    systemctl restart dropbear

    log_ok "Dropbear port changed to: ${new_port}"
}

# ---------------------------------------------------------------------------
# Show Dropbear status
# ---------------------------------------------------------------------------
dropbear_status() {
    local status
    status="$(service_status dropbear)"
    local port="${DROPBEAR_PORT}"

    print_key_value "  Dropbear Status" "${status}"
    print_key_value "  Dropbear Port" "${port}"
}
