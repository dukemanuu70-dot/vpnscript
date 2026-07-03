#!/usr/bin/env bash
# =============================================================================
# lib/detect.sh - OS, architecture, virtualization, and network detection
# =============================================================================
# Designed to support:
#   Ubuntu: 20.04, 22.04, 24.04, 26.04 and any future Ubuntu release
#   Debian: 11 (bullseye), 12 (bookworm), 13 (trixie) and any future Debian
#
# Philosophy: never block on an unknown future version — warn and continue.
# Minimum supported baseline: Ubuntu 20.04 / Debian 11.
# =============================================================================

# ---------------------------------------------------------------------------
# Exported globals (populated by detect_* functions)
# ---------------------------------------------------------------------------
OS_ID=""           # ubuntu | debian
OS_VERSION=""      # e.g. 22.04 / 12
OS_CODENAME=""     # e.g. jammy / bookworm
OS_FAMILY=""       # always "debian" for our supported set
OS_MAJOR=""        # major version number (int)
OS_MINOR=""        # minor version number (int, 0 for Debian)
ARCH=""            # amd64 | arm64 | armv7
VIRT_TYPE=""       # kvm | lxc | docker | vmware | none | …
IS_CONTAINER=0     # 1 if running inside any container/OpenVZ
SERVER_IPV4=""
SERVER_IPV6=""
KERNEL_VERSION=""

# Package-name compat shims (set by _resolve_package_compat)
PKG_CERTBOT_NGINX=""   # python3-certbot-nginx or certbot-nginx

# ---------------------------------------------------------------------------
# detect_os
# ---------------------------------------------------------------------------
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_fatal "Cannot detect OS: /etc/os-release not found"
    fi

    # Source safely into local vars first to avoid polluting global scope
    local id version_id version_codename ubuntu_codename pretty_name id_like
    id=""
    version_id=""
    version_codename=""
    ubuntu_codename=""

    while IFS='=' read -r key val; do
        # Strip surrounding quotes
        val="${val%\"}"
        val="${val#\"}"
        case "${key}" in
            ID)                id="${val,,}" ;;
            VERSION_ID)        version_id="${val}" ;;
            VERSION_CODENAME)  version_codename="${val}" ;;
            UBUNTU_CODENAME)   ubuntu_codename="${val}" ;;
            PRETTY_NAME)       pretty_name="${val}" ;;
            ID_LIKE)           id_like="${val}" ;;
        esac
    done < /etc/os-release

    OS_ID="${id}"
    OS_VERSION="${version_id}"
    # Ubuntu 22.04+ has UBUNTU_CODENAME; older uses VERSION_CODENAME
    OS_CODENAME="${ubuntu_codename:-${version_codename}}"
    OS_CODENAME="${OS_CODENAME,,}"   # lowercase

    # Determine OS family — also accept Ubuntu-based distros via ID_LIKE
    case "${OS_ID}" in
        ubuntu)
            OS_FAMILY="debian"
            ;;
        debian)
            OS_FAMILY="debian"
            ;;
        *)
            # Some distros (e.g. Linux Mint, Pop!_OS) set ID_LIKE=ubuntu or debian
            if echo "${id_like:-}" | grep -qiE 'ubuntu|debian'; then
                log_warn "Detected ${OS_ID} (based on ${id_like}). Treating as Ubuntu/Debian-compatible."
                OS_FAMILY="debian"
                # Use the base OS id for package logic
                if echo "${id_like:-}" | grep -qi ubuntu; then
                    OS_ID="ubuntu"
                else
                    OS_ID="debian"
                fi
            else
                log_fatal "Unsupported OS: ${id} (${pretty_name:-unknown}). Only Ubuntu and Debian are supported."
            fi
            ;;
    esac

    # Parse version numbers
    OS_MAJOR="${OS_VERSION%%.*}"
    OS_MINOR="${OS_VERSION##*.}"
    # For Debian the version is a single integer; set minor to 0
    [[ "${OS_MAJOR}" == "${OS_VERSION}" ]] && OS_MINOR="0"

    KERNEL_VERSION="$(uname -r)"

    log_ok "OS       : ${pretty_name:-${OS_ID} ${OS_VERSION}}"
    log_ok "Codename : ${OS_CODENAME:-n/a}"
    log_ok "Kernel   : ${KERNEL_VERSION}"

    export OS_ID OS_VERSION OS_CODENAME OS_FAMILY OS_MAJOR OS_MINOR KERNEL_VERSION
}

# ---------------------------------------------------------------------------
# validate_os  — never hard-block future releases, only warn
# ---------------------------------------------------------------------------
validate_os() {
    local verdict=""   # "supported" | "warn" | "unsupported"

    case "${OS_ID}" in
        # ── Ubuntu ──────────────────────────────────────────────────────────
        ubuntu)
            case "${OS_VERSION}" in
                20.04|22.04|24.04|26.04)
                    verdict="supported"
                    ;;
                *)
                    # Accept any Ubuntu >= 20.04
                    # Future LTS releases: even year, .04 month (28.04, 30.04 …)
                    # Interim releases (e.g. 23.10, 25.04) also accepted with warning
                    if _version_ge "${OS_MAJOR}" 20; then
                        verdict="warn"
                    else
                        verdict="unsupported"
                    fi
                    ;;
            esac
            ;;

        # ── Debian ──────────────────────────────────────────────────────────
        debian)
            case "${OS_VERSION}" in
                11|12|13)
                    verdict="supported"
                    ;;
                *)
                    # Accept any Debian >= 11
                    if [[ "${OS_VERSION}" =~ ^[0-9]+$ ]] && _version_ge "${OS_VERSION}" 11; then
                        verdict="warn"
                    else
                        verdict="unsupported"
                    fi
                    ;;
            esac
            ;;

        *)
            verdict="unsupported"
            ;;
    esac

    case "${verdict}" in
        supported)
            log_ok "OS version: ${OS_ID} ${OS_VERSION} — fully supported"
            ;;
        warn)
            log_warn "OS version: ${OS_ID} ${OS_VERSION} — not explicitly tested."
            log_warn "Proceeding with best-effort compatibility. Some packages may differ."
            log_warn "If you hit package errors, please open an issue on GitHub."
            ;;
        unsupported)
            log_fatal "Unsupported OS version: ${OS_ID} ${OS_VERSION}. Minimum: Ubuntu 20.04 / Debian 11."
            ;;
    esac

    # Resolve package name differences for this specific version
    _resolve_package_compat

    export OS_ID OS_VERSION OS_CODENAME OS_FAMILY OS_MAJOR OS_MINOR
}

# ---------------------------------------------------------------------------
# _resolve_package_compat
# Set global shim variables for packages whose names changed across releases
# ---------------------------------------------------------------------------
_resolve_package_compat() {
    # python3-certbot-nginx was renamed in some releases
    if apt-cache show python3-certbot-nginx &>/dev/null 2>&1; then
        PKG_CERTBOT_NGINX="python3-certbot-nginx"
    elif apt-cache show certbot &>/dev/null 2>&1; then
        PKG_CERTBOT_NGINX=""   # certbot alone; nginx plugin installed separately
    fi

    # needrestart: Ubuntu-only, not in Debian
    PKG_NEEDRESTART=""
    if [[ "${OS_ID}" == "ubuntu" ]]; then
        apt-cache show needrestart &>/dev/null 2>&1 && PKG_NEEDRESTART="needrestart"
    fi

    # nftables vs iptables: both available on modern kernels, prefer nftables
    PKG_NFTABLES=""
    apt-cache show nftables &>/dev/null 2>&1 && PKG_NFTABLES="nftables"

    # speedtest-cli package name varies
    PKG_SPEEDTEST=""
    if apt-cache show speedtest-cli &>/dev/null 2>&1; then
        PKG_SPEEDTEST="speedtest-cli"
    fi

    export PKG_CERTBOT_NGINX PKG_NEEDRESTART PKG_NFTABLES PKG_SPEEDTEST

    log_info "Package compat: certbot-nginx=${PKG_CERTBOT_NGINX:-certbot-only}"
    log_info "Package compat: nftables=${PKG_NFTABLES:-not-available}"
}

# ---------------------------------------------------------------------------
# detect_architecture
# ---------------------------------------------------------------------------
detect_architecture() {
    local raw_arch
    raw_arch="$(uname -m)"

    case "${raw_arch}" in
        x86_64)          ARCH="amd64"   ;;
        aarch64|arm64)   ARCH="arm64"   ;;
        armv7l|armv7)    ARCH="armv7"   ;;
        armv6l)
            ARCH="armv6"
            log_warn "ARMv6 detected. Some binaries (Xray, Hysteria2) may not have official builds."
            ;;
        riscv64)
            ARCH="riscv64"
            log_warn "RISC-V detected. Pre-built binaries may not be available."
            ;;
        *)
            ARCH="${raw_arch}"
            log_warn "Unknown architecture: ${raw_arch}. Defaulting to amd64 for downloads — may fail."
            ARCH="amd64"
            ;;
    esac

    log_ok "Architecture: ${ARCH} (${raw_arch})"
    export ARCH
}

# ---------------------------------------------------------------------------
# detect_virtualization
# ---------------------------------------------------------------------------
detect_virtualization() {
    VIRT_TYPE="none"
    IS_CONTAINER=0

    # 1. systemd-detect-virt (most reliable on systemd systems)
    if command -v systemd-detect-virt &>/dev/null; then
        VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo 'none')"
    fi

    # 2. Fallbacks for systems without systemd-detect-virt
    if [[ "${VIRT_TYPE}" == "none" ]]; then
        # Docker
        if [[ -f /.dockerenv ]]; then
            VIRT_TYPE="docker"
        # LXC via cgroup
        elif grep -qa 'lxc' /proc/1/cgroup 2>/dev/null; then
            VIRT_TYPE="lxc"
        # LXC via environment
        elif [[ -f /proc/1/environ ]] && \
             grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
            VIRT_TYPE="lxc"
        # OpenVZ
        elif [[ -d /proc/vz ]] && [[ ! -d /proc/bc ]]; then
            VIRT_TYPE="openvz"
        # Hyper-V
        elif grep -qa 'hyperv\|Hyper-V\|VRTUAL\|VirtualMachine' \
                  /sys/class/dmi/id/product_name 2>/dev/null; then
            VIRT_TYPE="microsoft"
        # VMware
        elif grep -qa 'VMware' /sys/class/dmi/id/product_name 2>/dev/null; then
            VIRT_TYPE="vmware"
        # KVM/QEMU via cpuinfo
        elif grep -qa 'hypervisor' /proc/cpuinfo 2>/dev/null; then
            VIRT_TYPE="kvm"
        fi
    fi

    # 3. Classify as container or VM
    case "${VIRT_TYPE}" in
        lxc|lxc-libvirt|openvz|docker|podman|container-other|systemd-nspawn)
            IS_CONTAINER=1
            log_warn "Container/paravirt detected: ${VIRT_TYPE}"
            log_warn "  → WireGuard kernel module may be unavailable"
            log_warn "  → BBR may be unavailable"
            log_warn "  → UDP-based protocols (Hysteria2) may be restricted"
            ;;
        kvm|qemu|vmware|microsoft|hyperv|xen)
            IS_CONTAINER=0
            log_ok "Virtualization: ${VIRT_TYPE} (full VM — all features supported)"
            ;;
        none)
            IS_CONTAINER=0
            log_ok "Virtualization: bare metal"
            ;;
        *)
            IS_CONTAINER=0
            log_warn "Unknown virtualization type: ${VIRT_TYPE}. Assuming full VM."
            ;;
    esac

    export VIRT_TYPE IS_CONTAINER
}

# ---------------------------------------------------------------------------
# detect_network
# ---------------------------------------------------------------------------
detect_network() {
    SERVER_IPV4=""
    SERVER_IPV6=""

    # IPv4 detection — try multiple sources, never fatal
    local ipv4_sources=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://checkip.amazonaws.com"
        "https://ipinfo.io/ip"
        "https://ifconfig.me/ip"
    )
    for src in "${ipv4_sources[@]}"; do
        local ip=""
        ip="$(curl -4 -s --connect-timeout 5 --max-time 8 "${src}" 2>/dev/null \
              | tr -d '[:space:]')" || true
        if _is_valid_ipv4 "${ip}"; then
            SERVER_IPV4="${ip}"
            break
        fi
    done

    # IPv6 detection — optional, never fatal
    local ipv6_sources=(
        "https://api6.ipify.org"
        "https://ipv6.icanhazip.com"
        "https://v6.ident.me"
    )
    for src in "${ipv6_sources[@]}"; do
        local ip=""
        ip="$(curl -6 -s --connect-timeout 5 --max-time 8 "${src}" 2>/dev/null \
              | tr -d '[:space:]')" || true
        if [[ "${ip}" =~ : ]]; then
            SERVER_IPV6="${ip}"
            break
        fi
    done

    # Must have at least IPv4
    if [[ -z "${SERVER_IPV4}" ]]; then
        # Last resort: read from primary interface
        SERVER_IPV4="$(get_local_ip 2>/dev/null || true)"
        if [[ -z "${SERVER_IPV4}" ]]; then
            log_warn "Could not detect public IP. You can set it manually in /etc/vpn-manager/vpn.conf"
            SERVER_IPV4="UNKNOWN"
        else
            log_warn "Using local interface IP: ${SERVER_IPV4} (may be a private/NAT address)"
        fi
    fi

    log_ok "IPv4: ${SERVER_IPV4}"
    log_ok "IPv6: ${SERVER_IPV6:-none detected}"

    export SERVER_IPV4 SERVER_IPV6
}

# ---------------------------------------------------------------------------
# check_internet
# ---------------------------------------------------------------------------
check_internet() {
    # Try ping first (fast)
    local ping_hosts=("8.8.8.8" "1.1.1.1")
    for h in "${ping_hosts[@]}"; do
        if ping -c 1 -W 3 "${h}" &>/dev/null 2>&1; then
            return 0
        fi
    done
    # Ping may be blocked — try HTTPS
    if curl -fsSL --connect-timeout 8 --max-time 10 \
            -o /dev/null "https://google.com" 2>/dev/null; then
        return 0
    fi
    if curl -fsSL --connect-timeout 8 --max-time 10 \
            -o /dev/null "https://github.com" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# get_primary_interface
# ---------------------------------------------------------------------------
get_primary_interface() {
    # Try the default route first
    local iface
    iface="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
    if [[ -z "${iface}" ]]; then
        # Fallback: first non-loopback interface
        iface="$(ip -o link show | awk -F': ' '!/lo|docker|veth|br-/{print $2; exit}')"
    fi
    echo "${iface:-eth0}"
}

# ---------------------------------------------------------------------------
# get_local_ip
# ---------------------------------------------------------------------------
get_local_ip() {
    ip route get 8.8.8.8 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'
}

# ---------------------------------------------------------------------------
# get_xray_download_url  (arch-aware)
# ---------------------------------------------------------------------------
get_xray_download_url() {
    local version="${1:-latest}"
    local base="https://github.com/XTLS/Xray-core/releases"

    if [[ "${version}" == "latest" ]]; then
        version="$(curl -fsSL --connect-timeout 10 --max-time 15 \
            "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
            2>/dev/null | grep '"tag_name"' | head -1 \
            | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' || echo 'v1.8.11')"
    fi

    local arch_str
    case "${ARCH:-amd64}" in
        amd64)  arch_str="64" ;;
        arm64)  arch_str="arm64-v8a" ;;
        armv7)  arch_str="arm32-v7a" ;;
        armv6)  arch_str="arm32-v6" ;;
        *)      arch_str="64" ;;  # fallback to amd64
    esac

    echo "${base}/download/${version}/Xray-linux-${arch_str}.zip"
}

# ---------------------------------------------------------------------------
# get_hysteria2_download_url  (arch-aware)
# ---------------------------------------------------------------------------
get_hysteria2_download_url() {
    local base="https://github.com/apernet/hysteria/releases/latest/download"

    local arch_str
    case "${ARCH:-amd64}" in
        amd64)  arch_str="amd64" ;;
        arm64)  arch_str="arm64" ;;
        armv7)  arch_str="arm-7" ;;
        *)      arch_str="amd64" ;;
    esac

    echo "${base}/hysteria-linux-${arch_str}"
}

# ---------------------------------------------------------------------------
# get_wireguard_kernel_status  — returns "available" | "module" | "unavailable"
# ---------------------------------------------------------------------------
get_wireguard_kernel_status() {
    # Kernel 5.6+ has WireGuard built-in
    local kmaj kmin
    kmaj="$(uname -r | cut -d. -f1)"
    kmin="$(uname -r | cut -d. -f2)"

    if [[ "${kmaj}" -gt 5 ]] || \
       { [[ "${kmaj}" -eq 5 ]] && [[ "${kmin}" -ge 6 ]]; }; then
        echo "builtin"
        return
    fi

    # Check for wireguard module
    if modinfo wireguard &>/dev/null 2>&1; then
        echo "module"
        return
    fi

    echo "unavailable"
}

# ---------------------------------------------------------------------------
# _is_valid_ipv4  — internal helper
# ---------------------------------------------------------------------------
_is_valid_ipv4() {
    local ip="${1:-}"
    if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    local IFS='.'
    read -ra parts <<< "${ip}"
    for part in "${parts[@]}"; do
        [[ "${part}" -le 255 ]] || return 1
    done
    # Reject obviously private/loopback addresses as "public" IP
    # (but keep them as fallback if that's all we have)
    return 0
}

# ---------------------------------------------------------------------------
# _version_ge  — numeric "greater than or equal" comparison
# Usage: _version_ge 22 20   → true (22 >= 20)
# ---------------------------------------------------------------------------
_version_ge() {
    local a="${1:-0}"
    local b="${2:-0}"
    [[ "${a}" =~ ^[0-9]+$ ]] && [[ "${b}" =~ ^[0-9]+$ ]] && \
        [[ "${a}" -ge "${b}" ]]
}
