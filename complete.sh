#!/bin/bash
# Script de Instalação Completa - Servidor Ubuntu 24.04
# Instala: DHCP, NAT, Email, Samba, Apache, MySQL, PHPMyAdmin, Squid, NFS

set -euo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/instalacao_completa_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERRO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Execute como root: sudo $0"
        exit 1
    fi
}

gerar_senha() {
    < /dev/urandom tr -dc 'A-Za-z0-9!@#$%&*()_+-=' | head -c16 || echo "SenhaSegura123!"
}

# Variáveis de configuração
INTERFACE_WAN="enp0s3"
INTERFACE_LAN="enp0s8"
SERVER_IP="192.168.0.1"
NETWORK_CIDR="192.168.0.0/24"
DHCP_RANGE_START="192.168.0.100"
DHCP_RANGE_END="192.168.0.200"
DNS_SERVER="1.1.1.1"

# Senhas geradas
MYSQL_ROOT_PASS=$(gerar_senha)
PHPMYADMIN_PASS=$(gerar_senha)
SAMBA_ADMIN_PASS=$(gerar_senha)

# ============================================================================
# FUNÇÃO PRINCIPAL DE INSTALAÇÃO
# ============================================================================

instalar_tudo() {
    print_header "INSTALAÇÃO COMPLETA DO SERVIDOR"
    echo "Iniciando em: $(date)"
    echo "Log: $LOG_FILE"
    echo ""
    
    # Etapa 1: Atualizar sistema
    print_header "1. ATUALIZANDO SISTEMA"
    apt update && apt upgrade -y
    
    # Etapa 2: Configurar rede
    print_header "2. CONFIGURANDO REDE E NAT"
    cat > /etc/netplan/01-installer-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE_WAN:
      dhcp4: true
    $INTERFACE_LAN:
      addresses: [$SERVER_IP/24]
      dhcp4: no
EOF
    netplan apply
    sleep 3
    
    # Habilitar NAT
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
    iptables -t nat -A POSTROUTING -o $INTERFACE_WAN -j MASQUERADE
    iptables -A FORWARD -i $INTERFACE_LAN -o $INTERFACE_WAN -j ACCEPT
    iptables -A FORWARD -i $INTERFACE_WAN -o $INTERFACE_LAN -m state --state RELATED,ESTABLISHED -j ACCEPT
    apt install -y netfilter-persistent
    netfilter-persistent save
    
    # Etapa 3: Instalar DHCP
    print_header "3. INSTALANDO SERVIDOR DHCP"
    apt install -y isc-dhcp-server
    cat > /etc/dhcp/dhcpd.conf <<EOF
default-lease-time 600;
max-lease-time 7200;
authoritative;
subnet 192.168.0.0 netmask 255.255.255.0 {
  range $DHCP_RANGE_START $DHCP_RANGE_END;
  option routers $SERVER_IP;
  option subnet-mask 255.255.255.0;
  option domain-name-servers $DNS_SERVER, 8.8.8.8;
}
EOF
    echo "INTERFACESv4=\"$INTERFACE_LAN\"" > /etc/default/isc-dhcp-server
    systemctl restart isc-dhcp-server
    systemctl enable isc-dhcp-server
    
    # Etapa 4: Instalar Email (Postfix + Dovecot)
    print_header "4. INSTALANDO SERVIDOR DE EMAIL"
    DEBIAN_FRONTEND=noninteractive apt install -y postfix dovecot-core dovecot-imapd dovecot-pop3d mailutils
    postconf -e "myhostname = $(hostname).localdomain"
    postconf -e "mydestination = localhost"
    postconf -e "inet_interfaces = all"
    postconf -e "mynetworks = 127.0.0.0/8 $NETWORK_CIDR"
    postconf -e "relayhost = "
    postconf -e "home_mailbox = Maildir/"
    
    # Configurar Dovecot
    cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_location = maildir:~/Maildir
EOF
    systemctl restart postfix dovecot
    systemctl enable postfix dovecot
    
    # Etapa 5: Instalar Samba
    print_header "5. INSTALANDO SAMBA"
    apt install -y samba
    SHARED_DIR="/srv/compartilhado"
    mkdir -p $SHARED_DIR
    chmod 777 $SHARED_DIR
    cat >> /etc/samba/smb.conf <<EOF
[Compartilhado]
   path = $SHARED_DIR
   browseable = yes
   writable = yes
   guest ok = yes
   public = yes
EOF
    systemctl restart smbd nmbd
    systemctl enable smbd nmbd
    
    # Etapa 6: Instalar Web Server
    print_header "6. INSTALANDO WEB SERVER"
    debconf-set-selections <<EOF
mysql-server mysql-server/root_password password $MYSQL_ROOT_PASS
mysql-server mysql-server/root_password_again password $MYSQL_ROOT_PASS
phpmyadmin phpmyadmin/dbconfig-install boolean true
phpmyadmin phpmyadmin/mysql/admin-pass password $MYSQL_ROOT_PASS
phpmyadmin phpmyadmin/mysql/app-pass password $PHPMYADMIN_PASS
phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2
EOF
    apt install -y apache2 mysql-server php libapache2-mod-php php-mysql phpmyadmin
    systemctl restart apache2 mysql
    systemctl enable apache2 mysql
    
    # Etapa 7: Instalar Squid Proxy
    print_header "7. INSTALANDO SQUID PROXY"
    apt install -y squid
    cat > /etc/squid/squid.conf <<EOF
http_port 3128
acl localnet src $NETWORK_CIDR
http_access allow localnet
http_access deny all
EOF
    systemctl restart squid
    systemctl enable squid
    
    # Etapa 8: Instalar NFS
    print_header "8. INSTALANDO NFS"
    apt install -y nfs-kernel-server
    NFS_SHARE="/srv/nfs"
    mkdir -p $NFS_SHARE
    chmod 777 $NFS_SHARE
    echo "$NFS_SHARE $NETWORK_CIDR(rw,sync,no_subtree_check)" >> /etc/exports
    exportfs -a
    systemctl restart nfs-kernel-server
    systemctl enable nfs-kernel-server
    
    # Etapa 9: Configurar Firewall
    print_header "9. CONFIGURANDO FIREWALL"
    apt install -y ufw
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80/tcp    # HTTP
    ufw allow 443/tcp   # HTTPS
    ufw allow 25/tcp    # SMTP
    ufw allow 143/tcp   # IMAP
    ufw allow 110/tcp   # POP3
    ufw allow 3128/tcp  # Squid
    ufw allow 139,445/tcp  # Samba
    ufw allow 2049/tcp  # NFS
    ufw --force enable
    
    # Etapa 10: Criar usuário de teste
    print_header "10. CRIANDO USUÁRIO DE TESTE"
    useradd -m -s /bin/bash admin || true
    echo "admin:Admin123!" | chpasswd
    usermod -aG sudo admin
    
    # Criar estrutura Maildir
    mkdir -p /home/admin/Maildir/{new,cur,tmp}
    chown -R admin:admin /home/admin/Maildir
    
    print_header "INSTALAÇÃO CONCLUÍDA!"
    echo ""
    echo "=========================================="
    echo "CREDENCIAIS E INFORMAÇÕES IMPORTANTES"
    echo "=========================================="
    echo "IP do Servidor: $SERVER_IP"
    echo "Rede: $NETWORK_CIDR"
    echo "DHCP: $DHCP_RANGE_START - $DHCP_RANGE_END"
    echo ""
    echo "MySQL Root Password: $MYSQL_ROOT_PASS"
    echo "phpMyAdmin Password: $PHPMYADMIN_PASS"
    echo ""
    echo "Usuário de teste: admin / Admin123!"
    echo ""
    echo "SERVIÇOS INSTALADOS:"
    echo "  • DHCP Server (isc-dhcp-server)"
    echo "  • NAT/Routing"
    echo "  • Postfix + Dovecot (SMTP/IMAP/POP3)"
    echo "  • Samba (//$SERVER_IP/Compartilhado)"
    echo "  • Apache2 + PHP + MySQL"
    echo "  • phpMyAdmin (http://$SERVER_IP/phpmyadmin)"
    echo "  • Squid Proxy (porta 3128)"
    echo "  • NFS Server (/srv/nfs)"
    echo ""
    echo "Para testar tudo, execute: sudo ./diagnostico_sistema.sh"
    echo "Para reparar problemas: sudo ./reparador_completo.sh"
    echo ""
    echo "Log completo: $LOG_FILE"
    echo "=========================================="
}

# Executar instalação
check_root
instalar_tudo