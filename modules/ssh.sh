#!/usr/bin/env bash
# =============================================================================
# modules/ssh.sh - OpenSSH installation, configuration, and user management
# =============================================================================

SSH_CONFIG="/etc/ssh/sshd_config"
SSH_USERS_DB="/etc/vpn-manager/users"
SSH_BANNER_FILE="/etc/vpn-manager/ssh_banner"
SSH_MOTD_FILE="/etc/motd"
SSHD_PORT="${SSHD_PORT:-22}"
DROPBEAR_PORT="${DROPBEAR_PORT:-444}"

# ---------------------------------------------------------------------------
# Install OpenSSH
# ---------------------------------------------------------------------------
module_install_openssh() {
    log_info "Installing OpenSSH server..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server 2>&1 | \
        tee -a "${INSTALL_LOG:-/dev/null}"

    # Backup original config
    backup_file "${SSH_CONFIG}"

    # Generate SSH keys if missing
    local key_types=("rsa" "ecdsa" "ed25519")
    for kt in "${key_types[@]}"; do
        local key_file="/etc/ssh/ssh_host_${kt}_key"
        if [[ ! -f "${key_file}" ]]; then
            ssh-keygen -t "${kt}" -f "${key_file}" -N "" -q
            log_ok "Generated SSH host key: ${kt}"
        fi
    done

    # Apply secure configuration
    _write_sshd_config

    # Install systemd unit override for automatic restart
    _install_ssh_systemd_override

    # Enable and start
    systemctl daemon-reload
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

    log_ok "OpenSSH installed and configured on port ${SSHD_PORT}"
}

module_remove_openssh() {
    log_info "Rolling back OpenSSH configuration..."
    local backup
    backup="$(ls -t /etc/vpn-manager/backups/sshd_config.*.bak 2>/dev/null | head -1)"
    if [[ -n "${backup}" ]]; then
        cp "${backup}" "${SSH_CONFIG}"
        systemctl restart ssh 2>/dev/null || true
        log_ok "OpenSSH config restored"
    fi
}

# ---------------------------------------------------------------------------
# Write hardened sshd_config
# ---------------------------------------------------------------------------
_write_sshd_config() {
    local port="${SSHD_PORT:-22}"
    local allow_password="${SSH_ALLOW_PASSWORD:-yes}"
    local allow_root="${SSH_ALLOW_ROOT:-no}"

    cat > "${SSH_CONFIG}" <<EOF
# =============================================================================
# OpenSSH Configuration - Managed by VPN Manager
# =============================================================================

Port ${port}
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# HostKeys
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_rsa_key

# Ciphers and keying
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256

# Authentication
LoginGraceTime 30
PermitRootLogin ${allow_root}
StrictModes yes
MaxAuthTries 4
MaxSessions 20
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication ${allow_password}
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Network
TCPKeepAlive yes
ClientAliveInterval 60
ClientAliveCountMax 3
AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no

# Logging
SyslogFacility AUTH
LogLevel INFO

# SFTP
Subsystem sftp /usr/lib/openssh/sftp-server

# Banner
Banner ${SSH_BANNER_FILE}

# Print last login
PrintLastLog yes
EOF

    chmod 600 "${SSH_CONFIG}"
    log_ok "sshd_config written"
}

# ---------------------------------------------------------------------------
# Systemd override for restart on failure
# ---------------------------------------------------------------------------
_install_ssh_systemd_override() {
    local override_dir="/etc/systemd/system/ssh.service.d"
    mkdir -p "${override_dir}"
    cat > "${override_dir}/override.conf" <<EOF
[Service]
Restart=always
RestartSec=5s
EOF
    # Also handle sshd.service name (Debian)
    local override_dir2="/etc/systemd/system/sshd.service.d"
    mkdir -p "${override_dir2}"
    cp "${override_dir}/override.conf" "${override_dir2}/override.conf"
    systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# Create SSH user
# ---------------------------------------------------------------------------
ssh_create_user() {
    local username="$1"
    local password="${2:-}"
    local days="${3:-30}"
    local max_logins="${4:-2}"
    local traffic_limit="${5:-0}"  # 0 = unlimited

    # Validate
    validate_username "${username}" || return 1

    if user_exists "${username}"; then
        log_error "User already exists: ${username}"
        return 1
    fi

    # Generate password if not provided
    if [[ -z "${password}" ]]; then
        password="$(generate_simple_password 12)"
    fi

    validate_password "${password}" || return 1

    local expiry_date
    expiry_date="$(days_from_now "${days}")"

    # Create system user
    useradd -M -s /bin/false \
        -e "${expiry_date}" \
        -c "VPN User" \
        "${username}"

    echo "${username}:${password}" | chpasswd

    # Store user metadata
    mkdir -p "${SSH_USERS_DB}"
    local user_conf="${SSH_USERS_DB}/${username}.conf"
    cat > "${user_conf}" <<EOF
# VPN Manager User Config
USERNAME=${username}
TYPE=ssh
CREATED=$(date +%Y-%m-%d)
EXPIRY=${expiry_date}
MAX_LOGINS=${max_logins}
TRAFFIC_LIMIT=${traffic_limit}
TRAFFIC_USED=0
STATUS=active
EOF
    chmod 600 "${user_conf}"

    # Apply connection limit via PAM (if configured)
    _apply_login_limit "${username}" "${max_logins}"

    log_activity "CREATE_SSH_USER" "${username}"
    log_ok "SSH user created: ${username} (expires: ${expiry_date})"

    # Output credentials
    echo ""
    print_color "${GREEN}" "  ┌─────────────────────────────────────┐"
    print_color "${GREEN}" "  │         SSH User Created             │"
    print_color "${GREEN}" "  ├─────────────────────────────────────┤"
    print_key_value "  Username" "${username}" "${CYAN}" "${WHITE}"
    print_key_value "  Password" "${password}" "${CYAN}" "${YELLOW}"
    print_key_value "  Expires" "${expiry_date}" "${CYAN}" "${WHITE}"
    print_key_value "  Max Logins" "${max_logins}" "${CYAN}" "${WHITE}"
    print_color "${GREEN}" "  └─────────────────────────────────────┘"
    echo ""
}

# ---------------------------------------------------------------------------
# Delete SSH user
# ---------------------------------------------------------------------------
ssh_delete_user() {
    local username="$1"

    if ! user_exists "${username}"; then
        log_error "User does not exist: ${username}"
        return 1
    fi

    if ! is_vpn_user "${username}"; then
        log_error "Cannot delete non-VPN user: ${username}"
        return 1
    fi

    # Disconnect active sessions
    ssh_disconnect_user "${username}" 2>/dev/null || true

    # Remove system user
    userdel -r "${username}" 2>/dev/null || userdel "${username}" 2>/dev/null || true

    # Remove user metadata
    rm -f "${SSH_USERS_DB}/${username}.conf"

    log_activity "DELETE_SSH_USER" "${username}"
    log_ok "SSH user deleted: ${username}"
}

# ---------------------------------------------------------------------------
# Lock/Unlock user
# ---------------------------------------------------------------------------
ssh_lock_user() {
    local username="$1"

    if ! user_exists "${username}"; then
        log_error "User does not exist: ${username}"
        return 1
    fi

    passwd -l "${username}"
    sed -i "s/^STATUS=.*/STATUS=locked/" "${SSH_USERS_DB}/${username}.conf" 2>/dev/null || true
    log_activity "LOCK_SSH_USER" "${username}"
    log_ok "User locked: ${username}"
}

ssh_unlock_user() {
    local username="$1"

    if ! user_exists "${username}"; then
        log_error "User does not exist: ${username}"
        return 1
    fi

    passwd -u "${username}"
    sed -i "s/^STATUS=.*/STATUS=active/" "${SSH_USERS_DB}/${username}.conf" 2>/dev/null || true
    log_activity "UNLOCK_SSH_USER" "${username}"
    log_ok "User unlocked: ${username}"
}

# ---------------------------------------------------------------------------
# Reset password
# ---------------------------------------------------------------------------
ssh_reset_password() {
    local username="$1"
    local new_password="${2:-}"

    if ! user_exists "${username}"; then
        log_error "User does not exist: ${username}"
        return 1
    fi

    if [[ -z "${new_password}" ]]; then
        new_password="$(generate_simple_password 12)"
    fi

    echo "${username}:${new_password}" | chpasswd
    log_activity "RESET_PASSWORD" "${username}"
    log_ok "Password reset for: ${username}"
    print_key_value "  New Password" "${new_password}" "${CYAN}" "${YELLOW}"
}

# ---------------------------------------------------------------------------
# Extend user expiry
# ---------------------------------------------------------------------------
ssh_extend_user() {
    local username="$1"
    local days="${2:-30}"

    if ! user_exists "${username}"; then
        log_error "User does not exist: ${username}"
        return 1
    fi

    local current_expiry
    current_expiry="$(chage -l "${username}" | grep 'Account expires' | cut -d: -f2 | xargs)"

    local new_expiry
    if [[ "${current_expiry}" == "never" ]] || [[ -z "${current_expiry}" ]]; then
        new_expiry="$(days_from_now "${days}")"
    else
        new_expiry="$(date -d "${current_expiry} +${days} days" +%Y-%m-%d 2>/dev/null || \
                       days_from_now "${days}")"
    fi

    chage -E "${new_expiry}" "${username}"
    sed -i "s/^EXPIRY=.*/EXPIRY=${new_expiry}/" "${SSH_USERS_DB}/${username}.conf" 2>/dev/null || true
    log_activity "EXTEND_SSH_USER" "${username} by ${days} days to ${new_expiry}"
    log_ok "Extended ${username} expiry to: ${new_expiry}"
}

# ---------------------------------------------------------------------------
# Show online users
# ---------------------------------------------------------------------------
ssh_online_users() {
    echo ""
    print_header "Online SSH Users"
    echo ""

    local online_count=0
    while IFS= read -r line; do
        local username login_time ip
        username="$(echo "${line}" | awk '{print $1}')"
        login_time="$(echo "${line}" | awk '{print $3, $4, $5}')"
        ip="$(echo "${line}" | awk '{print $NF}' | tr -d '()')"

        # Only show VPN users
        if is_vpn_user "${username}"; then
            printf "  ${GREEN}●${RESET} %-20s %-20s %s\n" "${username}" "${login_time}" "${ip}"
            (( online_count++ ))
        fi
    done < <(who 2>/dev/null)

    # Also check SSH connections
    while IFS= read -r pid; do
        local user ip
        user="$(ps -o user= -p "${pid}" 2>/dev/null | xargs)"
        ip="$(ss -tp | grep "pid=${pid}" | awk '{print $5}' | cut -d: -f1 | head -1)"
        if [[ -n "${user}" ]] && is_vpn_user "${user}" 2>/dev/null; then
            printf "  ${GREEN}●${RESET} %-20s %-20s %s (ssh)\n" "${user}" "$(date '+%H:%M')" "${ip}"
            (( online_count++ )) || true
        fi
    done < <(pgrep -f "sshd: " 2>/dev/null)

    echo ""
    print_key_value "  Total Online" "${online_count}" "${CYAN}" "${YELLOW}"
    echo ""
}

# ---------------------------------------------------------------------------
# Disconnect user
# ---------------------------------------------------------------------------
ssh_disconnect_user() {
    local username="$1"

    local pids
    pids="$(pgrep -u "${username}" sshd 2>/dev/null || true)"

    if [[ -z "${pids}" ]]; then
        # Try pkill
        pkill -u "${username}" 2>/dev/null || true
        log_info "Disconnected user (no active SSH PIDs found): ${username}"
    else
        echo "${pids}" | xargs -r kill -9 2>/dev/null || true
        log_ok "Disconnected SSH sessions for: ${username}"
    fi

    log_activity "DISCONNECT_USER" "${username}"
}

# ---------------------------------------------------------------------------
# Show user expiry dates
# ---------------------------------------------------------------------------
ssh_show_expiry() {
    echo ""
    print_header "SSH User Expiry Dates"
    echo ""
    printf "  ${CYAN}%-20s %-15s %-10s %s${RESET}\n" "Username" "Expires" "Status" "Days Left"
    print_separator "-" 70 "${GRAY}"

    local today_ts
    today_ts="$(date +%s)"

    for conf in "${SSH_USERS_DB}"/*.conf 2>/dev/null; do
        [[ -f "${conf}" ]] || continue
        local username expiry status
        username="$(get_config_value "${conf}" "USERNAME")"
        expiry="$(get_config_value "${conf}" "EXPIRY")"
        status="$(get_config_value "${conf}" "STATUS")"

        local days_left="N/A"
        local color="${WHITE}"

        if [[ "${expiry}" != "never" && -n "${expiry}" ]]; then
            local expiry_ts
            expiry_ts="$(date -d "${expiry}" +%s 2>/dev/null || echo 0)"
            local diff=$(( (expiry_ts - today_ts) / 86400 ))
            days_left="${diff}"

            if [[ "${diff}" -lt 0 ]]; then
                color="${RED}"
                days_left="EXPIRED"
            elif [[ "${diff}" -le 7 ]]; then
                color="${YELLOW}"
            fi
        fi

        printf "  ${color}%-20s %-15s %-10s %s${RESET}\n" \
            "${username}" "${expiry:-N/A}" "${status:-active}" "${days_left}"
    done
    echo ""
}

# ---------------------------------------------------------------------------
# Apply login limit via security limits or PAM
# ---------------------------------------------------------------------------
_apply_login_limit() {
    local username="$1"
    local max_logins="$2"

    local limits_file="/etc/security/limits.d/vpn-${username}.conf"
    cat > "${limits_file}" <<EOF
${username} hard maxlogins ${max_logins}
${username} soft maxlogins ${max_logins}
EOF
    chmod 644 "${limits_file}"
}

# ---------------------------------------------------------------------------
# Set SSH Banner
# ---------------------------------------------------------------------------
ssh_set_banner() {
    local banner_text="$1"

    echo "${banner_text}" > "${SSH_BANNER_FILE}"
    chmod 644 "${SSH_BANNER_FILE}"

    # Ensure Banner directive in sshd_config
    if grep -q "^Banner" "${SSH_CONFIG}"; then
        sed -i "s|^Banner.*|Banner ${SSH_BANNER_FILE}|" "${SSH_CONFIG}"
    else
        echo "Banner ${SSH_BANNER_FILE}" >> "${SSH_CONFIG}"
    fi

    service_reload "ssh" 2>/dev/null || service_reload "sshd" 2>/dev/null || true
    log_ok "SSH banner updated"
}

# ---------------------------------------------------------------------------
# Set MOTD
# ---------------------------------------------------------------------------
ssh_set_motd() {
    local motd_text="$1"

    echo "${motd_text}" > "${SSH_MOTD_FILE}"
    chmod 644 "${SSH_MOTD_FILE}"

    # Disable dynamic MOTD if present
    if [[ -d /etc/update-motd.d ]]; then
        chmod -x /etc/update-motd.d/* 2>/dev/null || true
    fi

    log_ok "MOTD updated"
}

# ---------------------------------------------------------------------------
# Auto-expire check (called by cron)
# ---------------------------------------------------------------------------
ssh_check_expiry() {
    local today
    today="$(date +%Y-%m-%d)"

    for conf in "${SSH_USERS_DB}"/*.conf 2>/dev/null; do
        [[ -f "${conf}" ]] || continue
        local username expiry status
        username="$(get_config_value "${conf}" "USERNAME")"
        expiry="$(get_config_value "${conf}" "EXPIRY")"
        status="$(get_config_value "${conf}" "STATUS")"

        [[ "${status}" == "active" ]] || continue
        [[ -n "${expiry}" && "${expiry}" != "never" ]] || continue

        if [[ "${today}" > "${expiry}" ]]; then
            log_info "Auto-expiring user: ${username}"
            passwd -l "${username}" 2>/dev/null || true
            sed -i "s/^STATUS=.*/STATUS=expired/" "${conf}"
            ssh_disconnect_user "${username}" 2>/dev/null || true
            log_activity "AUTO_EXPIRE" "${username}"
        fi
    done
}

# ---------------------------------------------------------------------------
# List all SSH VPN users
# ---------------------------------------------------------------------------
ssh_list_users() {
    echo ""
    print_header "SSH VPN Users"
    echo ""
    printf "  ${CYAN}%-20s %-12s %-15s %-10s${RESET}\n" "Username" "Status" "Expires" "Type"
    print_separator "-" 65 "${GRAY}"

    for conf in "${SSH_USERS_DB}"/*.conf 2>/dev/null; do
        [[ -f "${conf}" ]] || continue
        local username type expiry status
        username="$(get_config_value "${conf}" "USERNAME")"
        type="$(get_config_value "${conf}" "TYPE")"
        expiry="$(get_config_value "${conf}" "EXPIRY")"
        status="$(get_config_value "${conf}" "STATUS")"

        [[ "${type}" == "ssh" ]] || continue

        local color="${WHITE}"
        [[ "${status}" == "locked" ]] && color="${YELLOW}"
        [[ "${status}" == "expired" ]] && color="${RED}"

        printf "  ${color}%-20s %-12s %-15s %-10s${RESET}\n" \
            "${username}" "${status:-active}" "${expiry:-N/A}" "${type:-ssh}"
    done
    echo ""
}
