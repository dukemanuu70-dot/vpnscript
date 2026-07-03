#!/usr/bin/env bash
# =============================================================================
# lib/colors.sh - ANSI color definitions and print helpers
# =============================================================================

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
BOLD='\033[1m'
DIM='\033[2m'
UNDERLINE='\033[4m'
BLINK='\033[5m'
RESET='\033[0m'

# Background colors
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'
BG_BLUE='\033[44m'
BG_CYAN='\033[46m'

# ---------------------------------------------------------------------------
# Print helpers
# ---------------------------------------------------------------------------
print_color() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${RESET}"
}

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║         VPN & SSH SERVER MANAGEMENT SUITE v1.0.0        ║"
    echo "  ║              Production-Ready • Secure • Fast           ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

print_separator() {
    local char="${1:--}"
    local width="${2:-60}"
    local color="${3:-${CYAN}}"
    printf "${color}"
    printf '%*s' "${width}" '' | tr ' ' "${char}"
    printf "${RESET}\n"
}

print_header() {
    local title="$1"
    local color="${2:-${CYAN}}"
    echo ""
    print_separator "═" 60 "${color}"
    printf "  ${color}${BOLD}%-56s${RESET}\n" "${title}"
    print_separator "═" 60 "${color}"
}

print_menu_item() {
    local number="$1"
    local label="$2"
    printf "  ${CYAN}[${WHITE}%2s${CYAN}]${RESET} %-40s\n" "${number}" "${label}"
}

print_key_value() {
    local key="$1"
    local value="$2"
    local key_color="${3:-${CYAN}}"
    local val_color="${4:-${WHITE}}"
    printf "  ${key_color}%-20s${RESET}: ${val_color}%s${RESET}\n" "${key}" "${value}"
}

confirm_action() {
    local prompt="${1:-Are you sure?}"
    local default="${2:-n}"
    local answer

    if [[ "${default}" == "y" ]]; then
        read -rp "$(echo -e "${YELLOW}${prompt} [Y/n]: ${RESET}")" answer
        answer="${answer:-y}"
    else
        read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${RESET}")" answer
        answer="${answer:-n}"
    fi

    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

press_enter() {
    echo ""
    read -rp "$(echo -e "${DIM}  Press Enter to continue...${RESET}")" _
}

show_spinner() {
    local pid="$1"
    local message="${2:-Processing}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    while kill -0 "${pid}" 2>/dev/null; do
        local char="${spin:${i}:1}"
        printf "\r  ${CYAN}${char}${RESET} ${message}..."
        (( i = (i + 1) % ${#spin} ))
        sleep 0.1
    done
    printf "\r  ${GREEN}✓${RESET} ${message} done.\n"
}
