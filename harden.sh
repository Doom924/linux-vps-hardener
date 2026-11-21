#!/usr/bin/env bash
set -euo pipefail

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
   log_err "Запустите скрипт от имени root (sudo bash harden.sh)"
fi

# Определение ОС
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    log_err "Не удалось определить операционную систему"
fi

log_info "Обнаружена ОС: $PRETTY_NAME"

# 1. Установка базовых утилит и Fail2Ban
install_packages() {
    log_info "Обновление пакетов и установка Fail2Ban, tmux, mtr..."
    case "$OS" in
        ubuntu|debian)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban ufw tmux mtr-tiny curl
            ;;
        almalinux|rocky|centos|rhel)
            dnf install -y -q epel-release
            dnf install -y -q fail2ban firewalld tmux mtr curl
            ;;
        *)
            log_warn "Нестандартный дистрибутив ($OS), пропускаем автоустановку пакетов."
            ;;
    esac
}

# 2. Тюнинг SSH (стабильность соединения + защита)
harden_ssh() {
    local SSH_CFG="/etc/ssh/sshd_config"
    local BACKUP_CFG="/etc/ssh/sshd_config.bak.$(date +%F_%H%M%S)"
    
    log_info "Создание резервной копии $SSH_CFG -> $BACKUP_CFG"
    cp "$SSH_CFG" "$BACKUP_CFG"

    log_info "Настройка keep-alive и безопасности SSH..."
    cat << 'EOF' > /etc/ssh/sshd_config.d/99-hardening.conf
# Стабилизация соединения против разрывов NAT
ClientAliveInterval 30
ClientAliveCountMax 6
TCPKeepAlive yes
UseDNS no

# Базовый харденинг
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
PermitEmptyPasswords no
EOF

    # Проверка синтаксиса перед перезапуском службы
    if sshd -t; then
        log_info "Синтаксис sshd проверен успешно. Перезапуск службы..."
        systemctl restart sshd || systemctl restart ssh
    else
        log_err "Ошибка в конфигурации sshd! Откат изменений..."
        rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    fi
}

# 3. Оптимизация сети ядра (TCP BBR)
optimize_network() {
    log_info "Включение TCP BBR и оптимизация сетевого стека..."
    cat << 'EOF' > /etc/sysctl.d/99-network-tuning.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
EOF
    sysctl --system -q
}

# 4. Запуск Fail2Ban и файрвола
setup_security_services() {
    log_info "Активация Fail2Ban..."
    systemctl enable --now fail2ban

    case "$OS" in
        ubuntu|debian)
            ufw allow OpenSSH
            ufw --force enable
            ;;
        almalinux|rocky|centos|rhel)
            systemctl enable --now firewalld
            firewall-cmd --permanent --add-service=ssh
            firewall-cmd --reload
            ;;
    esac
}

install_packages
harden_ssh
optimize_network
setup_security_services

log_info "Базовая настройка, оптимизация сети и харденинг успешно завершены!"
