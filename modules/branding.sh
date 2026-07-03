#!/usr/bin/env bash
# =============================================================================
# modules/branding.sh - Server branding and customization
# =============================================================================

BRANDING_CONFIG="/etc/vpn-manager/branding.conf"
SSH_BANNER_FILE="/etc/vpn-manager/ssh_banner"
SSH_MOTD_FILE="/etc/motd"

# ---------------------------------------------------------------------------
# Default branding values
# ---------------------------------------------------------------------------
DEFAULT_SERVER_NAME="MY VPN SERVER"
DEFAULT_PROVIDER_NAME="VPN Provider"
DEFAULT_TELEGRAM="@myvpn"
DEFAULT_WHATSAPP="+1234567890"
DEFAULT_WEBSITE="https://example.com"
DEFAULT_EMAIL="admin@example.com"
DEFAULT_MENU_TITLE="VPN & SSH Management Suite"
DEFAULT_FOOTER="All rights reserved."

# ---------------------------------------------------------------------------
# Initial branding configuration (called during install)
# ---------------------------------------------------------------------------
module_configure_branding() {
    log_info "Configuring branding..."

    # Load or create branding config
    if [[ ! -f "${BRANDING_CONFIG}" ]]; then
        _write_default_branding
    fi

    # Load branding
    _load_branding

    # Write banner and MOTD from templates
    _write_ssh_banner
    _write_motd

    log_ok "Branding configured"
}

# ---------------------------------------------------------------------------
# Load branding values from config
# ---------------------------------------------------------------------------
_load_branding() {
    if [[ -f "${BRANDING_CONFIG}" ]]; then
        # shellcheck source=/dev/null
        source "${BRANDING_CONFIG}"
    fi

    # Set defaults for any missing values
    BRAND_SERVER_NAME="${BRAND_SERVER_NAME:-${DEFAULT_SERVER_NAME}}"
    BRAND_PROVIDER_NAME="${BRAND_PROVIDER_NAME:-${DEFAULT_PROVIDER_NAME}}"
    BRAND_TELEGRAM="${BRAND_TELEGRAM:-${DEFAULT_TELEGRAM}}"
    BRAND_WHATSAPP="${BRAND_WHATSAPP:-${DEFAULT_WHATSAPP}}"
    BRAND_WEBSITE="${BRAND_WEBSITE:-${DEFAULT_WEBSITE}}"
    BRAND_EMAIL="${BRAND_EMAIL:-${DEFAULT_EMAIL}}"
    BRAND_MENU_TITLE="${BRAND_MENU_TITLE:-${DEFAULT_MENU_TITLE}}"
    BRAND_FOOTER="${BRAND_FOOTER:-${DEFAULT_FOOTER}}"

    export BRAND_SERVER_NAME BRAND_PROVIDER_NAME BRAND_TELEGRAM BRAND_WHATSAPP
    export BRAND_WEBSITE BRAND_EMAIL BRAND_MENU_TITLE BRAND_FOOTER
}

# ---------------------------------------------------------------------------
# Write default branding config
# ---------------------------------------------------------------------------
_write_default_branding() {
    mkdir -p /etc/vpn-manager
    cat > "${BRANDING_CONFIG}" <<EOF
# VPN Manager Branding Configuration
BRAND_SERVER_NAME="${DEFAULT_SERVER_NAME}"
BRAND_PROVIDER_NAME="${DEFAULT_PROVIDER_NAME}"
BRAND_TELEGRAM="${DEFAULT_TELEGRAM}"
BRAND_WHATSAPP="${DEFAULT_WHATSAPP}"
BRAND_WEBSITE="${DEFAULT_WEBSITE}"
BRAND_EMAIL="${DEFAULT_EMAIL}"
BRAND_MENU_TITLE="${DEFAULT_MENU_TITLE}"
BRAND_FOOTER="${DEFAULT_FOOTER}"
EOF
    chmod 644 "${BRANDING_CONFIG}"
}

# ---------------------------------------------------------------------------
# Write SSH banner
# ---------------------------------------------------------------------------
_write_ssh_banner() {
    _load_branding
    local line
    line="$(printf '%0.s=' {1..50})"

    cat > "${SSH_BANNER_FILE}" <<EOF
${line}
  ${BRAND_SERVER_NAME}

  Welcome to ${BRAND_PROVIDER_NAME}
  Telegram  : ${BRAND_TELEGRAM}
  WhatsApp  : ${BRAND_WHATSAPP}
  Website   : ${BRAND_WEBSITE}
  Email     : ${BRAND_EMAIL}

  Unauthorized access is strictly prohibited.
  All activities are logged and monitored.
${line}

EOF
    chmod 644 "${SSH_BANNER_FILE}"
    log_ok "SSH banner written"
}

# ---------------------------------------------------------------------------
# Write MOTD
# ---------------------------------------------------------------------------
_write_motd() {
    _load_branding

    cat > "${SSH_MOTD_FILE}" <<EOF
$(printf '%0.s─' {1..50})
  Welcome to ${BRAND_SERVER_NAME}
  Provider : ${BRAND_PROVIDER_NAME}
  Support  : ${BRAND_TELEGRAM}
  Website  : ${BRAND_WEBSITE}
$(printf '%0.s─' {1..50})
EOF
    chmod 644 "${SSH_MOTD_FILE}"

    # Disable dynamic MOTD
    if [[ -d /etc/update-motd.d ]]; then
        chmod -x /etc/update-motd.d/* 2>/dev/null || true
    fi

    log_ok "MOTD written"
}

# ---------------------------------------------------------------------------
# Interactive branding menu
# ---------------------------------------------------------------------------
branding_edit_interactive() {
    _load_branding

    echo ""
    print_header "Edit Branding"
    echo ""

    BRAND_SERVER_NAME="$(prompt_with_default "Server Name" "${BRAND_SERVER_NAME}")"
    BRAND_PROVIDER_NAME="$(prompt_with_default "Provider Name" "${BRAND_PROVIDER_NAME}")"
    BRAND_TELEGRAM="$(prompt_with_default "Telegram" "${BRAND_TELEGRAM}")"
    BRAND_WHATSAPP="$(prompt_with_default "WhatsApp" "${BRAND_WHATSAPP}")"
    BRAND_WEBSITE="$(prompt_with_default "Website" "${BRAND_WEBSITE}")"
    BRAND_EMAIL="$(prompt_with_default "Email" "${BRAND_EMAIL}")"
    BRAND_MENU_TITLE="$(prompt_with_default "Menu Title" "${BRAND_MENU_TITLE}")"
    BRAND_FOOTER="$(prompt_with_default "Footer" "${BRAND_FOOTER}")"

    # Save branding
    cat > "${BRANDING_CONFIG}" <<EOF
# VPN Manager Branding Configuration
BRAND_SERVER_NAME="${BRAND_SERVER_NAME}"
BRAND_PROVIDER_NAME="${BRAND_PROVIDER_NAME}"
BRAND_TELEGRAM="${BRAND_TELEGRAM}"
BRAND_WHATSAPP="${BRAND_WHATSAPP}"
BRAND_WEBSITE="${BRAND_WEBSITE}"
BRAND_EMAIL="${BRAND_EMAIL}"
BRAND_MENU_TITLE="${BRAND_MENU_TITLE}"
BRAND_FOOTER="${BRAND_FOOTER}"
EOF

    export BRAND_SERVER_NAME BRAND_PROVIDER_NAME BRAND_TELEGRAM BRAND_WHATSAPP
    export BRAND_WEBSITE BRAND_EMAIL BRAND_MENU_TITLE BRAND_FOOTER

    _write_ssh_banner
    _write_motd

    # Restart SSH to apply new banner
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

    log_ok "Branding updated and applied"
    press_enter
}

# ---------------------------------------------------------------------------
# Edit SSH Banner directly
# ---------------------------------------------------------------------------
branding_edit_banner() {
    echo ""
    print_header "Edit SSH Banner"
    echo ""
    print_color "${CYAN}" "  Current banner:"
    cat "${SSH_BANNER_FILE}" 2>/dev/null || echo "  (empty)"
    echo ""
    print_color "${YELLOW}" "  Enter new banner text (end with a line containing only 'END'):"
    echo ""

    local banner_lines=()
    while IFS= read -r line; do
        [[ "${line}" == "END" ]] && break
        banner_lines+=("${line}")
    done

    printf '%s\n' "${banner_lines[@]}" > "${SSH_BANNER_FILE}"
    chmod 644 "${SSH_BANNER_FILE}"

    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    log_ok "SSH banner updated"
    press_enter
}

# ---------------------------------------------------------------------------
# Edit MOTD directly
# ---------------------------------------------------------------------------
branding_edit_motd() {
    echo ""
    print_header "Edit MOTD"
    echo ""
    print_color "${CYAN}" "  Current MOTD:"
    cat "${SSH_MOTD_FILE}" 2>/dev/null || echo "  (empty)"
    echo ""
    print_color "${YELLOW}" "  Enter new MOTD text (end with a line containing only 'END'):"
    echo ""

    local motd_lines=()
    while IFS= read -r line; do
        [[ "${line}" == "END" ]] && break
        motd_lines+=("${line}")
    done

    printf '%s\n' "${motd_lines[@]}" > "${SSH_MOTD_FILE}"
    chmod 644 "${SSH_MOTD_FILE}"
    log_ok "MOTD updated"
    press_enter
}
