#!/usr/bin/env bash
# =============================================================================
# lib/logger.sh - Structured logging system
# =============================================================================

# Ensure colors are loaded
if [[ -z "${RESET:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    GRAY='\033[0;37m'
    BOLD='\033[1m'
    RESET='\033[0m'
fi

# ---------------------------------------------------------------------------
# Log level constants
# ---------------------------------------------------------------------------
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_FATAL=4

# Default log level
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL_INFO}}"

# Log file (can be set externally)
LOG_FILE="${LOG_FILE:-/var/log/vpn-manager/vpn-manager.log}"

# ---------------------------------------------------------------------------
# Internal log writer
# ---------------------------------------------------------------------------
_log_write() {
    local level="$1"
    local color="$2"
    local symbol="$3"
    local message="$4"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local caller_info="${BASH_SOURCE[2]:-unknown}:${BASH_LINENO[1]:-0}"

    # Console output
    echo -e "  ${color}${symbol}${RESET} ${message}"

    # File output (plain text, no ANSI)
    if [[ -n "${LOG_FILE}" ]]; then
        local log_dir
        log_dir="$(dirname "${LOG_FILE}")"
        mkdir -p "${log_dir}" 2>/dev/null || true
        echo "[${timestamp}] [${level}] [${caller_info}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Public log functions
# ---------------------------------------------------------------------------
log_debug() {
    [[ "${LOG_LEVEL}" -le "${LOG_LEVEL_DEBUG}" ]] || return 0
    _log_write "DEBUG" "${GRAY}" "◌" "$*"
}

log_info() {
    [[ "${LOG_LEVEL}" -le "${LOG_LEVEL_INFO}" ]] || return 0
    _log_write "INFO " "${CYAN}" "•" "$*"
}

log_ok() {
    [[ "${LOG_LEVEL}" -le "${LOG_LEVEL_INFO}" ]] || return 0
    _log_write "OK   " "${GREEN}" "✓" "$*"
}

log_warn() {
    [[ "${LOG_LEVEL}" -le "${LOG_LEVEL_WARN}" ]] || return 0
    _log_write "WARN " "${YELLOW}" "⚠" "$*"
}

log_error() {
    [[ "${LOG_LEVEL}" -le "${LOG_LEVEL_ERROR}" ]] || return 0
    _log_write "ERROR" "${RED}" "✗" "$*" >&2
}

log_fatal() {
    _log_write "FATAL" "${RED}${BOLD}" "✗" "$*" >&2
    exit 1
}

log_section() {
    local title="$1"
    echo ""
    echo -e "  ${CYAN}${BOLD}▶ ${title}${RESET}"
    echo -e "  ${CYAN}$(printf '%.0s─' {1..55})${RESET}"
}

log_step() {
    local step="$1"
    local total="$2"
    local desc="$3"
    echo -e "  ${BLUE}[${step}/${total}]${RESET} ${desc}"
}

# ---------------------------------------------------------------------------
# Log rotation helper
# ---------------------------------------------------------------------------
rotate_log() {
    local log_file="${1:-${LOG_FILE}}"
    local max_size_mb="${2:-10}"
    local max_files="${3:-5}"

    if [[ ! -f "${log_file}" ]]; then
        return 0
    fi

    local size_bytes
    size_bytes="$(stat -c%s "${log_file}" 2>/dev/null || echo 0)"
    local size_mb=$(( size_bytes / 1048576 ))

    if [[ "${size_mb}" -ge "${max_size_mb}" ]]; then
        for (( i=max_files-1; i>=1; i-- )); do
            if [[ -f "${log_file}.${i}" ]]; then
                mv "${log_file}.${i}" "${log_file}.$(( i + 1 ))" 2>/dev/null || true
            fi
        done
        mv "${log_file}" "${log_file}.1" 2>/dev/null || true
        touch "${log_file}" 2>/dev/null || true
        log_info "Log rotated: ${log_file}"
    fi
}

# ---------------------------------------------------------------------------
# Activity log (user actions)
# ---------------------------------------------------------------------------
ACTIVITY_LOG="/var/log/vpn-manager/activity.log"

log_activity() {
    local action="$1"
    local details="${2:-}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local operator="${SUDO_USER:-${USER:-root}}"
    mkdir -p "$(dirname "${ACTIVITY_LOG}")" 2>/dev/null || true
    echo "[${timestamp}] [${operator}] ${action} ${details}" >> "${ACTIVITY_LOG}" 2>/dev/null || true
}
