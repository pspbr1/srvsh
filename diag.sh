#!/bin/bash
# Script de Diagnóstico Completo - Verifica todos os serviços e conflitos

set -euo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPORT_FILE="/var/log/diagnostico_$(date +%Y%m%d_%H%M%S).txt"
ERRORS=()
WARNINGS=()

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$REPORT_FILE"
}

log_error() {
    echo -e "${RED}[ERRO]${NC} $1"
    ERRORS+=("$1")
    echo "ERRO: $1" >> "$REPORT_FILE"
}

log_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
    WARNINGS+=("$1")
    echo "AVISO: $1" >> "$REPORT_FILE"
}

log_info() {
    echo -e "${GREEN}[OK]${NC} $1"
    echo "OK: $1" >> "$REPORT_FILE"
}

# ============================================================================
# FUNÇÕES DE DIAGNÓSTICO
# ============================================================================

diagnostico_rede() {
    print_header "1. DIAGNÓSTICO DE REDE E NAT"
    
    # Verificar interfaces
    if ip link show enp0s8 &>/dev/null; then
        log_info "Interface enp0s8 encontrada"
        IP=$(ip -4 addr show enp0s8 | grep -oP 'inet \K[\d.]+')
        if [ -n "$IP" ]; then
            log_info "IP enp0s8: $IP"
        else
            log_error "Interface enp0s8 sem IP configurado"
        fi
    else
        log_error "Interface enp0s8 não encontrada"
    fi
    
    # Verificar NAT
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
        log_error "IP forwarding desabilitado"
    else
        log_info "IP forwarding habilitado"
    fi
    
    # Verificar regras iptables
    if ! iptables -t nat -L POSTROUTING -n | grep -q MASQUERADE; then
        log_error "Regra NAT MASQUERADE não encontrada"
    else
        log_info "Regra NAT configurada"
    fi
    
    # Verificar conectividade
    if ping -c 2 8.8.8.8 &>/dev/null; then
        log_info "Conectividade com internet OK"
    else
        log_error "Sem conectividade com internet"
    fi
}

diagnostico_dhcp() {
    print_header "2. DIAGNÓSTICO DO SERVIDOR DHCP"
    
    if systemctl is-active --quiet isc-dhcp-server; then
        log_info "Serviço DHCP está ativo"
    else
        log_error "Serviço DHCP não está ativo"
        systemctl status isc-dhcp-server --no-pager | tail -20 >> "$REPORT_FILE"
    fi
    
    # Verificar porta UDP 67
    if netstat -uln | grep -q ":67 "; then
        log_info "DHCP escutando na porta 67"
    else
        log_error "DHCP não está escutando na porta 67"
    fi
    
    # Verificar configuração
    if [ -f "/etc/dhcp/dhcpd.conf" ]; then
        if grep -q "range" /etc/dhcp/dhcpd.conf; then
            RANGE=$(grep "range" /etc/dhcp/dhcpd.conf)
            log_info "Configuração DHCP encontrada: $RANGE"
        else
            log_error "Configuração DHCP incompleta (sem range)"
        fi
    else
        log_error "Arquivo /etc/dhcp/dhcpd.conf não encontrado"
    fi
}

diagnostico_email() {
    print_header "3. DIAGNÓSTICO DO SISTEMA DE EMAIL"
    
    # Postfix
    if systemctl is-active --quiet postfix; then
        log_info "Postfix está ativo"
    else
        log_error "Postfix não está ativo"
    fi
    
    # Dovecot
    if systemctl is-active --quiet dovecot; then
        log_info "Dovecot está ativo"
    else
        log_error "Dovecot não está ativo"
    fi
    
    # Verificar portas
    for porta in 25 110 143; do
        if netstat -tln | grep -q ":$porta "; then
            log_info "Porta $porta (email) em escuta"
        else
            log_error "Porta $porta NÃO está em escuta"
        fi
    done
    
    # Verificar logs de erro
    if [ -f "/var/log/mail.log" ]; then
        ERROS=$(tail -100 /var/log/mail.log | grep -i "error\|fatal\|reject" | wc -l)
        if [ "$ERROS" -gt 0 ]; then
            log_warning "Encontrados $ERROS erros no mail.log"
            tail -5 /var/log/mail.log | grep -i "error\|fatal" >> "$REPORT_FILE"
        fi
    fi
    
    # Verificar configuração
    RELAYHOST=$(postconf relayhost 2>/dev/null | cut -d'=' -f2 | xargs)
    if [ -n "$RELAYHOST" ] && [ "$RELAYHOST" != "" ]; then
        log_info "Relayhost configurado: $RELAYHOST"
    else
        log_warning "Relayhost não configurado (pode ser intencional no servidor)"
    fi
}

diagnostico_samba() {
    print_header "4. DIAGNÓSTICO DO SAMBA"
    
    if systemctl is-active --quiet smbd; then
        log_info "Samba está ativo"
    else
        log_error "Samba não está ativo"
    fi
    
    # Verificar compartilhamentos
    if [ -f "/etc/samba/smb.conf" ]; then
        SHARES=$(grep -c "^\[" /etc/samba/smb.conf)
        log_info "Encontrados $SHARES compartilhamentos no smb.conf"
    else
        log_error "Arquivo smb.conf não encontrado"
    fi
    
    # Verificar porta Samba
    if netstat -tln | grep -q ":445 "; then
        log_info "Samba escutando na porta 445"
    else
        log_error "Samba NÃO está escutando na porta 445"
    fi
}

diagnostico_web() {
    print_header "5. DIAGNÓSTICO DO WEB SERVER"
    
    # Apache
    if systemctl is-active --quiet apache2; then
        log_info "Apache está ativo"
    else
        log_error "Apache não está ativo"
    fi
    
    # MySQL
    if systemctl is-active --quiet mysql || systemctl is-active --quiet mariadb; then
        log_info "MySQL/MariaDB está ativo"
    else
        log_error "MySQL/MariaDB não está ativo"
    fi
    
    # Verificar portas web
    for porta in 80 443; do
        if netstat -tln | grep -q ":$porta "; then
            log_info "Porta $porta (HTTP/HTTPS) em escuta"
        else
            log_error "Porta $porta NÃO está em escuta"
        fi
    done
    
    # Verificar PHPMyAdmin
    if [ -d "/usr/share/phpmyadmin" ] || [ -d "/var/www/html/phpmyadmin" ]; then
        log_info "phpMyAdmin instalado"
    else
        log_warning "phpMyAdmin não encontrado"
    fi
}

diagnostico_squid() {
    print_header "6. DIAGNÓSTICO DO SQUID PROXY"
    
    if systemctl is-active --quiet squid; then
        log_info "Squid está ativo"
    else
        log_error "Squid não está ativo"
    fi
    
    # Verificar porta 3128
    if netstat -tln | grep -q ":3128 "; then
        log_info "Squid escutando na porta 3128"
    else
        log_error "Squid NÃO está escutando na porta 3128"
    fi
}

diagnostico_nfs() {
    print_header "7. DIAGNÓSTICO DO NFS"
    
    if systemctl is-active --quiet nfs-server; then
        log_info "NFS está ativo"
    else
        log_error "NFS não está ativo"
    fi
    
    # Verificar exportações
    if [ -f "/etc/exports" ] && [ -s "/etc/exports" ]; then
        log_info "Exportações NFS configuradas"
        cat /etc/exports >> "$REPORT_FILE"
    else
        log_error "Nenhuma exportação NFS configurada"
    fi
}

diagnostico_firewall() {
    print_header "8. DIAGNÓSTICO DO FIREWALL"
    
    if command -v ufw &>/dev/null; then
        if ufw status | grep -q "Status: active"; then
            log_info "UFW está ativo"
            echo "Regras UFW:" >> "$REPORT_FILE"
            ufw status verbose >> "$REPORT_FILE"
        else
            log_warning "UFW está inativo"
        fi
    else
        log_warning "UFW não está instalado"
    fi
}

diagnostico_conflitos() {
    print_header "9. VERIFICAÇÃO DE CONFLITOS"
    
    # Verificar portas conflitantes
    echo "Portas em uso:" >> "$REPORT_FILE"
    netstat -tlnp | grep LISTEN >> "$REPORT_FILE"
    
    # Verificar serviços duplicados
    if systemctl list-unit-files | grep -q "mariadb.service" && systemctl list-unit-files | grep -q "mysql.service"; then
        log_warning "MySQL e MariaDB ambos instalados (possível conflito)"
    fi
    
    # Verificar conflito de IP
    IP_CONFLICT=$(arping -c 2 -I enp0s8 192.168.0.1 2>/dev/null | grep -c "reply")
    if [ "$IP_CONFLICT" -gt 1 ]; then
        log_error "Possível conflito de IP na rede!"
    fi
}

# ============================================================================
# FUNÇÃO PRINCIPAL
# ============================================================================

main() {
    echo "Iniciando diagnóstico completo..."
    echo "Relatório sendo salvo em: $REPORT_FILE"
    echo ""
    
    diagnostico_rede
    echo ""
    
    diagnostico_dhcp
    echo ""
    
    diagnostico_email
    echo ""
    
    diagnostico_samba
    echo ""
    
    diagnostico_web
    echo ""
    
    diagnostico_squid
    echo ""
    
    diagnostico_nfs
    echo ""
    
    diagnostico_firewall
    echo ""
    
    diagnostico_conflitos
    echo ""
    
    # RESUMO FINAL
    print_header "RESUMO DO DIAGNÓSTICO"
    echo ""
    echo "=========================================="
    echo "ERROS ENCONTRADOS: ${#ERRORS[@]}"
    echo "=========================================="
    for erro in "${ERRORS[@]}"; do
        echo -e "${RED}• $erro${NC}"
    done
    
    echo ""
    echo "=========================================="
    echo "AVISOS: ${#WARNINGS[@]}"
    echo "=========================================="
    for aviso in "${WARNINGS[@]}"; do
        echo -e "${YELLOW}• $aviso${NC}"
    done
    
    echo ""
    echo "=========================================="
    echo "AÇÕES RECOMENDADAS:"
    echo "=========================================="
    if [ ${#ERRORS[@]} -gt 0 ]; then
        echo "1. Execute o script de reparo: sudo ./reparador_completo.sh"
        echo "2. Verifique o relatório completo: $REPORT_FILE"
        echo "3. Consulte os logs específicos de cada serviço"
    else
        echo "✓ Sistema funcionando corretamente!"
        echo "Para manutenção preventiva, execute o reparador mensalmente"
    fi
    
    echo ""
    echo "Relatório completo salvo em: $REPORT_FILE"
}

# Executar diagnóstico
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Execute como root: sudo $0${NC}"
    exit 1
fi

main