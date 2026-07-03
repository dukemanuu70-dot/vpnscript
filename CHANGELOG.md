# Changelog

All notable changes to VPN Manager will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2024-12-01

### Added
- Initial release of VPN Manager Suite
- Support for Ubuntu 20.04, 22.04, 24.04, 26.04 LTS
- Support for Debian 11, 12, 13
- Automated installation system with rollback on failure
- SSH management (OpenSSH + Dropbear)
  - User creation, deletion, lock/unlock
  - Password reset and expiry management
  - Connection limits and traffic monitoring
  - Custom SSH banners and MOTD
- Xray-core protocols
  - VLESS (TCP + WebSocket + gRPC)
  - VMess (WebSocket)
  - Trojan (TCP)
  - Shadowsocks (AEAD ciphers)
  - REALITY protocol support
- WireGuard VPN
  - Client configuration generation
  - QR code support
  - Automatic key management
- Hysteria2 protocol
  - QUIC-based transport
  - User/password authentication
- Nginx reverse proxy
  - Automatic SSL via Let's Encrypt
  - HTTP to HTTPS redirection
  - WebSocket and gRPC proxy support
  - Security headers
- Security features
  - UFW firewall with automatic rule management
  - Fail2Ban integration for SSH protection
  - BBR congestion control support
  - Sysctl hardening
  - Automatic security updates
- SSL/TLS management
  - Automated Let's Encrypt certificate issuance
  - Auto-renewal via systemd timer/cron
  - Multi-domain support
- Branding customization
  - Server name and provider info
  - Custom SSH banners
  - Custom MOTD
  - Contact information (Telegram, WhatsApp, website, email)
- System monitoring
  - CPU, RAM, disk usage
  - Bandwidth statistics (vnstat)
  - Service status overview
  - Online user tracking
  - Speed test integration
- Backup & restore
  - Automatic weekly backups
  - Manual backup creation
  - Full system restore capability
  - Backup rotation (keep last 10)
- Interactive management menu
  - Color-coded status indicators
  - User-friendly navigation
  - Input validation
  - Confirmation prompts for destructive actions
- Logging system
  - Structured logging with timestamps
  - Separate logs for different components
  - Activity audit log
  - Automatic log rotation
- Update system
  - System package updates
  - Xray-core updates
  - Panel self-update (git-based)
- Complete uninstaller
  - Service cleanup
  - Configuration removal
  - Optional log retention
  - SSH configuration restoration
- Comprehensive documentation
  - Installation guide
  - Configuration reference
  - Troubleshooting section
  - API documentation
  - FAQ

### Security
- All passwords hashed and stored securely
- Sensitive files have 600/700 permissions
- No hardcoded credentials
- Input validation for all user inputs
- ShellCheck compliance for all scripts
- Secure defaults (TLS 1.2+, modern ciphers)

### Performance
- BBR congestion control for improved throughput
- Optimized sysctl parameters
- Service auto-restart on failure
- Efficient process management

### Compatibility
- Automatic OS and architecture detection
- Virtualization detection (KVM, VMware, OpenVZ, LXC, Docker)
- Graceful degradation for unsupported features
- IPv4 and IPv6 support

---

## [Unreleased]

### Planned
- Web-based administration panel
- API for programmatic user management
- Multi-language support
- Email notifications for user expiry
- Advanced traffic shaping
- Load balancing support
- Database backend option (MySQL/PostgreSQL)
- Telegram bot integration
- RADIUS authentication support
- LDAP/Active Directory integration
- IPv6-only mode support
- Docker container deployment option
- Kubernetes Helm chart
- Ansible playbook
- Prometheus metrics export
- Grafana dashboard templates

---

## Version History

**1.0.0** - Initial Release (2024-12-01)
- Full-featured VPN and SSH management suite
- Production-ready with automated installation
- Comprehensive user management
- Multiple VPN protocols supported
- SSL automation
- Security hardening included
- Interactive menu system
- Complete documentation

---

## Migration Notes

### From Manual Setup
If you previously managed VPN services manually:
1. **Backup** all existing configurations
2. Note all active users and credentials
3. Run the installer on a **fresh VPS** (recommended)
4. Migrate users manually via the menu
5. Update client configurations with new server details

### Future Upgrades
- The update system preserves user configurations
- Database schemas will be versioned for smooth migrations
- Changelog will detail breaking changes
- Upgrade guides provided for major version bumps

---

## Contributing

We welcome contributions! See CONTRIBUTING.md for guidelines.

**Report issues**: https://github.com/dukemanuu70-dot/vpnscript/issues  
**Submit PRs**: https://github.com/dukemanuu70-dot/vpnscript/pulls

---

**Maintained by**: VPN Manager Team  
**License**: MIT  
**Website**: https://github.com/dukemanuu70-dot/vpnscript
