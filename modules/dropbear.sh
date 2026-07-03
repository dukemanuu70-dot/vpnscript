#!/usr/bin/env bash
# =============================================================================
# modules/dropbear.sh - Dropbear SSH server (multi-port for HTTP Injector)
# =============================================================================
# Port layout:
#   127.0.0.1:2083  — internal only (reserved for future Nginx stream proxy)
#   0.0.0.0:444     — direct SSH
#   0.0.0.0:8080    — HTTP-alt  (primary HTTP Injector / HTTP Custom port)
#   0.0.0.0:8880    — HTTP-alt2
#   0.0.0.0:2052    — Cloudflare-compatible
#   0.0.0.0:2095    — Cloudflare-compatible
# =============================================================================

DROPBEAR_SYSTEMD="/etc/systemd/system/dropbear.service"
DROPBEAR_PUBLIC_PORTS=(444 8080 8880 2052 2095)
DROPBEAR_INTERNAL_PORT=2083

# ---------------------------------------------------------------------------
# Install Dropbear
# ---------------------------------------------------------------------------
module_install_dropbear() {
    log_info "Installing Dropbear..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dropbear 2>&1 | \
        tee -a "${INSTALL_LOG:-/dev/null}"

    # Ensure host keys exist
    if [[ ! -f /etc/dropbear/dropbear_ed25519_host_key ]]; then
        mkdir -p /etc/dropbear
        dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null || true
        dropbearkey -t ecdsa  -f /etc/dropbear/dropbear_ecdsa_host_key  2>/dev/null || true
        dropbearkey -t rsa    -f /etc/dropbear/dropbear_rsa_host_key -s 4096 2>/dev/null || true
        log_ok "Dropbear host keys generated"
    fi

    _write_dropbear_systemd

    # Open public ports in UFW
    for port in "${DROPBEAR_PUBLIC_PORTS[@]}"; do
        ufw allow "${port}/tcp" comment "Dropbear" 2>/dev/null || true
    done

    systemctl daemon-reload
    systemctl enable dropbear
    systemctl restart dropbear

    if systemctl is-active --quiet dropbear; then
        log_ok "Dropbear running on ports: ${DROPBEAR_PUBLIC_PORTS[*]}"
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
# Write systemd unit — listens on internal + all public ports
# ---------------------------------------------------------------------------
_write_dropbear_systemd() {
    cat > "${DROPBEAR_SYSTEMD}" <<'EOF'
[Unit]
Description=Dropbear SSH Daemon (Multi-Port)
Documentation=man:dropbear(8)
After=network.target

[Service]
ExecStartPre=/bin/mkdir -p /run/dropbear
ExecStart=/usr/sbin/dropbear -F -E \
  -p 127.0.0.1:2083 \
  -p 0.0.0.0:444 \
  -p 0.0.0.0:8080 \
  -p 0.0.0.0:8880 \
  -p 0.0.0.0:2052 \
  -p 0.0.0.0:2095 \
  -w \
  -s \
  -r /etc/dropbear/dropbear_ecdsa_host_key \
  -r /etc/dropbear/dropbear_ed25519_host_key \
  -r /etc/dropbear/dropbear_rsa_host_key
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=always
RestartSec=5s
Type=simple

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${DROPBEAR_SYSTEMD}"
    log_ok "Dropbear systemd unit written"
}

# ---------------------------------------------------------------------------
# Show Dropbear status
# ---------------------------------------------------------------------------
dropbear_status() {
    echo ""
    print_header "Dropbear Status"
    echo ""
    print_key_value "  Status" "$(service_status dropbear)"
    print_key_value "  Public Ports" "${DROPBEAR_PUBLIC_PORTS[*]}"
    print_key_value "  Internal Port" "${DROPBEAR_INTERNAL_PORT} (localhost only)"
    echo ""
    ss -tlnp 2>/dev/null | grep dropbear | awk '{print "  Listening: "$4}' || true
    echo ""
}

# ---------------------------------------------------------------------------
# Add/change a public port
# ---------------------------------------------------------------------------
dropbear_add_port() {
    local new_port="$1"
    validate_port "${new_port}" || return 1

    # Add to systemd unit
    sed -i "/ExecStart=/a\\  -p 0.0.0.0:${new_port} \\\\" "${DROPBEAR_SYSTEMD}" 2>/dev/null || true
    ufw allow "${new_port}/tcp" comment "Dropbear" 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart dropbear
    log_ok "Dropbear port added: ${new_port}"
}
