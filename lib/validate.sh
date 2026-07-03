#!/usr/bin/env bash
# =============================================================================
# lib/validate.sh - Input validation functions
# =============================================================================

# ---------------------------------------------------------------------------
# Username validation
# ---------------------------------------------------------------------------
validate_username() {
    local username="$1"

    if [[ -z "${username}" ]]; then
        log_error "Username cannot be empty"
        return 1
    fi

    if [[ ${#username} -lt 3 || ${#username} -gt 32 ]]; then
        log_error "Username must be 3-32 characters"
        return 1
    fi

    if [[ ! "${username}" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        log_error "Username must start with a letter and contain only lowercase letters, numbers, hyphens, or underscores"
        return 1
    fi

    # Reserved usernames
    local reserved=("root" "admin" "daemon" "bin" "sys" "sync" "games" "man"
                     "lp" "mail" "news" "uucp" "proxy" "www-data" "backup"
                     "list" "irc" "gnats" "nobody" "systemd-network" "mysql"
                     "nginx" "xray" "vpn")
    for r in "${reserved[@]}"; do
        if [[ "${username}" == "${r}" ]]; then
            log_error "Username '${username}' is reserved"
            return 1
        fi
    done

    return 0
}

# ---------------------------------------------------------------------------
# Password validation
# ---------------------------------------------------------------------------
validate_password() {
    local password="$1"
    local min_length="${2:-8}"

    if [[ ${#password} -lt ${min_length} ]]; then
        log_error "Password must be at least ${min_length} characters"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Port validation
# ---------------------------------------------------------------------------
validate_port() {
    local port="$1"
    local allow_privileged="${2:-0}"

    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        log_error "Port must be a number"
        return 1
    fi

    if [[ "${allow_privileged}" -eq 0 && "${port}" -lt 1024 ]]; then
        log_error "Port must be >= 1024 (use allow_privileged=1 to override)"
        return 1
    fi

    if [[ "${port}" -gt 65535 ]]; then
        log_error "Port must be <= 65535"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Domain validation
# ---------------------------------------------------------------------------
validate_domain() {
    local domain="$1"

    if [[ -z "${domain}" ]]; then
        log_error "Domain cannot be empty"
        return 1
    fi

    if ! [[ "${domain}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid domain format: ${domain}"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# IP address validation
# ---------------------------------------------------------------------------
validate_ip() {
    local ip="$1"

    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra parts <<< "${ip}"
        for part in "${parts[@]}"; do
            if [[ "${part}" -gt 255 ]]; then
                log_error "Invalid IPv4: ${ip}"
                return 1
            fi
        done
        return 0
    fi

    # IPv6 check (simplified)
    if [[ "${ip}" =~ : ]]; then
        return 0
    fi

    log_error "Invalid IP address: ${ip}"
    return 1
}

# ---------------------------------------------------------------------------
# Traffic limit validation (e.g. 10G, 500M, 1T)
# ---------------------------------------------------------------------------
validate_traffic_limit() {
    local limit="$1"

    if [[ "${limit}" =~ ^[0-9]+[GgMmTtKk]?[Bb]?$ ]]; then
        return 0
    fi

    log_error "Invalid traffic limit format: ${limit}. Use: 10G, 500M, 1T, 0 (unlimited)"
    return 1
}

# ---------------------------------------------------------------------------
# Days validation
# ---------------------------------------------------------------------------
validate_days() {
    local days="$1"

    if [[ ! "${days}" =~ ^[0-9]+$ ]]; then
        log_error "Days must be a positive integer"
        return 1
    fi

    if [[ "${days}" -lt 1 || "${days}" -gt 36500 ]]; then
        log_error "Days must be between 1 and 36500"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# UUID validation
# ---------------------------------------------------------------------------
validate_uuid() {
    local uuid="$1"
    if [[ "${uuid}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        return 0
    fi
    log_error "Invalid UUID format: ${uuid}"
    return 1
}

# ---------------------------------------------------------------------------
# Email validation
# ---------------------------------------------------------------------------
validate_email() {
    local email="$1"
    if [[ "${email}" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    log_error "Invalid email format: ${email}"
    return 1
}

# ---------------------------------------------------------------------------
# Confirm user exists
# ---------------------------------------------------------------------------
user_exists() {
    id "$1" &>/dev/null
}

# ---------------------------------------------------------------------------
# Confirm user is a VPN user (not system)
# ---------------------------------------------------------------------------
is_vpn_user() {
    local username="$1"
    local user_db="/etc/vpn-manager/users/${username}.conf"
    [[ -f "${user_db}" ]]
}

# ---------------------------------------------------------------------------
# Normalize traffic bytes
# ---------------------------------------------------------------------------
normalize_bytes() {
    local value="$1"
    local unit="${value: -1}"
    local num="${value%[GgMmTtKkBb]}"

    case "${unit,,}" in
        k) echo "$(( num * 1024 ))" ;;
        m) echo "$(( num * 1048576 ))" ;;
        g) echo "$(( num * 1073741824 ))" ;;
        t) echo "$(( num * 1099511627776 ))" ;;
        *) echo "${value}" ;;
    esac
}
