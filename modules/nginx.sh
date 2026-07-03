#!/usr/bin/env bash
# =============================================================================
# modules/nginx.sh - Nginx installation and configuration
# =============================================================================

NGINX_CONF_DIR="/etc/nginx"
NGINX_SITES_AVAILABLE="${NGINX_CONF_DIR}/sites-available"
NGINX_SITES_ENABLED="${NGINX_CONF_DIR}/sites-enabled"
NGINX_MAIN_CONF="${NGINX_CONF_DIR}/nginx.conf"
NGINX_VPN_CONF="${NGINX_SITES_AVAILABLE}/vpn-manager"
VPN_CONFIG_FILE="/etc/vpn-manager/vpn.conf"

# ---------------------------------------------------------------------------
# Install Nginx
# ---------------------------------------------------------------------------
module_install_nginx() {
    log_info "Installing Nginx..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx 2>&1 | \
        tee -a "${INSTALL_LOG:-/dev/null}"

    # Remove default site
    rm -f "${NGINX_SITES_ENABLED}/default"

    _write_nginx_main_conf
    _write_nginx_security_headers
    _write_nginx_placeholder_site

    # Install systemd override
    local override_dir="/etc/systemd/system/nginx.service.d"
    mkdir -p "${override_dir}"
    cat > "${override_dir}/override.conf" <<EOF
[Service]
Restart=always
RestartSec=5s
EOF

    systemctl daemon-reload
    systemctl enable nginx
    systemctl restart nginx

    if systemctl is-active --quiet nginx; then
        log_ok "Nginx installed and running"
    else
        log_error "Nginx failed to start. Check: journalctl -u nginx"
        nginx -t 2>&1 | tee -a "${INSTALL_LOG:-/dev/null}"
        return 1
    fi
}

module_remove_nginx() {
    systemctl stop nginx 2>/dev/null || true
    log_info "Nginx stopped (rollback)"
}

# ---------------------------------------------------------------------------
# Main nginx.conf
# ---------------------------------------------------------------------------
_write_nginx_main_conf() {
    backup_file "${NGINX_MAIN_CONF}"

    cat > "${NGINX_MAIN_CONF}" <<'EOF'
# Nginx Main Configuration - Managed by VPN Manager
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    # Basic settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 16m;
    client_body_timeout 30;
    client_header_timeout 30;
    send_timeout 30;

    # MIME types
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main buffer=16k;
    error_log /var/log/nginx/error.log warn;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript
               application/xml+rss application/atom+xml image/svg+xml;

    # Rate limiting zones
    limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
    limit_req_zone $binary_remote_addr zone=api:10m rate=30r/m;
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    # SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 1.1.1.1 valid=300s;
    resolver_timeout 5s;

    # Include site configs
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
}

# ---------------------------------------------------------------------------
# Security headers snippet
# ---------------------------------------------------------------------------
_write_nginx_security_headers() {
    local snippet_file="${NGINX_CONF_DIR}/snippets/security-headers.conf"
    mkdir -p "${NGINX_CONF_DIR}/snippets"

    cat > "${snippet_file}" <<'EOF'
# Security headers snippet
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "no-referrer-when-downgrade" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
EOF
}

# ---------------------------------------------------------------------------
# Placeholder HTTP site (before SSL)
# ---------------------------------------------------------------------------
_write_nginx_placeholder_site() {
    cat > "${NGINX_VPN_CONF}" <<EOF
# VPN Manager - Placeholder (HTTP only, before SSL setup)
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/html;
    index index.html;

    location / {
        return 200 'VPN Manager - Configuring...';
        add_header Content-Type text/plain;
    }
}
EOF
    ln -sf "${NGINX_VPN_CONF}" "${NGINX_SITES_ENABLED}/vpn-manager"
    nginx -t && systemctl reload nginx 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Configure Nginx for a domain with SSL and Xray proxy
# ---------------------------------------------------------------------------
nginx_configure_domain() {
    local domain="$1"
    local xray_ws_port="${2:-10000}"
    local xray_grpc_port="${3:-10001}"
    local cert_path="/etc/letsencrypt/live/${domain}"

    if [[ ! -d "${cert_path}" ]]; then
        log_error "SSL certificate not found for ${domain}. Run ssl setup first."
        return 1
    fi

    local site_conf="${NGINX_SITES_AVAILABLE}/${domain}.conf"

    cat > "${site_conf}" <<EOF
# Nginx config for ${domain} - Managed by VPN Manager
# Generated: $(date)

# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};

    # SSL certificates
    ssl_certificate ${cert_path}/fullchain.pem;
    ssl_certificate_key ${cert_path}/privkey.pem;
    ssl_trusted_certificate ${cert_path}/chain.pem;

    # Include security headers
    include ${NGINX_CONF_DIR}/snippets/security-headers.conf;

    # Logging
    access_log /var/log/nginx/${domain}-access.log main;
    error_log /var/log/nginx/${domain}-error.log warn;

    # Root fallback
    root /var/www/html;
    index index.html;

    # WebSocket proxy for Xray (VLESS/VMess over WS)
    location /ws {
        if (\$http_upgrade != "websocket") {
            return 404;
        }
        proxy_pass http://127.0.0.1:${xray_ws_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_connect_timeout 60;
    }

    # gRPC proxy for Xray
    location /grpc {
        grpc_pass grpc://127.0.0.1:${xray_grpc_port};
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header Host \$http_host;
        grpc_read_timeout 86400s;
        grpc_send_timeout 86400s;
        grpc_connect_timeout 60s;
    }

    # Health check
    location /health {
        access_log off;
        return 200 'OK';
        add_header Content-Type text/plain;
    }

    # Default
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    # Enable site
    ln -sf "${site_conf}" "${NGINX_SITES_ENABLED}/${domain}.conf"

    if nginx -t 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        systemctl reload nginx
        log_ok "Nginx configured for domain: ${domain}"
        return 0
    else
        log_error "Nginx config test failed for ${domain}"
        rm -f "${NGINX_SITES_ENABLED}/${domain}.conf"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Remove domain from Nginx
# ---------------------------------------------------------------------------
nginx_remove_domain() {
    local domain="$1"

    rm -f "${NGINX_SITES_ENABLED}/${domain}.conf"
    rm -f "${NGINX_SITES_AVAILABLE}/${domain}.conf"

    nginx -t && systemctl reload nginx 2>/dev/null || true
    log_ok "Nginx domain removed: ${domain}"
}

# ---------------------------------------------------------------------------
# List configured domains
# ---------------------------------------------------------------------------
nginx_list_domains() {
    echo ""
    print_header "Configured Domains"
    echo ""
    for conf in "${NGINX_SITES_ENABLED}"/*.conf; do
        [[ -f "${conf}" ]] || continue
        local domain
        domain="$(basename "${conf}" .conf)"
        local status="${GREEN}active${RESET}"
        nginx -t 2>/dev/null && status="${GREEN}active${RESET}" || status="${RED}error${RESET}"
        echo -e "  • ${domain} - ${status}"
    done
    echo ""
}

# ---------------------------------------------------------------------------
# Test Nginx configuration
# ---------------------------------------------------------------------------
nginx_test_config() {
    if nginx -t 2>&1; then
        log_ok "Nginx configuration test passed"
        return 0
    else
        log_error "Nginx configuration test failed"
        return 1
    fi
}
