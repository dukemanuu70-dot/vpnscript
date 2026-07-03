#!/usr/bin/env bash
# =============================================================================
# lib/detect.sh - OS, architecture, virtualization, and network detection
# =============================================================================

# Exported detection results
OS_ID=""
OS_VERSION=""
OS_CODENAME=""
OS_FAMILY=""
ARCH=""
VIRT_TYPE=""
SERVER_IPV4=""
SERVER_IPV6=""
KERNEL_VERSION=""
IS_CONTAINER=0

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_fatal "Cannot detect OS: /etc/os-release not found"
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    OS_ID="${ID,,}"
    OS_VERSION="${VERSION_ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"

    case "${OS_ID}" in
        ubuntu) OS_FAMILY="debian" ;;
        debian) OS_FAMILY="debian" ;;
        *)
            log_fatal "Unsupported OS: ${OS_ID}. Only Ubuntu and Debian are supported."
            ;;
    esac

    KERNEL_VERSION="$(uname -r)"

    log_ok "OS detected: ${OS_ID} ${OS_VERSION} (${OS_CODENAME})"
    log_ok "Kernel: ${KERNEL_VERSION}"

    export OS_ID OS_VERSION OS_CODENAME OS_FAMILY KERNEL_VERSION
}

# ---------------------------------------------------------------------------
# OS version validation
# ---------------------------------------------------------------------------
validate_os() {
    local min_version=""
    local supported=0

    case "${OS_ID}" in
        ubuntu)
            # Supported: 20.04, 22.04, 24.04, 26.04 and future LTS
            case "${OS_VERSION}" in
                20.04|22.04|24.04|26.04) supported=1 ;;
                *)
                    # Allow future Ubuntu LTS (even year .04 releases)
                    local major minor
                    major="${OS_VERSION%%.*}"
                    minor="${OS_VERSION##*.}"
                    if [[ "${major}" -ge 20 ]] && [[ "${minor}" == "04" ]] && (( major % 2 == 0 )); then
                        supported=1
                        log_warn "Ubuntu ${OS_VERSION} is not explicitly tested. Proceeding with best-effort support."
                    fi
                    ;;
            esac
            ;;
        debian)
            # Supported: 11, 12, 13 and future
            case "${OS_VERSION}" in
                11|12|13) supported=1 ;;
                *)
                    if [[ "${OS_VERSION}" =~ ^[0-9]+$ ]] && [[ "${OS_VERSION}" -ge 11 ]]; then
                        supported=1
                        log_warn "Debian ${OS_VERSION} is not explicitly tested. Proceeding with best-effort support."
                    fi
                    ;;
            esac
            ;;
    esac

    if [[ "${supported}" -eq 0 ]]; then
        log_fatal "Unsupported OS version: ${OS_ID} ${OS_VERSION}. Supported: Ubuntu 20.04/22.04/24.04/26.04+, Debian 11/12/13+"
    fi

    log_ok "OS version validated: ${OS_ID} ${OS_VERSION}"
}

# ---------------------------------------------------------------------------
# Architecture detection
# ---------------------------------------------------------------------------
detect_architecture() {
    ARCH="$(uname -m)"

    case "${ARCH}" in
        x86_64)  ARCH="amd64"  ;;
        aarch64) ARCH="arm64"  ;;
        armv7l)  ARCH="armv7"  ;;
        *)
            log_warn "Architecture ${ARCH} may not be fully supported."
            ;;
    esac

    log_ok "Architecture: ${ARCH}"
    export ARCH
}

# ---------------------------------------------------------------------------
# Virtualization detection
# ---------------------------------------------------------------------------
detect_virtualization() {
    VIRT_TYPE="none"
    IS_CONTAINER=0

    # Try systemd-detect-virt first
    if command -v systemd-detect-virt &>/dev/null; then
        VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo 'none')"
    fi

    # Fallback detection
    if [[ "${VIRT_TYPE}" == "none" ]]; then
        if [[ -f /proc/1/environ ]] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
            VIRT_TYPE="lxc"
        elif [[ -f /.dockerenv ]]; then
            VIRT_TYPE="docker"
        elif grep -q "hypervisor" /proc/cpuinfo 2>/dev/null; then
            VIRT_TYPE="kvm"
        fi
    fi

    case "${VIRT_TYPE}" in
        lxc|lxc-libvirt|openvz|docker|podman|container-other)
            IS_CONTAINER=1
            log_warn "Container environment detected: ${VIRT_TYPE}"
            log_warn "Some features (BBR, WireGuard kernel module) may not be available."
            ;;
        kvm|qemu|vmware|hyperv|xen|microsoft)
            log_ok "Virtualization: ${VIRT_TYPE} (KVM/VM)"
            ;;
        none)
            log_ok "Virtualization: bare metal"
            ;;
        *)
            log_warn "Unknown virtualization: ${VIRT_TYPE}"
            ;;
    esac

    export VIRT_TYPE IS_CONTAINER
}

# ---------------------------------------------------------------------------
# Network detection
# ---------------------------------------------------------------------------
detect_network() {
    # IPv4
    SERVER_IPV4=""
    local ipv4_sources=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://checkip.amazonaws.com"
    )
    for src in "${ipv4_sources[@]}"; do
        local ip
        ip="$(curl -4 -s --connect-timeout 5 --max-time 10 "${src}" 2>/dev/null | tr -d '[:space:]')"
        if [[ "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            SERVER_IPV4="${ip}"
            break
        fi
    done

    # IPv6
    SERVER_IPV6=""
    local ipv6_sources=(
        "https://api6.ipify.org"
        "https://ipv6.icanhazip.com"
    )
    for src in "${ipv6_sources[@]}"; do
        local ip
        ip="$(curl -6 -s --connect-timeout 5 --max-time 10 "${src}" 2>/dev/null | tr -d '[:space:]')"
        if [[ "${ip}" =~ : ]]; then
            SERVER_IPV6="${ip}"
            break
        fi
    done

    if [[ -z "${SERVER_IPV4}" && -z "${SERVER_IPV6}" ]]; then
        log_fatal "Could not detect server IP address. Check internet connectivity."
    fi

    log_ok "IPv4: ${SERVER_IPV4:-N/A}"
    log_ok "IPv6: ${SERVER_IPV6:-N/A}"

    export SERVER_IPV4 SERVER_IPV6
}

# ---------------------------------------------------------------------------
# Internet connectivity check
# ---------------------------------------------------------------------------
check_internet() {
    local test_hosts=("8.8.8.8" "1.1.1.1" "google.com")
    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 3 "${host}" &>/dev/null 2>&1; then
            return 0
        fi
    done
    # Try curl as fallback
    if curl -s --connect-timeout 5 https://google.com &>/dev/null; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Get primary network interface
# ---------------------------------------------------------------------------
get_primary_interface() {
    ip route | awk '/default/{print $5; exit}'
}

# ---------------------------------------------------------------------------
# Get local IP
# ---------------------------------------------------------------------------
get_local_ip() {
    ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}

# ---------------------------------------------------------------------------
# Xray binary URL by OS/arch
# ---------------------------------------------------------------------------
get_xray_download_url() {
    local version="${1:-latest}"
    local base="https://github.com/XTLS/Xray-core/releases"

    if [[ "${version}" == "latest" ]]; then
        version="$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
            | jq -r '.tag_name' 2>/dev/null || echo 'v1.8.4')"
    fi

    local arch_str=""
    case "${ARCH}" in
        amd64) arch_str="64" ;;
        arm64) arch_str="arm64-v8a" ;;
        armv7) arch_str="arm32-v7a" ;;
        *) arch_str="64" ;;
    esac

    echo "${base}/download/${version}/Xray-linux-${arch_str}.zip"
}

# ---------------------------------------------------------------------------
# Hysteria2 binary URL
# ---------------------------------------------------------------------------
get_hysteria2_download_url() {
    local base="https://github.com/apernet/hysteria/releases/latest/download"
    local arch_str=""
    case "${ARCH}" in
        amd64) arch_str="amd64" ;;
        arm64) arch_str="arm64" ;;
        *)     arch_str="amd64" ;;
    esac
    echo "${base}/hysteria-linux-${arch_str}"
}
