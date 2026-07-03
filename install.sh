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
    log_error "Run: cat ${INSTALL_LOG}  to see full details"
    exit "${code}"
}

_on_exit() {
    local code=$?
    if [[ "${code}" -eq 0 ]]; then
        log_info "Install script exited normally."
    fi
    # Always flush log
    sync 2>/dev/null || true
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
    detect_network || true   # non-fatal — fallback handled inside function
}

# ---------------------------------------------------------------------------
# Fix DNS if systemd-resolved stub is broken
# ---------------------------------------------------------------------------
_fix_dns() {
    # Test if DNS works already
    if nslookup google.com 8.8.8.8 &>/dev/null 2>&1; then
        log_ok "DNS: OK"
        return 0
    fi

    log_warn "DNS stub resolver not working — fixing /etc/resolv.conf..."

    # Remove broken symlink/file and write direct nameservers
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 8.8.4.4
EOF
    # Protect from being overwritten by systemd-resolved
    chattr +i /etc/resolv.conf 2>/dev/null || true

    # Test again
    if nslookup google.com &>/dev/null 2>&1; then
        log_ok "DNS fixed — using 8.8.8.8 / 1.1.1.1"
    else
        log_warn "DNS still not resolving. Check your VPS network configuration."
    fi
}


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
# System update — suppress interactive prompts on all releases
# ---------------------------------------------------------------------------
_update_system() {
    log_section "Updating System"
    export DEBIAN_FRONTEND=noninteractive

    # Suppress needrestart interactive prompts (Ubuntu 22.04+)
    if [[ -f /etc/needrestart/needrestart.conf ]]; then
        sed -i "s/^#\?\$nrconf{restart}.*/\$nrconf{restart} = 'a';/" \
            /etc/needrestart/needrestart.conf 2>/dev/null || true
    fi

    # Suppress debconf prompts
    export DEBIAN_FRONTEND=noninteractive
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export UCF_FORCE_CONFFOLD=1

    log_info "Running apt-get update..."
    apt-get update -qq 2>&1 | tee -a "${INSTALL_LOG}" || log_fatal "apt-get update failed"

    log_info "Running apt-get upgrade..."
    apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        -o Dpkg::Options::="--force-confnew" \
        2>&1 | tee -a "${INSTALL_LOG}" || log_warn "Upgrade had non-fatal errors"

    log_ok "System updated"
}

# ---------------------------------------------------------------------------
# Base dependencies — version-aware, never hard-fails on optional packages
# ---------------------------------------------------------------------------
_install_deps() {
    log_section "Installing Dependencies"
    export DEBIAN_FRONTEND=noninteractive

    # ── Always-required packages (exist on all supported releases) ──────────
    local core_pkgs=(
        curl wget git unzip zip tar gzip
        openssl ca-certificates gnupg
        lsb-release apt-transport-https software-properties-common
        coreutils util-linux net-tools iproute2
        iptables iputils-ping dnsutils
        ufw fail2ban certbot cron logrotate
        rsync socat acl bc lsof psmisc procps sysstat
        qrencode uuid-runtime
        python3 python3-yaml
        dropbear
    )

    # ── Optional packages — installed with best-effort ──────────────────────
    # Names or availability vary across Ubuntu/Debian versions
    local optional_pkgs=(
        jq           # sometimes needs backports on older Debian
        whois
        tcpdump
        htop
        iotop
        iftop
        vnstat
        nload
        nftables
        wireguard
        wireguard-tools
    )

    # ── Version-specific extras ──────────────────────────────────────────────
    local versioned_pkgs=()

    # certbot nginx plugin (name changed in Ubuntu 24.04+)
    if [[ -n "${PKG_CERTBOT_NGINX:-}" ]]; then
        versioned_pkgs+=("${PKG_CERTBOT_NGINX}")
    else
        # Try python3-certbot-nginx, fall back silently
        versioned_pkgs+=("python3-certbot-nginx")
    fi

    # needrestart (Ubuntu only — causes interactive prompts on Debian)
    if [[ "${OS_ID}" == "ubuntu" ]]; then
        versioned_pkgs+=("needrestart")
    fi

    # speedtest
    if [[ -n "${PKG_SPEEDTEST:-}" ]]; then
        versioned_pkgs+=("${PKG_SPEEDTEST}")
    fi

    # ── Install core packages (fail loudly if these are missing) ────────────
    log_info "Installing core packages (${#core_pkgs[@]})..."
    local failed_core=()
    for pkg in "${core_pkgs[@]}"; do
        if ! _pkg_installed "${pkg}"; then
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkg}" \
                    2>&1 | tee -a "${INSTALL_LOG}"; then
                failed_core+=("${pkg}")
                log_warn "  Failed to install core package: ${pkg}"
            fi
        fi
    done

    if [[ ${#failed_core[@]} -gt 0 ]]; then
        log_warn "Some core packages failed: ${failed_core[*]}"
        log_warn "This may cause issues. Check apt sources and try: apt-get update"
    fi

    # ── Install optional packages (warn only) ────────────────────────────────
    log_info "Installing optional packages (${#optional_pkgs[@]})..."
    for pkg in "${optional_pkgs[@]}"; do
        if ! _pkg_installed "${pkg}"; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkg}" \
                2>&1 | tee -a "${INSTALL_LOG}" || \
                log_warn "  Optional package unavailable (skipped): ${pkg}"
        fi
    done

    # ── Install versioned/compat packages ────────────────────────────────────
    log_info "Installing version-specific packages..."
    for pkg in "${versioned_pkgs[@]}"; do
        [[ -z "${pkg}" ]] && continue
        if ! _pkg_installed "${pkg}"; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkg}" \
                2>&1 | tee -a "${INSTALL_LOG}" || \
                log_warn "  Version-specific package unavailable (skipped): ${pkg}"
        fi
    done

    # ── WireGuard: needs backports on some older releases ────────────────────
    _install_wireguard_compat

    log_ok "Dependency installation complete"
}

# ---------------------------------------------------------------------------
# WireGuard compatibility across releases
# ---------------------------------------------------------------------------
_install_wireguard_compat() {
    # Skip in containers — kernel module likely unavailable
    if [[ "${IS_CONTAINER:-0}" -eq 1 ]]; then
        log_info "Skipping WireGuard kernel module install (container environment)"
        return 0
    fi

    # Already installed?
    if _pkg_installed wireguard-tools && get_wireguard_kernel_status | grep -qv unavailable; then
        log_ok "WireGuard already available"
        return 0
    fi

    # Ubuntu 20.04 needs wireguard from backports or linux-modules-extra
    if [[ "${OS_ID}" == "ubuntu" && "${OS_MAJOR}" == "20" ]]; then
        log_info "Ubuntu 20.04: installing WireGuard via linux-modules-extra..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            linux-modules-extra-"$(uname -r)" wireguard wireguard-tools \
            2>&1 | tee -a "${INSTALL_LOG}" || \
            log_warn "WireGuard install failed on Ubuntu 20.04 — may need manual setup"
        return 0
    fi

    # Debian 11 (bullseye) needs backports
    if [[ "${OS_ID}" == "debian" && "${OS_MAJOR}" == "11" ]]; then
        log_info "Debian 11: enabling bullseye-backports for WireGuard..."
        if ! grep -q "bullseye-backports" /etc/apt/sources.list 2>/dev/null && \
           ! grep -rq "bullseye-backports" /etc/apt/sources.list.d/ 2>/dev/null; then
            echo "deb http://deb.debian.org/debian bullseye-backports main" \
                >> /etc/apt/sources.list.d/backports.list
            apt-get update -qq 2>&1 | tee -a "${INSTALL_LOG}" || true
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            -t bullseye-backports wireguard wireguard-tools \
            2>&1 | tee -a "${INSTALL_LOG}" || \
            log_warn "WireGuard install from backports failed"
        return 0
    fi

    # All other releases: standard install
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        wireguard wireguard-tools 2>&1 | tee -a "${INSTALL_LOG}" || \
        log_warn "WireGuard install failed — will be skipped during setup"
}

# ---------------------------------------------------------------------------
# Internal: check if package is installed
# ---------------------------------------------------------------------------
_pkg_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q '^ii'
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
# Install 'menu' command and auto-launch on SSH login
# ---------------------------------------------------------------------------
_install_menu_command() {
    log_section "Installing Menu Command"

    # Create global 'menu' command
    cat > /usr/local/bin/menu <<EOF
#!/usr/bin/env bash
exec bash ${SCRIPT_DIR}/menu.sh
EOF
    chmod +x /usr/local/bin/menu
    log_ok "Command installed: 'menu'"

    # Auto-launch on SSH login for root
    local bashrc="/root/.bashrc"
    if ! grep -q "vpn-manager menu" "${bashrc}" 2>/dev/null; then
        cat >> "${bashrc}" <<'BASHRC'

# VPN Manager — auto-launch menu on SSH login
if [[ -n "${SSH_CONNECTION:-}" ]] && [[ $- == *i* ]] && [[ "${TERM:-}" != "dumb" ]]; then
    exec /usr/local/bin/menu
fi
BASHRC
        log_ok "Auto-launch on SSH login configured"
    fi
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
    local elapsed
    elapsed=$(( $(date +%s) - INSTALL_START_TIME ))
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
    _fix_dns
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

    _run_module "wireguard" "module_install_wireguard" || true
    _register_rollback "_run_module wireguard module_remove_wireguard"

    _run_module "hysteria2" "module_install_hysteria2" || true
    _register_rollback "_run_module hysteria2 module_remove_hysteria2"

    _run_module "security"  "module_configure_security"
    _run_module "bbr"       "module_enable_bbr"
    _run_module "ssl"       "module_setup_ssl"
    _run_module "branding"  "module_configure_branding"
    _run_module "monitoring" "module_configure_monitoring"
    _run_module "backup"    "module_configure_backup"

    _verify
    _install_menu_command
    _print_summary
}

main "$@"
