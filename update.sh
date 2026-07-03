#!/usr/bin/env bash
# =============================================================================
# update.sh - VPN Manager update script
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "VPN Manager Update Script"
echo "========================="
echo ""

# Root check
if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Source libraries
# shellcheck source=lib/colors.sh
source "${SCRIPT_DIR}/lib/colors.sh"
# shellcheck source=lib/logger.sh
source "${SCRIPT_DIR}/lib/logger.sh"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/lib/utils.sh"

LOG_FILE="/var/log/vpn-manager/update_$(date +%Y%m%d_%H%M%S).log"

# ---------------------------------------------------------------------------
# Update system packages
# ---------------------------------------------------------------------------
update_system() {
    log_info "Updating system packages..."
    apt-get update -qq && apt-get upgrade -y -qq 2>&1 | tee -a "${LOG_FILE}" || true
    log_ok "System packages updated"
}

# ---------------------------------------------------------------------------
# Update Xray-core
# ---------------------------------------------------------------------------
update_xray() {
    if [[ -f "${SCRIPT_DIR}/modules/xray.sh" ]]; then
        # shellcheck source=modules/xray.sh
        source "${SCRIPT_DIR}/modules/xray.sh"
        xray_update
    else
        log_warn "Xray module not found, skipping"
    fi
}

# ---------------------------------------------------------------------------
# Update panel (git pull if in git repo)
# ---------------------------------------------------------------------------
update_panel() {
    log_info "Checking for VPN Manager updates..."

    if [[ -d "${SCRIPT_DIR}/.git" ]]; then
        cd "${SCRIPT_DIR}"
        local current_branch
        current_branch="$(git branch --show-current 2>/dev/null || echo 'main')"
        log_info "Git repository detected, branch: ${current_branch}"

        # Stash local changes
        git stash save "Auto-stash before update $(date)" 2>/dev/null || true

        # Pull updates
        if git pull origin "${current_branch}" 2>&1 | tee -a "${LOG_FILE}"; then
            log_ok "VPN Manager updated from git"
        else
            log_warn "Git pull failed or no updates available"
        fi

        # Re-apply stashed changes
        git stash pop 2>/dev/null || true
    else
        log_info "Not a git repository. Manual update required."
        log_info "Download latest version from: https://github.com/yourrepo/vpn-manager"
    fi
}

# ---------------------------------------------------------------------------
# Restart services after update
# ---------------------------------------------------------------------------
restart_services() {
    log_info "Restarting services..."
    local services=("nginx" "xray" "fail2ban")

    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "${svc}"; then
            systemctl restart "${svc}" 2>/dev/null && \
                log_ok "Restarted: ${svc}" || \
                log_warn "Could not restart: ${svc}"
        fi
    done
}

# ---------------------------------------------------------------------------
# Main update flow
# ---------------------------------------------------------------------------
main() {
    log_section "VPN Manager Update"

    update_system
    update_xray
    update_panel
    restart_services

    log_ok "Update complete!"
    log_activity "UPDATE" "completed"
}

main "$@"
