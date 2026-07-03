#!/usr/bin/env bash
# =============================================================================
# menu.sh - Interactive management menu
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
MODULES_DIR="${SCRIPT_DIR}/modules"
LOGS_DIR="${SCRIPT_DIR}/logs"

# Source libraries
# shellcheck source=lib/colors.sh
source "${LIB_DIR}/colors.sh"
# shellcheck source=lib/logger.sh
source "${LIB_DIR}/logger.sh"
# shellcheck source=lib/utils.sh
source "${LIB_DIR}/utils.sh"
# shellcheck source=lib/detect.sh
source "${LIB_DIR}/detect.sh"
# shellcheck source=lib/validate.sh
source "${LIB_DIR}/validate.sh"

LOG_FILE="/var/log/vpn-manager/menu.log"

# Load branding
if [[ -f /etc/vpn-manager/branding.conf ]]; then
    # shellcheck source=/dev/null
    source /etc/vpn-manager/branding.conf
fi
BRAND_MENU_TITLE="${BRAND_MENU_TITLE:-VPN & SSH Management Suite}"

# Detect OS if not already detected
[[ -z "${OS_ID:-}" ]] && detect_os 2>/dev/null || true

# Get server IP — try interface first (fast, no DNS needed), then public IP services
if [[ -z "${SERVER_IPV4:-}" ]]; then
    SERVER_IPV4="$(ip route get 8.8.8.8 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
fi
if [[ -z "${SERVER_IPV4:-}" ]]; then
    SERVER_IPV4="$(curl -4 -s --connect-timeout 4 --max-time 6 \
        https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
fi
SERVER_IPV4="${SERVER_IPV4:-N/A}"

# Root check
if [[ "${EUID}" -ne 0 ]]; then
    echo "This menu must be run as root. Use: sudo bash menu.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# Source a module safely
# ---------------------------------------------------------------------------
load_module() {
    local module="$1"
    local module_file="${MODULES_DIR}/${module}.sh"
    if [[ -f "${module_file}" ]]; then
        # shellcheck source=/dev/null
        source "${module_file}"
    else
        log_error "Module not found: ${module_file}"
        press_enter
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Print service status bar (shown in every menu header)
# ---------------------------------------------------------------------------
print_service_bar() {
    local services=(
        "ssh:SSH"
        "dropbear:Dropbear"
        "nginx:Nginx"
        "xray:Xray"
        "wg-quick@wg0:WireGuard"
        "fail2ban:Fail2Ban"
    )

    local line="  "
    for entry in "${services[@]}"; do
        local svc="${entry%%:*}"
        local label="${entry##*:}"
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            line+="${GREEN}●${RESET} ${WHITE}${label}${RESET}  "
        else
            line+="${RED}●${RESET} ${GRAY}${label}${RESET}  "
        fi
    done
    echo -e "${line}"
}

# ---------------------------------------------------------------------------
# Print main menu header
# ---------------------------------------------------------------------------
print_menu_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    printf "  ║  %-56s  ║\n" "${BRAND_MENU_TITLE}"
    echo "  ╠══════════════════════════════════════════════════════════╣"
    printf "  ║  %-20s  %-33s║\n" "IP: ${SERVER_IPV4:-N/A}" "$(date '+%Y-%m-%d %H:%M')"
    echo "  ╠══════════════════════════════════════════════════════════╣"
    echo -e "${RESET}"
    print_service_bar
    echo -e "${CYAN}  ╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

# ===========================================================================
# MAIN MENU
# ===========================================================================
main_menu() {
    while true; do
        print_menu_header
        print_color "${CYAN}" "  ┌─────────────────────────────────────────────────────────┐"
        print_color "${CYAN}" "  │                    MAIN MENU                            │"
        print_color "${CYAN}" "  └─────────────────────────────────────────────────────────┘"
        echo ""
        print_menu_item "1"  "System Information"
        print_menu_item "2"  "Service Status"
        print_menu_item "3"  "SSH User Management  ▶"
        print_menu_item "4"  "Xray / VPN Users     ▶"
        print_menu_item "5"  "WireGuard            ▶"
        print_menu_item "6"  "SSL / Domain         ▶"
        print_menu_item "7"  "Security             ▶"
        print_menu_item "8"  "Monitoring           ▶"
        print_menu_item "9"  "Backup & Restore     ▶"
        print_menu_item "10" "Branding & Settings  ▶"
        print_menu_item "11" "Updates              ▶"
        print_menu_item "12" "Restart Services"
        print_menu_item "13" "View Logs"
        print_menu_item "14" "Reboot VPS"
        print_menu_item "15" "Shutdown VPS"
        print_menu_item "16" "Uninstall"
        echo ""
        print_menu_item "0"  "Exit"
        echo ""
        print_separator "-" 60 "${GRAY}"

        read -rp "$(echo -e "  ${CYAN}Select option: ${RESET}")" choice

        case "${choice}" in
            1)  menu_system_info ;;
            2)  menu_service_status ;;
            3)  menu_ssh ;;
            4)  menu_xray ;;
            5)  menu_wireguard ;;
            6)  menu_ssl ;;
            7)  menu_security ;;
            8)  menu_monitoring ;;
            9)  menu_backup ;;
            10) menu_branding ;;
            11) menu_updates ;;
            12) menu_restart_services ;;
            13) menu_view_logs ;;
            14) menu_reboot ;;
            15) menu_shutdown ;;
            16) menu_uninstall ;;
            0)  echo -e "\n${GREEN}  Goodbye!${RESET}\n"; exit 0 ;;
            *)  echo -e "\n${RED}  Invalid option.${RESET}"; sleep 1 ;;
        esac
    done
}

# ===========================================================================
# SUBMENUS
# ===========================================================================

# ---------------------------------------------------------------------------
# System Info
# ---------------------------------------------------------------------------
menu_system_info() {
    load_module "monitoring" || return
    monitoring_show_system_info
    press_enter
}

# ---------------------------------------------------------------------------
# Service Status
# ---------------------------------------------------------------------------
menu_service_status() {
    load_module "monitoring" || return
    monitoring_show_services
    press_enter
}

# ---------------------------------------------------------------------------
# SSH Menu
# ---------------------------------------------------------------------------
menu_ssh() {
    load_module "ssh" || return

    while true; do
        print_menu_header
        print_color "${CYAN}" "  SSH User Management"
        print_separator "-" 60 "${GRAY}"
        echo ""
        print_menu_item "1"  "Create SSH User"
        print_menu_item "2"  "Delete SSH User"
        print_menu_item "3"  "Lock User"
        print_menu_item "4"  "Unlock User"
        print_menu_item "5"  "Reset Password"
        print_menu_item "6"  "Extend User Expiry"
        print_menu_item "7"  "List All Users"
        print_menu_item "8"  "Online Users"
        print_menu_item "9"  "Disconnect User"
        print_menu_item "10" "Show Expiry Dates"
        print_menu_item "11" "Edit SSH Banner"
        print_menu_item "12" "Edit MOTD"
        print_menu_item "0"  "Back"
        echo ""

        read -rp "$(echo -e "  ${CYAN}Select option: ${RESET}")" choice

        case "${choice}" in
            1)
                echo ""
                local u days ml pass
                u="$(prompt_required "Username")"
                read -rsp "$(echo -e "  ${CYAN}Password (leave blank to auto-generate): ${RESET}")" pass
                echo ""
                days="$(prompt_with_default "Days until expiry" "30")"
                ml="$(prompt_with_default "Max simultaneous logins" "2")"
                ssh_create_user "${u}" "${pass}" "${days}" "${ml}"
                press_enter
                ;;
            2)
                echo ""
                local u
                u="$(prompt_required "Username to delete")"
                if confirm_action "Delete user ${u}?"; then
                    ssh_delete_user "${u}"
                fi
                press_enter
                ;;
            3)
                echo ""
                local u
                u="$(prompt_required "Username to lock")"
                ssh_lock_user "${u}"
                press_enter
                ;;
            4)
                echo ""
                local u
                u="$(prompt_required "Username to unlock")"
                ssh_unlock_user "${u}"
                press_enter
                ;;
            5)
                echo ""
                local u
                u="$(prompt_required "Username")"
                ssh_reset_password "${u}"
                press_enter
                ;;
            6)
                echo ""
                local u days
                u="$(prompt_required "Username")"
                days="$(prompt_with_default "Additional days" "30")"
                ssh_extend_user "${u}" "${days}"
                press_enter
                ;;
            7)  ssh_list_users; press_enter ;;
            8)  ssh_online_users; press_enter ;;
            9)
                echo ""
                local u
                u="$(prompt_required "Username to disconnect")"
                ssh_disconnect_user "${u}"
                press_enter
                ;;
            10) ssh_show_expiry; press_enter ;;
            11)
                load_module "branding" || break
                branding_edit_banner
                ;;
            12)
                load_module "branding" || break
                branding_edit_motd
                ;;
            0)  break ;;
            *)  echo -e "\n${RED}  Invalid option.${RESET}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Xray Menu
# ---------------------------------------------------------------------------
menu_xray() {
    load_module "xray" || return

    while true; do
        print_menu_header
        print_color "${CYAN}" "  Xray / VPN Protocol Users"
        print_separator "-" 60 "${GRAY}"
        echo ""
        print_menu_item "1"  "Create VLESS User"
        print_menu_item "2"  "Delete VLESS User"
        print_menu_item "3"  "Create VMess User"
        print_menu_item "4"  "Delete VMess User"
        print_menu_item "5"  "Create Trojan User"
        print_menu_item "6"  "Delete Trojan User"
        print_menu_item "7"  "Create Shadowsocks User"
        print_menu_item "8"  "Delete Shadowsocks User"
        print_menu_item "9"  "Extend User"
        print_menu_item "10" "List All Xray Users"
        print_menu_item "11" "Update Xray"
        print_menu_item "0"  "Back"
        echo ""

        read -rp "$(echo -e "  ${CYAN}Select option: ${RESET}")" choice

        case "${choice}" in
            1)
                echo ""
                local u days tl
                u="$(prompt_required "Username")"
                days="$(prompt_with_default "Days" "30")"
                tl="$(prompt_with_default "Traffic limit (0=unlimited, e.g. 10G)" "0")"
                xray_create_vless "${u}" "${days}" "${tl}"
                press_enter
                ;;
            2)
                echo ""
                local u
                u="$(prompt_required "Username to delete")"
                if confirm_action "Delete VLESS user ${u}?"; then
                    xray_delete_user "${u}" "vless"
                fi
                press_enter
                ;;
            3)
                echo ""
                local u days tl
                u="$(prompt_required "Username")"
                days="$(prompt_with_default "Days" "30")"
                tl="$(prompt_with_default "Traffic limit" "0")"
                xray_create_vmess "${u}" "${days}" "${tl}"
                press_enter
                ;;
            4)
                echo ""
                local u
                u="$(prompt_required "Username")"
                if confirm_action "Delete VMess user ${u}?"; then
                    xray_delete_user "${u}" "vmess"
                fi
                press_enter
                ;;
            5)
                echo ""
                local u days tl
                u="$(prompt_required "Username")"
                days="$(prompt_with_default "Days" "30")"
                tl="$(prompt_with_default "Traffic limit" "0")"
                xray_create_trojan "${u}" "${days}" "${tl}"
                press_enter
                ;;
            6)
                echo ""
                local u
                u="$(prompt_required "Username")"
                if confirm_action "Delete Trojan user ${u}?"; then
                    xray_delete_user "${u}" "trojan"
                fi
                press_enter
                ;;
            7)
                echo ""
                local u days tl
                u="$(prompt_required "Username")"
                days="$(prompt_with_default "Days" "30")"
                tl="$(prompt_with_default "Traffic limit" "0")"
                xray_create_shadowsocks "${u}" "${days}" "${tl}"
                press_enter
                ;;
            8)
                echo ""
                local u
                u="$(prompt_required "Username")"
                if confirm_action "Delete Shadowsocks user ${u}?"; then
                    xray_delete_user "${u}" "shadowsocks"
                fi
                press_enter
                ;;
            9)
                echo ""
                local u days proto
                u="$(prompt_required "Username")"
                days="$(prompt_with_default "Additional days" "30")"
                proto="$(prompt_with_default "Protocol (leave empty for all)" "")"
                xray_extend_user "${u}" "${days}" "${proto}"
                press_enter
                ;;
            10) xray_list_users; press_enter ;;
            11) xray_update; press_enter ;;
            0)  break ;;
            *)  echo -e "\n${RED}  Invalid option.${RESET}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# WireGuard Menu
# ---------------------------------------------------------------------------
menu_wireguard() {
    load_module "wireguard" || return

    while true; do
        print_menu_header
        print_color "${CYAN}" "  WireGuard VPN"
        print_separator "-" 60 "${GRAY}"
        echo ""
        print_menu_item "1" "Add WireGuard Client"
        print_menu_item "2" "Remove WireGuard Client"
        print_menu_item "3" "WireGuard Status"
        print_menu_item "0" "Back"
        echo ""

        read -rp "$(echo -e "  ${CYAN}Select option: ${RESET}")" choice

        case "${choice}" in
            1)
                echo ""
                local u days
                u="$(prompt_required "Client username")"
                days="$(prompt_with_default "Days" "30")"
                wg_add_client "${u}" "${days}"
                press_enter
                ;;
            2)
                echo ""
                local u
                u="$(prompt_required "Client username")"
                if confirm_action "Remove WireGuard client ${u}?"; then
                    wg_remove_client "${u}"
                fi
                press_enter
                ;;
            3) wg_status; press_enter ;;
            0) break ;;
            *)  echo -e "\n${RED}  Invalid option.${RESET}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# SSL Menu
# ---------------------------------------------------------------------------
menu_ssl() {
    load_module "ssl" || return

    while true; do
        print_menu_header
        print_color "${CYAN}" "  SSL / Domain Management"
        print_separator "-" 60 "${GRAY}"
        echo ""
        print_menu_item "1" "Setup SSL for Domain"
        print_menu_item "2" "Change Domain"
        print_menu_item "3" "Add Additional Domain"
        print_menu_item "4" "Renew Certificates"
        print_menu_item "5" "SSL Status"
        print_menu_item "0" "Back"
        echo ""

        read -rp "$(echo -e "  ${CYAN}Select option: ${RESET}")" choice

        case "${choice}" in
    1)
                echo ""
                local d email
                d="$(prompt_required "Enter your domain (e.g. vpn.example.com)")"
                email="$(prompt_with_default "Email for SSL notifications" "admin@${d}")"
                ssl_setup_domain "${d}" "${email}"
                press_enter
                ;;
            2)
                echo ""
                local d
                d="$(prompt_required "New domain")"
                ssl_change_domain "${d}"
                press_enter
                ;;
            3)
                echo ""
                local d
                d="$(prompt_required "Additional domain")"
                ssl_add_domain "${d}"
                press_enter
                ;;
            4) ssl_renew; press_enter ;;
            5) ssl_status; press_enter ;;
            0) break ;;
            *)  echo -e "\n${RED}  Invalid option.${RESET}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Security Menu
# ---------------------------------------------------------------------------
menu_security() {
    load_module "security" || return
    load_module "bbr" || return

    while true; do
        print_menu_header
        print_color "${CYAN}" "  Security"
        print_separator "-" 60 "${GRAY}"
        echo ""
        print_menu_item "1" "Security Status"
        print_menu_item "2" "Enable BBR"
        print_menu_item "3" "Disable BBR"
        print_menu_item "4" "BBR Status"
        print_menu_item "5" "Open Port in Firewall"
        print_menu_item "6" "Close Port in Firewall"
        print_menu_item "7" "Unban All IPs"
        print_menu_item "0" "Back"
        echo ""

        read -rp "$(echo -e "  ${CYAN}Select option: ${RESET}")" choice

        case "${choice}" in
            1) security_show_status; press_enter ;;
            2) module_enable_bbr; press_enter ;;
            3) module_disable_bbr; press_enter ;;
            4) bbr_status; press_enter ;;
            5)
                echo ""
                local p proto
                p="$(prompt_required "Port number")"
                proto="$(prompt_with_default "Protocol (tcp/udp)" "tcp")"
                security_open_port "${p}" "${proto}"
                press_enter
                ;;
            6)
                echo ""
                local p proto
                p="$(prompt_required "Port number")"
                proto="$(prompt_with_default "Protocol (tcp/udp)" "tcp")"
                security_close_port "${p}" "${proto}"
                press_enter
                ;;
            7)
                fail2ban-client unban --all 2>/dev/null && \
                    log_ok "All IPs unbanned" || \
                    log_warn "Nothing to unban"
                press_enter
                ;;
            0) break ;;
            *)  echo -e "\n${RED}  Invalid option.${RESET}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Monitoring Menu
# ---------------------------------------------------------------------------
menu_monitoring() {
    load_module "monitoring" || return

    while true; do
        print_menu_header
        print_color "${CYAN}" "  Monitoring"
        print_separator "-" 60 "${GRAY}"
        echo ""
        print_menu_item "1" "System Information"
        print_menu_item "2" "CPU Usage"
        print_menu_item "3" "RAM Usage"
        print_menu_item "4" "Disk Usage"
        print_menu_item "5" "Bandwidth Usage"
        print_menu_item "6" "Network Information"
        print_menu_item "7" "Speed Test"
        print_menu_item "0" "Back"
        echo ""

        read -rp "$(echo -e "  ${CYAN}Select option: ${RESET}")" choice

        case "${choice}" in
            1) monitoring_show_system_info; press_enter ;;
            2) monitoring_cpu; press_enter ;;
            3) monitoring_ram; press_enter ;;
            4) monitoring_disk; press_enter ;;
            5) monitoring_bandwidth; press_enter ;;
            6) monitoring_network_info; press_enter ;;
            7) monitoring_speedtest; press_enter ;;
            0) break ;;
            *)  echo -e "\n${RED}  Invalid option.${RESET}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Backup Menu
# ---------------------------------------------------------------------------
menu_backup() {
    load_module "backup" || return

    while true; do
        print_menu_header
        print_color "${CYAN}" "  Backup & Restore"
        print_separator "-" 60 "${GRAY}"
        echo ""
        print_menu_item "1" "Create Backup"
        print_menu_item "2" "List Backups"
        print_menu_item "3" "Restore from Backup"
        print_menu_item "4" "Download Backup Info"
        print_menu_item "0" "Back"
        echo ""

        read -rp "$(echo -e "  ${CYAN}Select option: ${RESET}")" choice

        case "${choice}" in
            1)
                local label
                label="$(prompt_with_default "Backup label" "manual")"
                backup_create "${label}"
                press_enter
                ;;
            2) backup_list; press_enter ;;
            3) backup_restore ""; press_enter ;;
            4) backup_download_info ""; press_enter ;;
            0) break ;;
            *)  echo -e "\n${RED}  Invalid option.${RESET}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Branding Menu
# ---------------------------------------------------------------------------
menu_branding() {
    load_module "branding" || return

    while true; do
        print_menu_header
        print_color "${CYAN}" "  Branding & Settings"
        print_separator "-" 60 "${GRAY}"
        echo ""
        print_menu_item "1" "Edit Server Branding"
        print_menu_item "2" "Edit SSH Banner"
        print_menu_item "3" "Edit MOTD"
        print_menu_item "0" "Back"
        echo ""

        read -rp "$(echo -e "  ${CYAN}Select option: ${RESET}")" choice

        case "${choice}" in
            1) branding_edit_interactive ;;
            2) branding_edit_banner ;;
            3) branding_edit_motd ;;
            0) break ;;
            *)  echo -e "\n${RED}  Invalid option.${RESET}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Updates Menu
# ---------------------------------------------------------------------------
menu_updates() {
    while true; do
        print_menu_header
        print_color "${CYAN}" "  Updates"
        print_separator "-" 60 "${GRAY}"
        echo ""
        print_menu_item "1" "Update System Packages"
        print_menu_item "2" "Update Xray-core"
        print_menu_item "3" "Update VPN Manager Panel"
        print_menu_item "0" "Back"
        echo ""

        read -rp "$(echo -e "  ${CYAN}Select option: ${RESET}")" choice

        case "${choice}" in
            1)
                log_info "Updating system packages..."
                apt-get update -qq && apt-get upgrade -y -qq && log_ok "System updated"
                press_enter
                ;;
            2)
                load_module "xray" || break
                xray_update
                press_enter
                ;;
            3)
                if [[ -f "${SCRIPT_DIR}/update.sh" ]]; then
                    bash "${SCRIPT_DIR}/update.sh"
                else
                    log_warn "update.sh not found"
                fi
                press_enter
                ;;
            0) break ;;
            *)  echo -e "\n${RED}  Invalid option.${RESET}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Restart Services
# ---------------------------------------------------------------------------
menu_restart_services() {
    echo ""
    print_header "Restart Services"
    echo ""

    local services=("nginx" "xray" "ssh" "dropbear" "fail2ban"
                     "wg-quick@wg0" "hysteria-server")

    for svc in "${services[@]}"; do
        if systemctl is-enabled "${svc}" &>/dev/null 2>&1; then
            log_info "Restarting: ${svc}"
            systemctl restart "${svc}" 2>/dev/null && \
                log_ok "Restarted: ${svc}" || \
                log_warn "Could not restart: ${svc}"
        fi
    done

    log_ok "All services restarted"
    press_enter
}

# ---------------------------------------------------------------------------
# View Logs
# ---------------------------------------------------------------------------
menu_view_logs() {
    while true; do
        print_menu_header
        print_color "${CYAN}" "  View Logs"
        print_separator "-" 60 "${GRAY}"
        echo ""
        print_menu_item "1" "VPN Manager Log"
        print_menu_item "2" "Activity Log"
        print_menu_item "3" "SSH Auth Log"
        print_menu_item "4" "Nginx Access Log"
        print_menu_item "5" "Nginx Error Log"
        print_menu_item "6" "Xray Log"
        print_menu_item "7" "Fail2Ban Log"
        print_menu_item "0" "Back"
        echo ""

        read -rp "$(echo -e "  ${CYAN}Select option: ${RESET}")" choice

        local log_file=""
        case "${choice}" in
            1) log_file="/var/log/vpn-manager/vpn-manager.log" ;;
            2) log_file="/var/log/vpn-manager/activity.log" ;;
            3) log_file="/var/log/auth.log" ;;
            4) log_file="/var/log/nginx/access.log" ;;
            5) log_file="/var/log/nginx/error.log" ;;
            6) log_file="/var/log/xray/error.log" ;;
            7) log_file="/var/log/fail2ban.log" ;;
            0) break ;;
            *)  echo -e "\n${RED}  Invalid option.${RESET}"; sleep 1; continue ;;
        esac

        if [[ -n "${log_file}" ]]; then
            if [[ -f "${log_file}" ]]; then
                clear
                echo -e "${CYAN}  Log: ${log_file}${RESET}"
                print_separator "-" 60 "${GRAY}"
                tail -50 "${log_file}" | less -R 2>/dev/null || tail -50 "${log_file}"
            else
                log_warn "Log file not found: ${log_file}"
                sleep 1
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
# Reboot
# ---------------------------------------------------------------------------
menu_reboot() {
    echo ""
    if confirm_action "Reboot the VPS?"; then
        log_warn "Rebooting in 5 seconds..."
        log_activity "SYSTEM_REBOOT" "initiated from menu"
        sleep 5
        reboot
    fi
}

# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------
menu_shutdown() {
    echo ""
    if confirm_action "Shutdown the VPS?"; then
        log_warn "Shutting down in 5 seconds..."
        log_activity "SYSTEM_SHUTDOWN" "initiated from menu"
        sleep 5
        shutdown -h now
    fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
menu_uninstall() {
    echo ""
    print_color "${RED}" "  ⚠  WARNING: This will completely remove VPN Manager!"
    if confirm_action "Are you absolutely sure?"; then
        if confirm_action "Confirm UNINSTALL - all configs will be deleted?"; then
            if [[ -f "${SCRIPT_DIR}/uninstall.sh" ]]; then
                bash "${SCRIPT_DIR}/uninstall.sh"
            else
                log_error "uninstall.sh not found"
            fi
        fi
    fi
    press_enter
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main_menu
