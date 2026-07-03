#!/usr/bin/env bash
# =============================================================================
# VPN Manager - Main Installer v1.0.0
# =============================================================================
# Description: Production-ready VPN & SSH Server Management Suite
# Supports: Ubuntu 20.04/22.04/24.04/26.04+, Debian 11/12/13+
# License: MIT
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Resolve script directory
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
MODULES_DIR="${SCRIPT_DIR}/modules"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
SYSTEMD_DIR="${SCRIPT_DIR}/systemd"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
LOGS_DIR="${SCRIPT_DIR}/logs"

# ---------------------------------------------------------------------------
# Ensure log directory exists early
# ---------------------------------------------------------------------------
mkdir -p "${LOGS_DIR}" /var/log/vpn-manager
INSTALL_LOG="/var/log/vpn-manager/install_$(date +%Y%m%d_%H%M%S).log"
LOG_FILE="${INSTALL_LOG}"

# Redirect all output to log
exec > >(tee -a "${INSTALL_LOG}") 2>&1

# ---------------------------------------------------------------------------
# Source libraries
# ---------------------------------------------------------------------------
for lib in colors logger utils detect validate; do
    lib_file="${LIB_DIR}/${lib}.sh"
    if [[ ! -f "${lib_file}" ]]; then
        echo "FATAL: Required library missing: ${lib_file}"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "${lib_file}"
done

# ---------------------------------------------------------------------------
# Export LOG_FILE for modules
# ---------------------------------------------------------------------------
export LOG_FILE INSTALL_LOG SCRIPT_DIR LIB_DIR MODULES_DIR

# ---------------------------------------------------------------------------
# Rollback state
# ---------------------------------------------------------------------------
ROLLBACK_ACTIONS=()
INSTALL_START_TIME="$(date +%s)"

# ---------------------------------------------------------------------------
# Trap handlers
# ---------------------------------------------------------------------------
trap '_on_error $? $LINENO' ERR
trap '_on_exit' EXIT

_on_error() {
    local code="$1" line="$2"
    log_error "Fatal error at line ${line} (exit code ${code})"
    log_warn "Initiating rollback..."
    _perform_rollback
    log_error "Installation failed. Log: ${INSTALL_LOG}"
    exit "${code}"
}

_on_exit() {
    local code=$?
    [[ "${code}" -eq 0 ]] && log_info "Install script exited normally."
}

_perform_rollback() {
    for (( i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i-- )); do
        local action="${ROLLBACK_ACTIONS[$i]}"
        log_warn "Rollback: ${action}"
        eval "${action}" 2>/dev/null || true
    done
}

_register_rollback() {
    ROLLBACK_ACTIONS+=("$1")
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
_preflight() {
    log_section "Pre-flight Checks"

    [[ "${EUID}" -ne 0 ]] && log_fatal "Must be run as root: sudo bash install.sh"
    log_ok "Running as root"

    [[ "${BASH_VERSINFO[0]}" -lt 4 ]] && log_fatal "Bash 4+ required (current: ${BASH_VERSION})"
    log_ok "Bash ${BASH_VERSION}"

    check_internet || log_fatal "No internet connection detected"
    log_ok "Internet: OK"

    local free_kb
    free_kb="$(df / --output=avail | tail -1)"
    [[ "${free_kb}" -lt 2097152 ]] && \
        log_fatal "Need 2GB+ free disk space (have: $(( free_kb / 1024 ))MB)"
    log_ok "Disk: $(( free_kb / 1024 / 1024 ))GB free"

    local ram_mb
    ram_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
    [[ "${ram_mb}" -lt 512 ]] && log_warn "Low RAM: ${ram_mb}MB (min recommended: 512MB)"
    log_ok "RAM: ${ram_mb}MB"

    detect_os
    validate_os
    detect_architecture
    detect_virtualization
    detect_network
}

# ---------------------------------------------------------------------------
# Create directory structure
# ---------------------------------------------------------------------------
_create_dirs() {
    log_section "Creating Directory Structure"
    local dirs=(
        "${LOGS_DIR}"
        "/etc/vpn-manager"
        "/etc/vpn-manager/ssl"
        "/etc/vpn-manager/users"
        "/etc/vpn-manager/backups"
        "/var/lib/vpn-manager"
        "/var/lib/vpn-manager/backups"
        "/var/log/vpn-manager"
    )
    for dir in "${dirs[@]}"; do
        mkdir -p "${dir}"
        log_ok "Created: ${dir}"
    done
    chmod 700 /etc/vpn-manager/ssl /etc/vpn-manager/users /etc/vpn-manager/backups
}

# ---------------------------------------------------------------------------
# System update
# ---------------------------------------------------------------------------
_update_system() {
    log_section "Updating System"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>&1 | tee -a "${INSTALL_LOG}" || log_fatal "apt-get update failed"
    apt-get upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        2>&1 | tee -a "${INSTALL_LOG}" || log_warn "Upgrade had some errors"
    log_ok "System updated"
}

# ---------------------------------------------------------------------------
# Base dependencies
# ---------------------------------------------------------------------------
_install_deps() {
    log_section "Installing Dependencies"
    export DEBIAN_FRONTEND=noninteractive

    local pkgs=(
        curl wget git unzip zip tar gzip jq openssl ca-certificates gnupg
        lsb-release apt-transport-https software-properties-common
        coreutils util-linux net-tools iproute2 iptables iputils-ping
        dnsutils whois tcpdump htop iotop iftop vnstat nload
        ufw fail2ban certbot python3-certbot-nginx cron logrotate
        rsync socat acl bc lsof psmisc procps sysstat
        qrencode uuid-runtime nftables python3 python3-yaml
        wireguard wireguard-tools dropbear
    )

    for pkg in "${pkgs[@]}"; do
        if ! dpkg -l "${pkg}" &>/dev/null; then
            apt-get install -y -qq "${pkg}" 2>&1 | tee -a "${INSTALL_LOG}" || \
                log_warn "Could not install: ${pkg}"
        fi
    done
    log_ok "Dependencies installed"
}

# ---------------------------------------------------------------------------
# Load and run module
# ---------------------------------------------------------------------------
_run_module() {
    local module="$1"
    local func="$2"
    local module_file="${MODULES_DIR}/${module}.sh"

    if [[ ! -f "${module_file}" ]]; then
        log_warn "Module not found: ${module_file}"
        return 0
    fi

    # shellcheck source=/dev/null
    source "${module_file}"
    "${func}"
}

# ---------------------------------------------------------------------------
# Post-install verification
# ---------------------------------------------------------------------------
_verify() {
    log_section "Verifying Installation"

    local services=("ssh" "dropbear" "nginx" "xray" "fail2ban")
    local failed=0

    for svc in "${services[@]}"; do
        if systemctl is-enabled "${svc}" &>/dev/null 2>&1; then
            if systemctl is-active --quiet "${svc}"; then
                log_ok "Running: ${svc}"
            else
                systemctl start "${svc}" 2>/dev/null || true
                if systemctl is-active --quiet "${svc}"; then
                    log_ok "Started: ${svc}"
                else
                    log_warn "Not running: ${svc}"
                    (( failed++ )) || true
                fi
            fi
        else
            log_info "Not enabled: ${svc} (may be optional)"
        fi
    done

    [[ "${failed}" -gt 0 ]] && \
        log_warn "${failed} service(s) need attention. Check logs."
    log_ok "Verification complete"
}

# ---------------------------------------------------------------------------
# Install summary
# ---------------------------------------------------------------------------
_print_summary() {
    local elapsed=$(( $(date +%s) - INSTALL_START_TIME ))
    echo ""
    print_banner
    echo ""
    print_color "${GREEN}" "  ✓ Installation Complete!"
    echo ""
    print_key_value "  OS"       "${OS_ID} ${OS_VERSION}"
    print_key_value "  Arch"     "${ARCH}"
    print_key_value "  IPv4"     "${SERVER_IPV4:-N/A}"
    print_key_value "  IPv6"     "${SERVER_IPV6:-N/A}"
    print_key_value "  Virt"     "${VIRT_TYPE:-bare-metal}"
    print_key_value "  Time"     "${elapsed}s"
    print_key_value "  Log"      "${INSTALL_LOG}"
    echo ""
    print_color "${CYAN}" "  Run the management menu:"
    print_color "${WHITE}" "    bash ${SCRIPT_DIR}/menu.sh"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    print_banner
    echo ""
    log_info "VPN Manager Installer v1.0.0"
    log_info "Log: ${INSTALL_LOG}"
    echo ""

    _preflight
    _create_dirs
    _update_system
    _install_deps

    _run_module "ssh"       "module_install_openssh"
    _register_rollback "_run_module ssh module_remove_openssh"

    _run_module "dropbear"  "module_install_dropbear"
    _register_rollback "_run_module dropbear module_remove_dropbear"

    _run_module "nginx"     "module_install_nginx"
    _register_rollback "_run_module nginx module_remove_nginx"

    _run_module "xray"      "module_install_xray"
    _register_rollback "_run_module xray module_remove_xray"

    _run_module "wireguard" "module_install_wireguard"
    _register_rollback "_run_module wireguard module_remove_wireguard"

    _run_module "hysteria2" "module_install_hysteria2"
    _register_rollback "_run_module hysteria2 module_remove_hysteria2"

    _run_module "security"  "module_configure_security"
    _run_module "bbr"       "module_enable_bbr"
    _run_module "ssl"       "module_setup_ssl"
    _run_module "branding"  "module_configure_branding"
    _run_module "monitoring" "module_configure_monitoring"
    _run_module "backup"    "module_configure_backup"

    _verify
    _print_summary
}

main "$@"
