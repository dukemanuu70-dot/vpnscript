#!/usr/bin/env bash
# =============================================================================
# uninstall.sh - VPN Manager complete uninstaller
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Source colors if available
if [[ -f "${SCRIPT_DIR}/lib/colors.sh" ]]; then
    source "${SCRIPT_DIR}/lib/colors.sh"
fi

echo ""
echo -e "${RED:-}WARNING: This will remove VPN Manager and all its configurations.${RESET:-}"
echo -e "${RED:-}USER ACCOUNTS WILL BE DELETED.${RESET:-}"
echo ""
read -rp "Type 'UNINSTALL' to confirm: " confirm
if [[ "${confirm}" != "UNINSTALL" ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo "Starting uninstall..."

# ---------------------------------------------------------------------------
# Remove SSH VPN users
# ---------------------------------------------------------------------------
remove_vpn_users() {
    echo "Removing VPN users..."
    if [[ -d /etc/vpn-manager/users ]]; then
        for conf in /etc/vpn-manager/users/*.conf; do
            [[ -f "${conf}" ]] || continue
            local username type
            username="$(grep '^USERNAME=' "${conf}" | cut -d= -f2)"
            type="$(grep '^TYPE=' "${conf}" | cut -d= -f2)"

            if [[ "${type}" == "ssh" ]] && id "${username}" &>/dev/null 2>&1; then
                userdel -r "${username}" 2>/dev/null || userdel "${username}" 2>/dev/null || true
                echo "  Removed user: ${username}"
            fi
        done
    fi
}

# ---------------------------------------------------------------------------
# Stop and disable services
# ---------------------------------------------------------------------------
stop_services() {
    echo "Stopping services..."
    local services=(
        "xray"
        "hysteria-server"
        "wg-quick@wg0"
        "dropbear"
        "fail2ban"
        "nginx"
    )

    for svc in "${services[@]}"; do
        systemctl stop "${svc}" 2>/dev/null || true
        systemctl disable "${svc}" 2>/dev/null || true
        echo "  Stopped: ${svc}"
    done
}

# ---------------------------------------------------------------------------
# Remove packages
# ---------------------------------------------------------------------------
remove_packages() {
    echo "Removing installed packages..."
    local packages=(
        "dropbear"
        "fail2ban"
        "certbot"
        "python3-certbot-nginx"
        "vnstat"
        "wireguard"
        "wireguard-tools"
    )

    DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "${packages[@]}" 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Remove config files
# ---------------------------------------------------------------------------
remove_configs() {
    echo "Removing configuration files..."

    local dirs=(
        "/etc/vpn-manager"
        "/usr/local/etc/xray"
        "/etc/wireguard"
        "/etc/hysteria"
        "/var/lib/vpn-manager"
    )

    for dir in "${dirs[@]}"; do
        [[ -d "${dir}" ]] && rm -rf "${dir}" && echo "  Removed: ${dir}"
    done

    # Remove binaries
    rm -f /usr/local/bin/xray
    rm -f /usr/local/bin/hysteria
    rm -f /usr/local/bin/vpn-manager-cron

    # Remove systemd units
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/hysteria-server.service
    rm -f /etc/systemd/system/dropbear.service
    rm -rf /etc/systemd/system/ssh.service.d
    rm -rf /etc/systemd/system/sshd.service.d
    rm -rf /etc/systemd/system/nginx.service.d
    rm -rf /etc/systemd/system/fail2ban.service.d

    # Remove cron jobs
    rm -f /etc/cron.d/vpn-manager

    # Remove security limits
    rm -f /etc/security/limits.d/vpn-*.conf

    # Restore sshd_config backup
    local latest_backup
    latest_backup="$(ls -t /etc/vpn-manager/backups/sshd_config.*.bak 2>/dev/null | head -1 || echo '')"
    if [[ -n "${latest_backup}" && -f "${latest_backup}" ]]; then
        cp "${latest_backup}" /etc/ssh/sshd_config
        echo "  Restored: /etc/ssh/sshd_config"
    fi

    # Remove nginx vpn configs
    rm -f /etc/nginx/sites-enabled/vpn-manager
    rm -f /etc/nginx/sites-available/vpn-manager
    rm -f /etc/nginx/sites-enabled/acme-challenge
    rm -f /etc/nginx/sites-available/acme-challenge

    # Remove sysctl settings
    rm -f /etc/sysctl.d/99-vpn-manager.conf
    rm -f /etc/sysctl.d/98-bbr.conf

    systemctl daemon-reload
    sysctl -p 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Remove logs (optional)
# ---------------------------------------------------------------------------
remove_logs() {
    read -rp "Remove log files? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
        rm -rf /var/log/vpn-manager
        echo "  Logs removed"
    else
        echo "  Logs kept at /var/log/vpn-manager"
    fi
}

# ---------------------------------------------------------------------------
# Restore SSH
# ---------------------------------------------------------------------------
restore_ssh() {
    echo "Restarting SSH..."
    systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    echo "  SSH restarted"
}

# ---------------------------------------------------------------------------
# UFW reset
# ---------------------------------------------------------------------------
reset_firewall() {
    read -rp "Reset UFW firewall rules? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
        ufw --force reset 2>/dev/null || true
        ufw allow ssh
        ufw --force enable
        echo "  UFW reset with SSH allowed"
    fi
}

# ---------------------------------------------------------------------------
# Main uninstall
# ---------------------------------------------------------------------------
remove_vpn_users
stop_services
remove_packages
remove_configs
restore_ssh
reset_firewall
remove_logs

echo ""
echo "VPN Manager has been uninstalled."
echo "You may want to remove the vpn-manager directory manually:"
echo "  rm -rf ${SCRIPT_DIR}"
echo ""
