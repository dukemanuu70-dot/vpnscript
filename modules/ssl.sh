#!/usr/bin/env bash
# =============================================================================
# modules/ssl.sh - Let's Encrypt SSL certificate management
# =============================================================================

SSL_CONFIG="/etc/vpn-manager/ssl.conf"
VPN_CONFIG="/etc/vpn-manager/vpn.conf"
CERTBOT_WEBROOT="/var/www/certbot"
CERTBOT_HOOKS_DIR="/etc/letsencrypt/renewal-hooks"

# ---------------------------------------------------------------------------
# Setup SSL (interactive domain entry)
# ---------------------------------------------------------------------------
module_setup_ssl() {
    log_info "Setting up SSL certificates..."

    # Read domain from config if already set
    local domain
    domain="$(get_config_value "${VPN_CONFIG}" "DOMAIN" 2>/dev/null || echo '')"

    if [[ -z "${domain}" ]]; then
        if is_interactive; then
            domain="$(prompt_required "Enter your domain name (e.g. vpn.example.com)")"
        else
            log_warn "No domain configured. SSL setup skipped. Run from menu to configure."
            return 0
        fi
    fi

    ssl_setup_domain "${domain}"
}

# ---------------------------------------------------------------------------
# Setup SSL for a domain
# ---------------------------------------------------------------------------
ssl_setup_domain() {
    local domain="$1"
    local email="${2:-}"

    validate_domain "${domain}" || return 1

    # Verify DNS
    log_info "Verifying DNS for ${domain}..."
    if ! verify_dns "${domain}" "${SERVER_IPV4:-}"; then
        log_warn "DNS verification failed. Certificate may fail."
        if is_interactive; then
            if ! confirm_action "Continue anyway?"; then
                log_info "SSL setup cancelled."
                return 0
            fi
        fi
    fi

    # Get email
    if [[ -z "${email}" ]]; then
        if is_interactive; then
            email="$(prompt_with_default "Email for SSL notifications" "admin@${domain}")"
        else
            email="admin@${domain}"
        fi
    fi

    # Stop nginx temporarily for standalone cert
    log_info "Obtaining Let's Encrypt certificate for ${domain}..."

    mkdir -p "${CERTBOT_WEBROOT}"
    mkdir -p "${CERTBOT_HOOKS_DIR}/post"

    # Ensure certbot is installed (may have been skipped if package name changed)
    if ! command -v certbot &>/dev/null; then
        log_info "Certbot not found. Installing via snap (fallback)..."
        if command -v snap &>/dev/null; then
            snap install --classic certbot 2>/dev/null && \
                ln -sf /snap/bin/certbot /usr/local/bin/certbot 2>/dev/null || true
        fi
        if ! command -v certbot &>/dev/null; then
            log_error "Cannot install certbot. Please install manually and re-run SSL setup."
            return 1
        fi
    fi

    # Try webroot method first (nginx must be running and serving /.well-known)
    local cert_obtained=0

    # Prepare nginx for ACME challenge
    _nginx_prepare_webroot "${domain}"

    if certbot certonly \
        --webroot \
        --webroot-path "${CERTBOT_WEBROOT}" \
        --email "${email}" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        -d "${domain}" \
        2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        cert_obtained=1
        log_ok "Certificate obtained via webroot for ${domain}"
    else
        log_warn "Webroot method failed. Trying standalone..."
        systemctl stop nginx 2>/dev/null || true

        if certbot certonly \
            --standalone \
            --email "${email}" \
            --agree-tos \
            --no-eff-email \
            --non-interactive \
            -d "${domain}" \
            2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
            cert_obtained=1
            log_ok "Certificate obtained via standalone for ${domain}"
        fi

        systemctl start nginx 2>/dev/null || true
    fi

    if [[ "${cert_obtained}" -eq 0 ]]; then
        log_error "Failed to obtain SSL certificate for ${domain}"
        return 1
    fi

    # Save domain config
    mkdir -p /etc/vpn-manager
    set_config_value "${VPN_CONFIG}" "DOMAIN" "${domain}"
    set_config_value "${VPN_CONFIG}" "SSL_EMAIL" "${email}"
    set_config_value "${VPN_CONFIG}" "SSL_OBTAINED" "$(date +%Y-%m-%d)"

    # Configure auto-renewal hooks
    _configure_renewal_hooks "${domain}"

    # Configure nginx with SSL
    if declare -f nginx_configure_domain &>/dev/null; then
        nginx_configure_domain "${domain}"
    fi

    # Update Xray config with new domain/certs
    if declare -f xray_rebuild_config &>/dev/null; then
        xray_rebuild_config
    fi

    # Update Hysteria2 config
    if declare -f _write_hysteria2_config &>/dev/null; then
        _write_hysteria2_config
        systemctl restart hysteria-server 2>/dev/null || true
    fi

    log_ok "SSL setup complete for ${domain}"
    log_activity "SSL_SETUP" "${domain}"
}

# ---------------------------------------------------------------------------
# Prepare nginx for webroot validation
# ---------------------------------------------------------------------------
_nginx_prepare_webroot() {
    local domain="$1"
    local acme_conf="/etc/nginx/sites-available/acme-challenge"

    cat > "${acme_conf}" <<EOF
server {
    listen 80;
    server_name ${domain};
    root ${CERTBOT_WEBROOT};

    location /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
        allow all;
    }

    location / {
        return 200 'OK';
    }
}
EOF
    ln -sf "${acme_conf}" /etc/nginx/sites-enabled/acme-challenge
    nginx -t && systemctl reload nginx 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Configure renewal hooks
# ---------------------------------------------------------------------------
_configure_renewal_hooks() {
    local domain="$1"

    # Post-renewal hook to reload services
    cat > "${CERTBOT_HOOKS_DIR}/post/vpn-manager.sh" <<'EOF'
#!/usr/bin/env bash
# Reload services after certificate renewal
systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
systemctl restart xray 2>/dev/null || true
systemctl restart hysteria-server 2>/dev/null || true
echo "[$(date)] Certificate renewed and services reloaded" >> /var/log/vpn-manager/ssl.log
EOF
    chmod 755 "${CERTBOT_HOOKS_DIR}/post/vpn-manager.sh"

    # Setup certbot systemd timer (if not already)
    if systemctl list-units --type=timer | grep -q "certbot"; then
        log_ok "Certbot timer already active"
    else
        # Setup cron for renewal
        local cron_job="0 2,14 * * * root certbot renew --quiet --post-hook '${CERTBOT_HOOKS_DIR}/post/vpn-manager.sh' >> /var/log/vpn-manager/ssl.log 2>&1"
        if ! grep -q "certbot renew" /etc/cron.d/vpn-manager 2>/dev/null; then
            echo "${cron_job}" >> /etc/cron.d/vpn-manager
            chmod 644 /etc/cron.d/vpn-manager
        fi
    fi

    log_ok "Certificate auto-renewal configured"
}

# ---------------------------------------------------------------------------
# Renew certificate manually
# ---------------------------------------------------------------------------
ssl_renew() {
    local domain="${1:-}"

    log_info "Renewing SSL certificates..."

    local force_flag=""
    [[ -n "${domain}" ]] && force_flag="--cert-name ${domain}"

    if certbot renew ${force_flag} --quiet 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        # Run post-renewal hooks
        bash "${CERTBOT_HOOKS_DIR}/post/vpn-manager.sh" 2>/dev/null || true
        log_ok "Certificates renewed"
    else
        log_warn "Certificate renewal had issues. Check: certbot renew --dry-run"
    fi

    log_activity "SSL_RENEW" "${domain:-all}"
}

# ---------------------------------------------------------------------------
# Show certificate status
# ---------------------------------------------------------------------------
ssl_status() {
    echo ""
    print_header "SSL Certificate Status"
    echo ""

    if ! command -v certbot &>/dev/null; then
        log_warn "Certbot not installed"
        return
    fi

    certbot certificates 2>/dev/null | while IFS= read -r line; do
        if [[ "${line}" =~ "Expiry Date" ]]; then
            local expiry_str
            expiry_str="$(echo "${line}" | grep -oP '\d{4}-\d{2}-\d{2}')"
            if [[ -n "${expiry_str}" ]]; then
                local today_ts expiry_ts days_left
                today_ts="$(date +%s)"
                expiry_ts="$(date -d "${expiry_str}" +%s 2>/dev/null || echo 0)"
                days_left=$(( (expiry_ts - today_ts) / 86400 ))
                if [[ "${days_left}" -le 14 ]]; then
                    echo -e "  ${RED}${line} (${days_left} days left - RENEW SOON)${RESET}"
                else
                    echo -e "  ${GREEN}${line} (${days_left} days left)${RESET}"
                fi
                continue
            fi
        fi
        echo "  ${line}"
    done
    echo ""
}

# ---------------------------------------------------------------------------
# Change domain
# ---------------------------------------------------------------------------
ssl_change_domain() {
    local new_domain="$1"

    validate_domain "${new_domain}" || return 1

    log_info "Changing domain to: ${new_domain}"

    # Remove old nginx config
    local old_domain
    old_domain="$(get_config_value "${VPN_CONFIG}" "DOMAIN" 2>/dev/null || echo '')"
    if [[ -n "${old_domain}" ]]; then
        rm -f "/etc/nginx/sites-enabled/${old_domain}.conf"
        rm -f "/etc/nginx/sites-available/${old_domain}.conf"
    fi

    # Setup new domain
    ssl_setup_domain "${new_domain}"
}

# ---------------------------------------------------------------------------
# Add additional domain
# ---------------------------------------------------------------------------
ssl_add_domain() {
    local domain="$1"
    ssl_setup_domain "${domain}"
}
