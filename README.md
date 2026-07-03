# VPN & SSH Server Management Suite v1.0.0

**Production-ready, modular, enterprise-grade VPN & SSH management panel.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20|%2022.04%20|%2024.04-orange.svg)](https://ubuntu.com/)
[![Debian](https://img.shields.io/badge/Debian-11%20|%2012%20|%2013-red.svg)](https://www.debian.org/)

## Overview

This is a comprehensive VPN and SSH server management solution designed for fresh VPS installations. It provides automated setup, user management, and an interactive menu for managing multiple VPN protocols, SSH users, SSL certificates, and server security.

## Features

### Protocols Supported
- **SSH**: OpenSSH + Dropbear dual SSH servers
- **VPN Protocols**:
  - Xray-core (VLESS, VMess, Trojan, Shadowsocks)
  - WireGuard
  - Hysteria2
- **Transport**:
  - WebSocket (WS)
  - gRPC
  - HTTP/2
  - TLS / REALITY

### Core Features
- ✅ Automated installation on Ubuntu/Debian
- ✅ Interactive management menu
- ✅ User creation, deletion, expiry management
- ✅ Traffic and connection limits
- ✅ Subscription links and QR codes
- ✅ SSL certificate management (Let's Encrypt)
- ✅ Nginx reverse proxy with automatic HTTP→HTTPS redirect
- ✅ BBR congestion control
- ✅ UFW firewall + Fail2Ban
- ✅ System monitoring (CPU, RAM, bandwidth, etc.)
- ✅ Automatic backups and restore
- ✅ Customizable branding (banners, MOTD, etc.)
- ✅ Service auto-restart on failure
- ✅ Automatic security updates
- ✅ Comprehensive logging

---

## System Requirements

### Supported Operating Systems
- **Ubuntu**: 20.04 LTS, 22.04 LTS, 24.04 LTS, 26.04 LTS+
- **Debian**: 11, 12, 13+

### Minimum Hardware
- **CPU**: 1 core
- **RAM**: 512MB (1GB recommended)
- **Disk**: 2GB free space
- **Network**: Public IPv4 address (IPv6 optional)

### Virtualization
Supported: KVM, VMware, Hyper-V, Xen, Bare Metal  
Limited support: OpenVZ, LXC, Docker (WireGuard and BBR may not work)

---

## 🚀 Quick Install (One-Line Command)

### Auto-Install Script
```bash
wget -qO- https://raw.githubusercontent.com/dukemanuu70-dot/vpnscript/main/vpn-manager/install.sh | sudo bash
```

**OR using curl:**
```bash
curl -fsSL https://raw.githubusercontent.com/dukemanuu70-dot/vpnscript/main/vpn-manager/install.sh | sudo bash
```

### Manual Installation
```bash
# Clone the repository
git clone https://github.com/dukemanuu70-dot/vpnscript.git
cd vpnscript/vpn-manager

# Run the installer
sudo bash install.sh
```

### Post-Install
After installation completes:
```bash
# Navigate to the installed directory
cd /root/vpnscript/vpn-manager  # or wherever you cloned it

# Launch the interactive menu
sudo bash menu.sh
```

**⚠️ IMPORTANT**: 
- Run on a **fresh VPS only** (existing configurations may conflict)
- Ensure ports **22, 80, 443** are accessible
- Root access required

---

## File Structure

```
vpn-manager/
├── install.sh              # Main installer
├── update.sh               # Update script
├── uninstall.sh            # Complete uninstaller
├── menu.sh                 # Interactive management menu
├── lib/                    # Core libraries
│   ├── colors.sh           # ANSI color definitions
│   ├── logger.sh           # Logging system
│   ├── utils.sh            # Utility functions
│   ├── detect.sh           # OS/network detection
│   └── validate.sh         # Input validation
├── modules/                # Feature modules
│   ├── ssh.sh              # SSH user management
│   ├── dropbear.sh         # Dropbear SSH
│   ├── nginx.sh            # Nginx configuration
│   ├── xray.sh             # Xray-core protocols
│   ├── wireguard.sh        # WireGuard VPN
│   ├── hysteria2.sh        # Hysteria2 protocol
│   ├── ssl.sh              # SSL certificate management
│   ├── security.sh         # Firewall & Fail2Ban
│   ├── bbr.sh              # BBR congestion control
│   ├── branding.sh         # Customization
│   ├── monitoring.sh       # System monitoring
│   └── backup.sh           # Backup & restore
├── systemd/                # Systemd service units
│   ├── xray.service
│   ├── hysteria-server.service
│   └── dropbear.service
├── templates/              # Config templates
│   ├── xray-config.json
│   └── nginx-domain.conf
├── logs/                   # Local logs (install-time)
├── backup/                 # Backup storage
├── configs/                # Additional configs
├── README.md               # This file
├── LICENSE                 # License file
└── CHANGELOG.md            # Version history
```

---

## Configuration

### Domain Setup
The installer will prompt for your domain. Ensure:
1. Domain DNS points to your VPS IPv4
2. Ports 80 and 443 are open
3. Email for SSL notifications

```bash
# Example: Configure domain after install
sudo bash menu.sh
# Select: SSL / Domain -> Setup SSL for Domain
```

### Firewall Ports
Default ports opened by installer:
- **22**: SSH (OpenSSH)
- **444**: SSH (Dropbear)
- **80/443**: HTTP/HTTPS (Nginx)
- **51820/udp**: WireGuard
- **8443/udp**: Hysteria2

Internal ports (proxied via Nginx):
- 10000-10003: Xray protocols (not exposed)

### User Management

#### SSH Users
```bash
# Via menu:
menu.sh -> SSH User Management -> Create SSH User

# Or via command (future CLI):
vpn-manager ssh create-user <username> --days 30 --max-logins 2
```

#### VPN Users (Xray)
```bash
# Create VLESS, VMess, Trojan, or Shadowsocks users via menu
menu.sh -> Xray / VPN Users -> Create [Protocol] User
```

Each user gets:
- Unique UUID/password
- Subscription link
- QR code (if qrencode installed)
- Expiry date
- Traffic limit (optional)
- Connection limit (optional)

### SSL Certificate Renewal
Automatic renewal runs twice daily via cron. Manual renewal:
```bash
# Via menu:
menu.sh -> SSL / Domain -> Renew Certificates

# Or directly:
certbot renew --quiet
systemctl reload nginx
```

### Backup & Restore
```bash
# Create backup
menu.sh -> Backup & Restore -> Create Backup

# Backups stored in: /var/lib/vpn-manager/backups/
# Maximum 10 backups kept (configurable)

# Restore from backup
menu.sh -> Backup & Restore -> Restore from Backup
```

Backed up items:
- User database
- SSL certificates
- Xray configs
- Nginx configs
- SSH configs
- Firewall rules
- Branding settings

---

## Security

### Hardening Applied
- UFW firewall with default deny
- Fail2Ban with SSH brute-force protection
- Sysctl security settings (IP forwarding controls, SYN cookies, etc.)
- TLS 1.2/1.3 only (no SSLv3, TLS 1.0/1.1)
- Secure SSH ciphers and key exchange
- Rate limiting on Nginx
- Automatic security updates enabled

### Fail2Ban
Monitors:
- SSH (OpenSSH + Dropbear)
- Nginx authentication failures
- Nginx rate limit violations

Ban time: 1 hour (configurable in `/etc/fail2ban/jail.local`)

### BBR Congestion Control
BBR improves network throughput. Enable via menu:
```bash
menu.sh -> Security -> Enable BBR
```
Requires kernel 4.9+. Not available in some container environments.

---

## Monitoring

Available metrics:
- System info (OS, CPU, RAM, disk, uptime)
- Service status (all services)
- Online users (SSH, VPN)
- Bandwidth usage (via vnstat)
- Speed test (via speedtest-cli)
- User expiry dates
- Banned IPs (Fail2Ban)

Access via:
```bash
menu.sh -> Monitoring
```

---

## Updating

### One-Line Update
```bash
wget -qO- https://raw.githubusercontent.com/dukemanuu70-dot/vpnscript/main/vpn-manager/update.sh | sudo bash
```

### Update System Packages
```bash
sudo bash update.sh
# Or via menu: Updates -> Update System Packages
```

### Update Xray-core
```bash
# Via menu: Updates -> Update Xray-core
```

### Update Panel
```bash
cd vpnscript/vpn-manager
git pull origin main
# Or via menu: Updates -> Update VPN Manager Panel
```

---

## Troubleshooting

### Installation Fails
- Check log: `/var/log/vpn-manager/install_<date>.log`
- Ensure internet connectivity
- Verify OS is supported
- Check disk space: `df -h`

### Service Not Starting
```bash
# Check service status
systemctl status <service>

# View logs
journalctl -u <service> -n 50

# Test config
nginx -t          # Nginx
xray run -test -config /usr/local/etc/xray/config.json  # Xray
```

### SSL Certificate Issues
```bash
# Test certificate renewal
certbot renew --dry-run

# Check DNS
dig +short yourdomain.com

# Verify ports 80 and 443 are open
ss -tlnp | grep ':80\|:443'
```

### Users Can't Connect
1. Check service status: `systemctl status xray nginx`
2. Verify firewall: `ufw status`
3. Check user not expired: `menu.sh -> SSH/Xray Users -> Show Expiry`
4. Review logs: `/var/log/xray/error.log`, `/var/log/nginx/error.log`

### Reset Admin Password
SSH users can be reset via:
```bash
menu.sh -> SSH User Management -> Reset Password
```

---

## Uninstall

Complete removal:
```bash
sudo bash uninstall.sh
```
Prompts:
- Remove VPN users? (yes/no)
- Reset firewall? (yes/no)
- Remove logs? (yes/no)

---

## FAQ

**Q: Can I use multiple domains?**  
A: Yes, use `menu.sh -> SSL / Domain -> Add Additional Domain`

**Q: How do I change SSH port?**  
A: Edit `/etc/ssh/sshd_config`, update UFW rules, restart SSH.

**Q: Does this work on OpenVZ/LXC?**  
A: Partially. SSH, Xray, Nginx work. WireGuard and BBR require kernel modules not available in most containers.

**Q: Can I install on an existing server?**  
A: Not recommended. Installer assumes fresh VPS. Backup existing configs first.

**Q: How many users can I create?**  
A: Limited only by system resources. Tested with 1000+ users.

**Q: Is this free?**  
A: Yes, MIT licensed. Free for personal and commercial use.

---

## License

MIT License. See `LICENSE` file for details.

---

## Support

- **GitHub**: https://github.com/dukemanuu70-dot/vpnscript
- **Issues**: https://github.com/dukemanuu70-dot/vpnscript/issues

---

## Credits

Built with:
- **Xray-core**: https://github.com/XTLS/Xray-core
- **Hysteria2**: https://github.com/apernet/hysteria
- **WireGuard**: https://www.wireguard.com/
- **Nginx**: https://nginx.org/
- **Certbot**: https://certbot.eff.org/

---

**Author**: VPN Manager Team  
**Version**: 1.0.0  
**Repository**: https://github.com/dukemanuu70-dot/vpnscript  
**Last Updated**: 2024
