#!/usr/bin/env bash
# =============================================================================
# modules/backup.sh - Backup and restore functionality
# =============================================================================

BACKUP_BASE_DIR="/var/lib/vpn-manager/backups"
BACKUP_LATEST_LINK="${BACKUP_BASE_DIR}/latest"
BACKUP_MAX_COUNT="${BACKUP_MAX_COUNT:-10}"

# ---------------------------------------------------------------------------
# Setup backup system
# ---------------------------------------------------------------------------
module_configure_backup() {
    log_info "Setting up backup system..."

    mkdir -p "${BACKUP_BASE_DIR}"
    chmod 700 "${BACKUP_BASE_DIR}"

    # Write backup cron (weekly full backup)
    local cron_file="/etc/cron.d/vpn-manager"
    if [[ -f "${cron_file}" ]]; then
        if ! grep -q "backup" "${cron_file}"; then
            echo "0 3 * * 0 root /opt/vpn-manager/backup.sh auto >> /var/log/vpn-manager/backup.log 2>&1" \
                >> "${cron_file}"
        fi
    fi

    log_ok "Backup system configured"
}

# ---------------------------------------------------------------------------
# Create full backup
# ---------------------------------------------------------------------------
backup_create() {
    local label="${1:-manual}"
    local backup_name="backup_${label}_$(date +%Y%m%d_%H%M%S)"
    local backup_dir="${BACKUP_BASE_DIR}/${backup_name}"
    local backup_archive="${BACKUP_BASE_DIR}/${backup_name}.tar.gz"

    log_info "Creating backup: ${backup_name}"
    mkdir -p "${backup_dir}"

    # List of items to back up
    local backup_items=(
        "/etc/vpn-manager"
        "/etc/ssh/sshd_config"
        "/etc/default/dropbear"
        "/etc/nginx/sites-available"
        "/etc/nginx/nginx.conf"
        "/usr/local/etc/xray"
        "/etc/wireguard"
        "/etc/hysteria"
        "/etc/fail2ban/jail.local"
        "/etc/ufw"
        "/etc/sysctl.d/99-vpn-manager.conf"
        "/etc/security/limits.d"
        "/etc/letsencrypt/renewal"
    )

    local backed_up=0
    local failed=0

    for item in "${backup_items[@]}"; do
        if [[ -e "${item}" ]]; then
            local dest_dir="${backup_dir}$(dirname "${item}")"
            mkdir -p "${dest_dir}"
            if cp -rp "${item}" "${dest_dir}/"; then
                (( backed_up++ ))
                log_info "  Backed up: ${item}"
            else
                log_warn "  Failed to backup: ${item}"
                (( failed++ ))
            fi
        fi
    done

    # Save backup metadata
    cat > "${backup_dir}/backup_info.txt" <<EOF
Backup Name: ${backup_name}
Created: $(date)
Label: ${label}
OS: ${OS_ID:-unknown} ${OS_VERSION:-}
Items Backed Up: ${backed_up}
Items Failed: ${failed}
EOF

    # Create archive
    if tar -czf "${backup_archive}" -C "${BACKUP_BASE_DIR}" "${backup_name}" 2>/dev/null; then
        rm -rf "${backup_dir}"
        ln -sf "${backup_archive}" "${BACKUP_LATEST_LINK}.tar.gz"
        local size
        size="$(du -sh "${backup_archive}" | cut -f1)"
        log_ok "Backup created: ${backup_archive} (${size})"
        log_activity "BACKUP_CREATE" "${backup_name}"

        # Rotate old backups
        _rotate_backups

        echo "${backup_archive}"
        return 0
    else
        log_error "Failed to create backup archive"
        rm -rf "${backup_dir}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Rotate old backups
# ---------------------------------------------------------------------------
_rotate_backups() {
    local count
    count="$(find "${BACKUP_BASE_DIR}" -name "*.tar.gz" | wc -l)"

    if [[ "${count}" -gt "${BACKUP_MAX_COUNT}" ]]; then
        local to_delete
        to_delete=$(( count - BACKUP_MAX_COUNT ))
        log_info "Rotating ${to_delete} old backup(s)..."
        find "${BACKUP_BASE_DIR}" -name "*.tar.gz" -printf "%T+ %p\n" | \
            sort | head -"${to_delete}" | awk '{print $2}' | xargs -r rm -f
    fi
}

# ---------------------------------------------------------------------------
# List backups
# ---------------------------------------------------------------------------
backup_list() {
    echo ""
    print_header "Available Backups"
    echo ""

    local count=0
    while IFS= read -r backup; do
        local name size date
        name="$(basename "${backup}" .tar.gz)"
        size="$(du -sh "${backup}" 2>/dev/null | cut -f1)"
        date="$(stat -c '%y' "${backup}" 2>/dev/null | cut -d. -f1)"
        printf "  ${CYAN}[%3d]${RESET} %-45s ${WHITE}%6s${RESET}  %s\n" \
            "$(( ++count ))" "${name}" "${size}" "${date}"
    done < <(find "${BACKUP_BASE_DIR}" -name "*.tar.gz" -printf "%T@ %p\n" | sort -rn | awk '{print $2}')

    if [[ "${count}" -eq 0 ]]; then
        log_warn "No backups found in ${BACKUP_BASE_DIR}"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Restore from backup
# ---------------------------------------------------------------------------
backup_restore() {
    local backup_file="$1"

    if [[ -z "${backup_file}" ]]; then
        # Interactive selection
        backup_list
        read -rp "$(echo -e "${CYAN}  Enter backup name or full path: ${RESET}")" backup_file

        # If just name provided, look in backup dir
        if [[ ! -f "${backup_file}" ]]; then
            backup_file="${BACKUP_BASE_DIR}/${backup_file}.tar.gz"
        fi
    fi

    if [[ ! -f "${backup_file}" ]]; then
        log_error "Backup file not found: ${backup_file}"
        return 1
    fi

    log_warn "RESTORE will overwrite current configuration!"
    if is_interactive && ! confirm_action "Proceed with restore from $(basename "${backup_file}")?"; then
        log_info "Restore cancelled."
        return 0
    fi

    log_info "Restoring from: ${backup_file}"

    # Extract to temp dir first
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    if ! tar -xzf "${backup_file}" -C "${tmp_dir}" 2>/dev/null; then
        log_error "Failed to extract backup archive"
        rm -rf "${tmp_dir}"
        return 1
    fi

    # Find the extracted backup directory
    local extracted_dir
    extracted_dir="$(find "${tmp_dir}" -maxdepth 1 -type d | tail -1)"

    if [[ ! -d "${extracted_dir}" ]]; then
        log_error "Could not find extracted backup directory"
        rm -rf "${tmp_dir}"
        return 1
    fi

    # Stop services before restore
    local services=("nginx" "xray" "ssh" "dropbear" "fail2ban")
    for svc in "${services[@]}"; do
        systemctl stop "${svc}" 2>/dev/null || true
    done

    # Restore files
    local restored=0
    for item in "${extracted_dir}"/*/*; do
        local rel_path="${item#"${extracted_dir}"}"
        local dest_dir
        dest_dir="$(dirname "${rel_path}")"
        mkdir -p "${dest_dir}"
        if cp -rp "${item}" "${dest_dir}/"; then
            (( restored++ ))
        fi
    done

    # Restart services
    for svc in "${services[@]}"; do
        systemctl start "${svc}" 2>/dev/null || true
    done

    rm -rf "${tmp_dir}"

    log_ok "Restore complete: ${restored} items restored"
    log_activity "BACKUP_RESTORE" "$(basename "${backup_file}")"
}

# ---------------------------------------------------------------------------
# Download backup (display path for manual transfer)
# ---------------------------------------------------------------------------
backup_download_info() {
    local backup_file="${1:-}"
    if [[ -z "${backup_file}" ]]; then
        backup_file="$(ls -t "${BACKUP_BASE_DIR}"/*.tar.gz 2>/dev/null | head -1)"
    fi

    if [[ -z "${backup_file}" ]]; then
        log_warn "No backup found"
        return 1
    fi

    echo ""
    print_header "Download Backup"
    echo ""
    print_key_value "  File" "${backup_file}"
    print_key_value "  Size" "$(du -sh "${backup_file}" | cut -f1)"
    echo ""
    print_color "${CYAN}" "  Transfer with SCP:"
    echo "  scp root@${SERVER_IPV4:-SERVER}:${backup_file} ./"
    echo ""
    print_color "${CYAN}" "  Transfer with SFTP:"
    echo "  sftp root@${SERVER_IPV4:-SERVER}:${backup_file}"
    echo ""
}
