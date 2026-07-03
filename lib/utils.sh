#!/usr/bin/env bash
# =============================================================================
# lib/utils.sh - General utility functions
# =============================================================================

# ---------------------------------------------------------------------------
# UUID generation
# ---------------------------------------------------------------------------
generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || \
        openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
    fi
}

# ---------------------------------------------------------------------------
# Random port selection
# ---------------------------------------------------------------------------
get_random_port() {
    local min="${1:-10000}"
    local max="${2:-65535}"
    local port

    for _ in {1..50}; do
        port=$(( RANDOM % (max - min + 1) + min ))
        if ! ss -tlnp | grep -q ":${port} "; then
            echo "${port}"
            return 0
        fi
    done

    # Fallback sequential search
    for (( p=min; p<=max; p++ )); do
        if ! ss -tlnp | grep -q ":${p} "; then
            echo "${p}"
            return 0
        fi
    done

    log_error "Could not find an available port in range ${min}-${max}"
    return 1
}

# ---------------------------------------------------------------------------
# Password generation
# ---------------------------------------------------------------------------
generate_password() {
    local length="${1:-16}"
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c "${length}" 2>/dev/null || \
    openssl rand -base64 "${length}" | head -c "${length}"
}

generate_simple_password() {
    local length="${1:-12}"
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${length}" 2>/dev/null || \
    openssl rand -base64 "${length}" | tr -dc 'A-Za-z0-9' | head -c "${length}"
}

# ---------------------------------------------------------------------------
# File backup helper
# ---------------------------------------------------------------------------
backup_file() {
    local file="$1"
    local backup_dir="${2:-/etc/vpn-manager/backups}"

    if [[ -f "${file}" ]]; then
        mkdir -p "${backup_dir}"
        local backup_name
        backup_name="${backup_dir}/$(basename "${file}").$(date +%Y%m%d_%H%M%S).bak"
        cp -p "${file}" "${backup_name}"
        log_info "Backed up: ${file} → ${backup_name}"
        echo "${backup_name}"
    fi
}

# ---------------------------------------------------------------------------
# File permission setter
# ---------------------------------------------------------------------------
secure_file() {
    local file="$1"
    local owner="${2:-root:root}"
    local perms="${3:-600}"

    if [[ -f "${file}" ]]; then
        chown "${owner}" "${file}"
        chmod "${perms}" "${file}"
    fi
}

# ---------------------------------------------------------------------------
# Service management helpers
# ---------------------------------------------------------------------------
service_enable_start() {
    local service="$1"
    systemctl daemon-reload
    systemctl enable "${service}" 2>/dev/null || true
    systemctl start "${service}" 2>/dev/null || true

    if systemctl is-active --quiet "${service}"; then
        log_ok "Service enabled and started: ${service}"
        return 0
    else
        log_warn "Service may not have started: ${service}"
        return 1
    fi
}

service_restart() {
    local service="$1"
    systemctl restart "${service}" 2>/dev/null && \
        log_ok "Service restarted: ${service}" || \
        log_warn "Failed to restart: ${service}"
}

service_reload() {
    local service="$1"
    systemctl reload "${service}" 2>/dev/null || \
    systemctl restart "${service}" 2>/dev/null && \
        log_ok "Service reloaded: ${service}" || \
        log_warn "Failed to reload: ${service}"
}

service_status() {
    local service="$1"
    if systemctl is-active --quiet "${service}"; then
        echo "running"
    elif systemctl is-enabled --quiet "${service}" 2>/dev/null; then
        echo "stopped"
    else
        echo "disabled"
    fi
}

# ---------------------------------------------------------------------------
# Package helpers
# ---------------------------------------------------------------------------
pkg_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q '^ii'
}

pkg_install() {
    local pkg="$1"
    if ! pkg_installed "${pkg}"; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkg}" 2>&1 | \
            tee -a "${LOG_FILE:-/dev/null}" || return 1
        log_ok "Installed: ${pkg}"
    fi
}

# ---------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------
port_open() {
    local port="$1"
    local proto="${2:-tcp}"
    ss -${proto:0:1}lnp | grep -q ":${port} "
}

wait_for_port() {
    local host="$1"
    local port="$2"
    local timeout="${3:-30}"
    local count=0

    while ! nc -z "${host}" "${port}" 2>/dev/null; do
        sleep 1
        (( count++ ))
        if [[ "${count}" -ge "${timeout}" ]]; then
            log_warn "Timeout waiting for ${host}:${port}"
            return 1
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# DNS verification
# ---------------------------------------------------------------------------
verify_dns() {
    local domain="$1"
    local expected_ip="${2:-${SERVER_IPV4:-}}"

    local resolved_ip
    resolved_ip="$(dig +short "${domain}" A 2>/dev/null | tail -1 || \
                   host -t A "${domain}" 2>/dev/null | awk '/has address/{print $NF}' | head -1 || \
                   getent hosts "${domain}" | awk '{print $1}' | head -1)"

    if [[ -z "${resolved_ip}" ]]; then
        log_warn "DNS: ${domain} could not be resolved"
        return 1
    fi

    if [[ "${resolved_ip}" == "${expected_ip}" ]]; then
        log_ok "DNS: ${domain} → ${resolved_ip} ✓"
        return 0
    else
        log_warn "DNS mismatch: ${domain} → ${resolved_ip} (expected: ${expected_ip})"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Config file helpers
# ---------------------------------------------------------------------------
set_config_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    local delimiter="${4:-=}"

    if grep -q "^${key}${delimiter}" "${file}" 2>/dev/null; then
        sed -i "s|^${key}${delimiter}.*|${key}${delimiter}${value}|" "${file}"
    else
        echo "${key}${delimiter}${value}" >> "${file}"
    fi
}

get_config_value() {
    local file="$1"
    local key="$2"
    local delimiter="${3:-=}"
    grep "^${key}${delimiter}" "${file}" 2>/dev/null | cut -d"${delimiter}" -f2- | head -1
}

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------
json_get() {
    local file="$1"
    local key="$2"
    jq -r "${key}" "${file}" 2>/dev/null
}

json_set() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp
    tmp="$(mktemp)"
    jq "${key} = ${value}" "${file}" > "${tmp}" && mv "${tmp}" "${file}"
}

# ---------------------------------------------------------------------------
# Download with retry
# ---------------------------------------------------------------------------
download_file() {
    local url="$1"
    local dest="$2"
    local retries="${3:-3}"

    for (( i=1; i<=retries; i++ )); do
        if curl -fsSL --connect-timeout 30 --max-time 120 \
            --retry 2 --retry-delay 3 \
            -o "${dest}" "${url}"; then
            log_ok "Downloaded: $(basename "${dest}")"
            return 0
        fi
        log_warn "Download attempt ${i}/${retries} failed: ${url}"
        sleep 2
    done

    log_error "Failed to download: ${url}"
    return 1
}

# ---------------------------------------------------------------------------
# Get latest GitHub release
# ---------------------------------------------------------------------------
get_github_latest() {
    local repo="$1"  # e.g. "XTLS/Xray-core"
    curl -s "https://api.github.com/repos/${repo}/releases/latest" \
        | jq -r '.tag_name' 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Validate IPv4
# ---------------------------------------------------------------------------
is_valid_ipv4() {
    local ip="$1"
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra parts <<< "${ip}"
    for part in "${parts[@]}"; do
        [[ "${part}" -le 255 ]] || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# Validate domain
# ---------------------------------------------------------------------------
is_valid_domain() {
    local domain="$1"
    [[ "${domain}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# ---------------------------------------------------------------------------
# Human-readable sizes
# ---------------------------------------------------------------------------
human_size() {
    local bytes="$1"
    if [[ "${bytes}" -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ "${bytes}" -lt 1048576 ]]; then
        echo "$(( bytes / 1024 ))KB"
    elif [[ "${bytes}" -lt 1073741824 ]]; then
        echo "$(( bytes / 1048576 ))MB"
    else
        echo "$(( bytes / 1073741824 ))GB"
    fi
}

# ---------------------------------------------------------------------------
# Date helpers
# ---------------------------------------------------------------------------
days_from_now() {
    local days="$1"
    date -d "+${days} days" "+%Y-%m-%d" 2>/dev/null || \
    date -v "+${days}d" "+%Y-%m-%d" 2>/dev/null || \
    echo "$(( $(date +%s) + days * 86400 ))"
}

timestamp_to_date() {
    date -d "@$1" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$1" "+%Y-%m-%d %H:%M:%S"
}

# ---------------------------------------------------------------------------
# Systemd unit installer
# ---------------------------------------------------------------------------
install_systemd_unit() {
    local unit_file="$1"
    local unit_name
    unit_name="$(basename "${unit_file}")"
    local dest="/etc/systemd/system/${unit_name}"

    cp "${unit_file}" "${dest}"
    chmod 644 "${dest}"
    systemctl daemon-reload
    log_ok "Installed systemd unit: ${unit_name}"
}

# ---------------------------------------------------------------------------
# Check if running in interactive terminal
# ---------------------------------------------------------------------------
is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# ---------------------------------------------------------------------------
# Prompt with default
# ---------------------------------------------------------------------------
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local answer

    read -rp "$(echo -e "${CYAN}  ${prompt} [${default}]: ${RESET}")" answer
    echo "${answer:-${default}}"
}

prompt_required() {
    local prompt="$1"
    local answer=""

    while [[ -z "${answer}" ]]; do
        read -rp "$(echo -e "${CYAN}  ${prompt}: ${RESET}")" answer
        if [[ -z "${answer}" ]]; then
            echo -e "${YELLOW}  This field is required.${RESET}"
        fi
    done
    echo "${answer}"
}
