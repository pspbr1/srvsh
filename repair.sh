#!/bin/bash
# Script de Reparo Completo - Corrige problemas em servidor e cliente

set -euo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPAIR_LOG="/var/log/reparo_$(date +%Y%m%d_%H%M%S).txt"
FIX_COUNT=0

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

log_fix() {
    echo -e "${GREEN}[REPARO]${NC} $1"
    ((FIX_COUNT++))
    echo "REPARO: $1" >> "$REPAIR_LOG"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }

# ============================================================================
# FUNÇÕES DE REPARO
# ============================================================================

reparar_rede() {
    print_header "REPARANDO REDE E NAT"
    
    # Corrigir IP forwarding
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p
        log_fix "IP forwarding habilitado"
    fi
    
    # Corrigir NAT
    if ! iptables -t nat -C POSTROUTING -o enp0s3 -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o enp0s3 -j MASQUERADE
        iptables -A FORWARD -i enp0s8 -o enp0s3 -j ACCEPT
        iptables -A FORWARD -i enp0s3 -o enp0s8 -m state --state RELATED,ESTABLISHED -j ACCEPT
        
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
        else
            apt install -y netfilter-persistent
            netfilter-persistent save
        fi
        log_fix "Regras NAT configuradas e salvas"
    fi
    
    # Verificar interface LAN
    if ! ip link show enp0s8 &>/dev/null; then
        log_info "Interface enp0s8 não encontrada. Verifique nomes das interfaces."
    else
        if ! ip addr show enp0s8 | grep -q "inet "; then
            log_info "Configurando IP na enp0s8..."
            cat > /etc/netplan/99-fix.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s8:
      addresses: [192.168.0.1/24]
      dhcp4: no
EOF
            netplan apply
            log_fix "IP configurado na interface enp0s8"
        fi
    fi
}

reparar_dhcp() {
    print_header "REPARANDO SERVIDOR DHCP"
    
    # Instalar se necessário
    if ! command -v dhcpd &>/dev/null; then
        apt install -y isc-dhcp-server
        log_fix "DHCP instalado"
    fi
    
    # Corrigir configuração
    cat > /etc/dhcp/dhcpd.conf <<EOF
default-lease-time 600;
max-lease-time 7200;
authoritative;
subnet 192.168.0.0 netmask 255.255.255.0 {
  range 192.168.0.100 192.168.0.200;
  option routers 192.168.0.1;
  option subnet-mask 255.255.255.0;
  option domain-name-servers 1.1.1.1, 8.8.8.8;
}
EOF
    
    echo "INTERFACESv4=\"enp0s8\"" > /etc/default/isc-dhcp-server
    
    systemctl restart isc-dhcp-server
    systemctl enable isc-dhcp-server
    log_fix "Configuração DHCP corrigida"
}

reparar_email_servidor() {
    print_header "REPARANDO EMAIL NO SERVIDOR"
    
    # Verificar Postfix
    if ! systemctl is-active --quiet postfix; then
        apt install -y postfix mailutils
        log_fix "Postfix instalado/reinstalado"
    fi
    
    # Configuração correta para servidor
    postconf -e "myhostname = $(hostname).localdomain"
    postconf -e "mydomain = localdomain"
    postconf -e "inet_interfaces = all"
    postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
    postconf -e "mynetworks = 127.0.0.0/8 192.168.0.0/24"
    postconf -e "relayhost = "
    postconf -e "home_mailbox = Maildir/"
    
    systemctl restart postfix
    log_fix "Postfix configurado como servidor"
    
    # Dovecot
    if ! systemctl is-active --quiet dovecot; then
        apt install -y dovecot-core dovecot-imapd dovecot-pop3d
    fi
    
    # Configuração básica Dovecot
    cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_location = maildir:~/Maildir
EOF
    
    systemctl restart dovecot
    log_fix "Dovecot configurado"
    
    # Liberar firewall
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow 25/tcp
        ufw allow 143/tcp
        ufw allow 110/tcp
        log_fix "Portas de email liberadas no firewall"
    fi
}

reparar_email_cliente() {
    print_header "REPARANDO EMAIL NO CLIENTE"
    
    read -p "Digite o IP do servidor de email: " IP_SERVIDOR
    
    if ! systemctl is-active --quiet postfix; then
        apt install -y postfix mailutils
    fi
    
    # Configuração correta para cliente
    postconf -e "myhostname = $(hostname).localdomain"
    postconf -e "mydomain = localdomain"
    postconf -e "relayhost = [$IP_SERVIDOR]"
    postconf -e "inet_interfaces = loopback-only"
    postconf -e "mydestination = localhost"
    postconf -e "mynetworks = 127.0.0.0/8"
    
    # Adicionar ao /etc/hosts
    if ! grep -q "$IP_SERVIDOR" /etc/hosts; then
        echo "$IP_SERVIDOR    servidor.localdomain servidor" >> /etc/hosts
        log_fix "Servidor adicionado ao /etc/hosts"
    fi
    
    systemctl restart postfix
    log_fix "Cliente configurado para usar relay: $IP_SERVIDOR"
}

reparar_samba() {
    print_header "REPARANDO SAMBA"
    
    if ! systemctl is-active --quiet smbd; then
        apt install -y samba
        log_fix "Samba instalado"
    fi
    
    # Configuração básica
    SHARED_DIR="/srv/compartilhado"
    mkdir -p $SHARED_DIR
    chmod 777 $SHARED_DIR
    
    if ! grep -q "^\[Compartilhado\]" /etc/samba/smb.conf; then
        cat >> /etc/samba/smb.conf <<EOF

[Compartilhado]
   path = $SHARED_DIR
   browseable = yes
   writable = yes
   guest ok = yes
   public = yes
EOF
        log_fix "Compartilhamento Samba adicionado"
    fi
    
    systemctl restart smbd nmbd
    systemctl enable smbd nmbd
    
    # Liberar firewall
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow samba
        log_fix "Samba liberado no firewall"
    fi
}

reparar_web() {
    print_header "REPARANDO WEB SERVER"
    
    # Apache
    if ! systemctl is-active --quiet apache2; then
        apt install -y apache2
        log_fix "Apache instalado"
    fi
    
    # MySQL/MariaDB
    if ! systemctl is-active --quiet mysql && ! systemctl is-active --quiet mariadb; then
        apt install -y mysql-server
        log_fix "MySQL instalado"
    fi
    
    systemctl restart apache2
    if systemctl list-unit-files | grep -q "mysql.service"; then
        systemctl restart mysql
    else
        systemctl restart mariadb
    fi
    
    log_fix "Serviços web reiniciados"
    
    # Liberar firewall
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        log_fix "Portas web liberadas no firewall"
    fi
}

reparar_squid() {
    print_header "REPARANDO SQUID"
    
    if ! systemctl is-active --quiet squid; then
        apt install -y squid
        log_fix "Squid instalado"
    fi
    
    # Configuração básica
    cat > /etc/squid/squid.conf <<EOF
http_port 3128
acl localnet src 192.168.0.0/24
http_access allow localnet
http_access deny all
EOF
    
    systemctl restart squid
    log_fix "Squid configurado e reiniciado"
}

reparar_nfs() {
    print_header "REPARANDO NFS"
    
    if ! systemctl is-active --quiet nfs-server; then
        apt install -y nfs-kernel-server
        log_fix "NFS instalado"
    fi
    
    # Configuração básica
    NFS_SHARE="/srv/nfs"
    mkdir -p $NFS_SHARE
    chmod 777 $NFS_SHARE
    
    if [ ! -f "/etc/exports" ] || ! grep -q "$NFS_SHARE" /etc/exports; then
        echo "$NFS_SHARE 192.168.0.0/24(rw,sync,no_subtree_check)" > /etc/exports
        exportfs -a
        log_fix "Exportação NFS configurada"
    fi
    
    systemctl restart nfs-server
    log_fix "NFS reiniciado"
}

reparar_firewall() {
    print_header "REPARANDO FIREWALL"
    
    if ! command -v ufw &>/dev/null; then
        apt install -y ufw
        log_fix "UFW instalado"
    fi
    
    # Configuração segura
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 25/tcp
    ufw allow 143/tcp
    ufw allow 110/tcp
    ufw allow 3128/tcp
    
    ufw --force enable
    log_fix "Firewall configurado com regras padrão"
}

limpar_fila_emails() {
    print_header "LIMPANDO FILA DE EMAILS"
    
    if command -v mailq &>/dev/null; then
        QUEUE_COUNT=$(mailq | grep -c "^[A-F0-9]" 2>/dev/null || echo "0")
        if [ "$QUEUE_COUNT" -gt 0 ]; then
            postsuper -d ALL
            log_fix "Fila de emails limpa ($QUEUE_COUNT emails removidos)"
        else
            log_info "Fila de emails vazia"
        fi
    fi
}

# ============================================================================
# FUNÇÃO PRINCIPAL
# ============================================================================

main() {
    echo "Script de Reparo Completo"
    echo "Este script corrige problemas comuns em servidores e clientes"
    echo "Log de reparos: $REPAIR_LOG"
    echo ""
    
    echo "Selecione o tipo de reparo:"
    echo "1) Reparo COMPLETO do servidor"
    echo "2) Reparo do CLIENTE de email apenas"
    echo "3) Reparo específico de um serviço"
    read -p "Opção [1-3]: " OPCAO
    
    case $OPCAO in
        1)
            echo "Iniciando reparo completo do servidor..."
            reparar_rede
            reparar_dhcp
            reparar_email_servidor
            reparar_samba
            reparar_web
            reparar_squid
            reparar_nfs
            reparar_firewall
            limpar_fila_emails
            ;;
        2)
            echo "Reparando apenas cliente de email..."
            reparar_email_cliente
            limpar_fila_emails
            ;;
        3)
            echo "Selecione o serviço para reparar:"
            echo "1) Rede/NAT"
            echo "2) DHCP"
            echo "3) Email (servidor)"
            echo "4) Email (cliente)"
            echo "5) Samba"
            echo "6) Web Server"
            echo "7) Squid"
            echo "8) NFS"
            echo "9) Firewall"
            read -p "Opção: " SERVICO
            
            case $SERVICO in
                1) reparar_rede ;;
                2) reparar_dhcp ;;
                3) reparar_email_servidor ;;
                4) reparar_email_cliente ;;
                5) reparar_samba ;;
                6) reparar_web ;;
                7) reparar_squid ;;
                8) reparar_nfs ;;
                9) reparar_firewall ;;
                *) echo "Opção inválida"; exit 1 ;;
            esac
            ;;
        *)
            echo "Opção inválida"
            exit 1
            ;;
    esac
    
    # RESUMO
    print_header "REPARO CONCLUÍDO"
    echo ""
    echo "Reparos aplicados: $FIX_COUNT"
    echo "Log completo: $REPAIR_LOG"
    echo ""
    echo "Recomendações pós-reparo:"
    echo "1. Execute o diagnóstico: sudo ./diagnostico_sistema.sh"
    echo "2. Teste cada serviço manualmente"
    echo "3. Reinicie o servidor se necessário: sudo reboot"
    echo ""
    echo "Para testar email:"
    echo "  Servidor: echo 'Teste' | mail -s 'Teste' root@localhost"
    echo "  Cliente: echo 'Teste' | mail -s 'Teste' usuario@servidor.localdomain"
    echo ""
    echo "=========================================="
}

# Executar
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Execute como root: sudo $0${NC}"
    exit 1
fi

main