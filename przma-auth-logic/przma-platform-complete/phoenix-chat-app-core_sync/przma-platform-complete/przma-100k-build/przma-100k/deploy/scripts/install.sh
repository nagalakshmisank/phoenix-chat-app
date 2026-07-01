#!/bin/bash
# deploy/scripts/install.sh
#
# PRZMA one-line self-hosted installer.
# Tested on: Ubuntu 22.04/24.04, Debian 12 (Linode, DigitalOcean, any VPS)
#
# Usage:
#   curl -sSL https://get.przma.app | bash
#   # OR:
#   bash install.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[PRZMA]${NC} $1"; }
success() { echo -e "${GREEN}[PRZMA]${NC} $1"; }
warn()    { echo -e "${YELLOW}[PRZMA]${NC} $1"; }
error()   { echo -e "${RED}[PRZMA]${NC} $1"; exit 1; }

INSTALL_DIR="${PRZMA_INSTALL_DIR:-/opt/przma}"
DATA_DIR="${PRZMA_DATA_DIR:-/var/lib/przma}"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        PRZMA Self-Hosted Installer       ║"
echo "║   Sovereign Perception Intelligence      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Check prerequisites ────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (or with sudo)."
    fi
}

check_os() {
    if ! command -v apt-get &>/dev/null; then
        warn "This installer is designed for Debian/Ubuntu. Your system may work but is untested."
    fi
}

check_ram() {
    RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_GB=$(awk "BEGIN {printf \"%.1f\", $RAM_KB/1048576}")
    if (( RAM_KB < 1500000 )); then
        warn "Only ${RAM_GB}GB RAM detected. PRZMA needs at least 2GB. Performance may be degraded."
    else
        info "RAM: ${RAM_GB}GB — sufficient"
    fi
}

# ── Install Docker ─────────────────────────────────────────────────────────────
install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker already installed: $(docker --version)"
        return
    fi

    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    success "Docker installed"
}

install_docker_compose() {
    if docker compose version &>/dev/null 2>&1; then
        info "Docker Compose already installed"
        return
    fi

    info "Installing Docker Compose plugin..."
    apt-get install -y docker-compose-plugin
    success "Docker Compose installed"
}

# ── Install Caddy ──────────────────────────────────────────────────────────────
install_caddy() {
    if command -v caddy &>/dev/null; then
        info "Caddy already installed: $(caddy version)"
        return
    fi

    info "Installing Caddy..."
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
    success "Caddy installed"
}

# ── Configure PRZMA ────────────────────────────────────────────────────────────
configure() {
    info "Configuring PRZMA..."

    mkdir -p "$INSTALL_DIR" "$DATA_DIR/vaults" "$DATA_DIR/keys" /var/log/caddy

    # Prompt for domain
    echo ""
    read -rp "  Enter your domain name (e.g. przma.yourdomain.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && error "Domain name is required."

    # Prompt for email (Let's Encrypt)
    read -rp "  Enter your email for TLS certificates: " EMAIL
    [[ -z "$EMAIL" ]] && error "Email is required for TLS."

    # Generate secrets
    SECRET_KEY_BASE=$(openssl rand -hex 64)
    POSTGRES_PASSWORD=$(openssl rand -hex 32)
    MINIO_SECRET_KEY=$(openssl rand -hex 32)

    info "Generating .env configuration..."
    cat > "$INSTALL_DIR/.env" << EOF
SECRET_KEY_BASE=$SECRET_KEY_BASE
PRZMA_INSTANCE_URL=https://$DOMAIN
PRZMA_INSTANCE_HOST=$DOMAIN
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
MINIO_ACCESS_KEY=przma
MINIO_SECRET_KEY=$MINIO_SECRET_KEY
PRZMA_VERSION=latest
ACME_EMAIL=$EMAIL
EOF

    chmod 600 "$INSTALL_DIR/.env"
    success ".env written to $INSTALL_DIR/.env"

    # Copy docker-compose files
    cp "$(dirname "$0")/../docker/docker-compose.yml" "$INSTALL_DIR/"
    cp "$(dirname "$0")/../docker/Caddyfile"          "$INSTALL_DIR/"

    # Substitute domain in Caddyfile
    sed -i "s/\${PRZMA_INSTANCE_HOST}/$DOMAIN/g" "$INSTALL_DIR/Caddyfile"
    sed -i "s/\${ACME_EMAIL}/$EMAIL/g"            "$INSTALL_DIR/Caddyfile"

    success "Configuration complete"
}

# ── Create systemd services ────────────────────────────────────────────────────
setup_systemd() {
    info "Setting up systemd services..."

    # PRZMA (Docker Compose)
    cat > /etc/systemd/system/przma.service << EOF
[Unit]
Description=PRZMA Sovereign Platform
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

    # Caddy
    systemctl enable caddy

    systemctl daemon-reload
    systemctl enable przma
    success "Systemd services configured"
}

# ── Install backup cron ────────────────────────────────────────────────────────
setup_backup() {
    info "Setting up daily backup..."
    BACKUP_SCRIPT="$INSTALL_DIR/backup.sh"
    cp "$(dirname "$0")/backup.sh" "$BACKUP_SCRIPT"
    chmod +x "$BACKUP_SCRIPT"

    # Add cron job at 3am daily
    (crontab -l 2>/dev/null; echo "0 3 * * * $BACKUP_SCRIPT >> /var/log/przma-backup.log 2>&1") | crontab -
    success "Daily backup scheduled at 03:00"
}

# ── Start PRZMA ────────────────────────────────────────────────────────────────
start() {
    info "Starting PRZMA..."
    cd "$INSTALL_DIR"
    docker compose pull
    docker compose up -d

    # Start Caddy with our config
    caddy start --config "$INSTALL_DIR/Caddyfile" --adapter caddyfile 2>/dev/null || \
    caddy reload --config "$INSTALL_DIR/Caddyfile" --adapter caddyfile

    success "PRZMA started!"
}

# ── Summary ────────────────────────────────────────────────────────────────────
summary() {
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║         PRZMA Installation Complete!     ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    success "Your PRZMA instance is starting at: https://$DOMAIN"
    echo ""
    warn "  Important notes:"
    echo "  1. Allow 2-3 minutes for PRZMA to fully start."
    echo "  2. TLS certificate will be obtained automatically on first access."
    echo "  3. Configuration is in: $INSTALL_DIR/.env"
    echo "  4. Vault data is in: $DATA_DIR/vaults"
    echo ""
    info "  Useful commands:"
    echo "  • View logs:    cd $INSTALL_DIR && docker compose logs -f przma"
    echo "  • Stop:         cd $INSTALL_DIR && docker compose down"
    echo "  • Update:       cd $INSTALL_DIR && bash update.sh"
    echo "  • Backup:       bash $INSTALL_DIR/backup.sh"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    check_root
    check_os
    check_ram

    info "Updating package lists..."
    apt-get update -qq

    install_docker
    install_docker_compose
    install_caddy
    configure
    setup_systemd
    setup_backup
    start
    summary
}

main "$@"
