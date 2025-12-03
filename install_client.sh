#!/bin/bash
# Script de Instalação Completa - Cliente Ubuntu 24.04
# Configura cliente para consumir serviços do servidor

set -euo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/instalacao_cliente_$(date +%Y%m%d_%H%M%S).log"
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

# ============================================================================
# VARIÁVEIS DE CONFIGURAÇÃO
# ============================================================================

SERVER_IP="192.168.0.1"
INTERFACE_LAN="enp0s3"
PROXY_PORT="3128"
NFS_MOUNT_POINT="/mnt/nfs_servidor"
SAMBA_MOUNT_POINT="/mnt/samba_servidor"

# ============================================================================
# FUNÇÃO PRINCIPAL DE INSTALAÇÃO
# ============================================================================

instalar_cliente() {
    print_header "INSTALAÇÃO COMPLETA DO CLIENTE"
    echo "Iniciando em: $(date)"
    echo "Log: $LOG_FILE"
    echo "Servidor: $SERVER_IP"
    echo ""
    
    # Etapa 1: Atualizar sistema
    print_header "1. ATUALIZANDO SISTEMA"
    apt update && apt upgrade -y
    
    # Etapa 2: Configurar rede com DHCP
    print_header "2. CONFIGURANDO REDE (DHCP)"
    cat > /etc/netplan/01-installer-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE_LAN:
      dhcp4: true
      dhcp4-overrides:
        use-dns: true
        use-routes: true
EOF
    netplan apply
    sleep 5
    
    log_info "Testando conectividade com servidor..."
    if ping -c 3 $SERVER_IP > /dev/null 2>&1; then
        log_info "Servidor alcançável em $SERVER_IP"
    else
        log_warn "Servidor $SERVER_IP não responde. Verifique a conexão."
    fi
    
    # Etapa 3: Configurar Proxy Squid
    print_header "3. CONFIGURANDO PROXY SQUID"
    
    # Configurar proxy do sistema
    cat > /etc/environment <<EOF
http_proxy="http://$SERVER_IP:$PROXY_PORT/"
https_proxy="http://$SERVER_IP:$PROXY_PORT/"
ftp_proxy="http://$SERVER_IP:$PROXY_PORT/"
no_proxy="localhost,127.0.0.1,$SERVER_IP,192.168.0.0/24"
HTTP_PROXY="http://$SERVER_IP:$PROXY_PORT/"
HTTPS_PROXY="http://$SERVER_IP:$PROXY_PORT/"
FTP_PROXY="http://$SERVER_IP:$PROXY_PORT/"
NO_PROXY="localhost,127.0.0.1,$SERVER_IP,192.168.0.0/24"
EOF
    
    # Configurar APT para usar proxy
    cat > /etc/apt/apt.conf.d/95proxies <<EOF
Acquire::http::Proxy "http://$SERVER_IP:$PROXY_PORT/";
Acquire::https::Proxy "http://$SERVER_IP:$PROXY_PORT/";
EOF
    
    log_info "Proxy configurado: http://$SERVER_IP:$PROXY_PORT"
    
    # Etapa 4: Instalar e configurar Cliente Samba
    print_header "4. INSTALANDO CLIENTE SAMBA"
    apt install -y cifs-utils smbclient
    
    mkdir -p $SAMBA_MOUNT_POINT
    
    # Criar script de montagem Samba
    cat > /usr/local/bin/montar_samba.sh <<EOF
#!/bin/bash
if mount | grep -q "$SAMBA_MOUNT_POINT"; then
    echo "Samba já montado em $SAMBA_MOUNT_POINT"
else
    mount -t cifs //$SERVER_IP/Compartilhado $SAMBA_MOUNT_POINT -o guest,uid=1000,gid=1000,file_mode=0777,dir_mode=0777
    echo "Samba montado em $SAMBA_MOUNT_POINT"
fi
EOF
    chmod +x /usr/local/bin/montar_samba.sh
    
    # Adicionar ao fstab (opcional, comentado por padrão)
    if ! grep -q "Compartilhado" /etc/fstab; then
        echo "# //$SERVER_IP/Compartilhado $SAMBA_MOUNT_POINT cifs guest,uid=1000,gid=1000,file_mode=0777,dir_mode=0777,_netdev 0 0" >> /etc/fstab
    fi
    
    log_info "Cliente Samba instalado. Use: sudo /usr/local/bin/montar_samba.sh"
    
    # Etapa 5: Instalar e configurar Cliente NFS
    print_header "5. INSTALANDO CLIENTE NFS"
    apt install -y nfs-common
    
    mkdir -p $NFS_MOUNT_POINT
    
    # Criar script de montagem NFS
    cat > /usr/local/bin/montar_nfs.sh <<EOF
#!/bin/bash
if mount | grep -q "$NFS_MOUNT_POINT"; then
    echo "NFS já montado em $NFS_MOUNT_POINT"
else
    mount -t nfs $SERVER_IP:/srv/nfs $NFS_MOUNT_POINT
    echo "NFS montado em $NFS_MOUNT_POINT"
fi
EOF
    chmod +x /usr/local/bin/montar_nfs.sh
    
    # Adicionar ao fstab (opcional, comentado por padrão)
    if ! grep -q "/srv/nfs" /etc/fstab; then
        echo "# $SERVER_IP:/srv/nfs $NFS_MOUNT_POINT nfs defaults,_netdev 0 0" >> /etc/fstab
    fi
    
    log_info "Cliente NFS instalado. Use: sudo /usr/local/bin/montar_nfs.sh"
    
    # Etapa 6: Configurar Cliente de Email
    print_header "6. CONFIGURANDO CLIENTE DE EMAIL"
    apt install -y mailutils
    
    # Configurar Postfix como satélite
    DEBIAN_FRONTEND=noninteractive apt install -y postfix
    postconf -e "relayhost = [$SERVER_IP]"
    postconf -e "inet_interfaces = loopback-only"
    postconf -e "mydestination = "
    postconf -e "mynetworks = 127.0.0.0/8"
    
    systemctl restart postfix
    systemctl enable postfix
    
    log_info "Cliente de email configurado para relay via $SERVER_IP"
    
    # Etapa 7: Instalar ferramentas úteis
    print_header "7. INSTALANDO FERRAMENTAS ÚTEIS"
    apt install -y \
        curl \
        wget \
        net-tools \
        htop \
        vim \
        git \
        firefox \
        thunderbird \
        libreoffice
    
    # Etapa 8: Criar scripts de diagnóstico
    print_header "8. CRIANDO SCRIPTS DE DIAGNÓSTICO"
    
    cat > /usr/local/bin/testar_servidor.sh <<'EOF'
#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SERVER_IP="192.168.0.1"

echo "=========================================="
echo "TESTE DE CONECTIVIDADE COM SERVIDOR"
echo "=========================================="
echo ""

# Teste 1: Ping
echo -n "Ping para servidor... "
if ping -c 2 $SERVER_IP > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FALHOU${NC}"
fi

# Teste 2: DHCP
echo -n "Endereço IP via DHCP... "
IP=$(ip addr show | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1 | head -1)
if [[ $IP == 192.168.0.* ]]; then
    echo -e "${GREEN}$IP${NC}"
else
    echo -e "${YELLOW}$IP (verifique)${NC}"
fi

# Teste 3: Gateway
echo -n "Gateway padrão... "
GW=$(ip route | grep default | awk '{print $3}')
if [ "$GW" == "$SERVER_IP" ]; then
    echo -e "${GREEN}$GW${NC}"
else
    echo -e "${YELLOW}$GW${NC}"
fi

# Teste 4: DNS
echo -n "Resolução DNS... "
if nslookup google.com > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FALHOU${NC}"
fi

# Teste 5: Proxy
echo -n "Proxy Squid (porta 3128)... "
if nc -z -w2 $SERVER_IP 3128 > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FALHOU${NC}"
fi

# Teste 6: Web Server
echo -n "Servidor Web (porta 80)... "
if nc -z -w2 $SERVER_IP 80 > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FALHOU${NC}"
fi

# Teste 7: Samba
echo -n "Samba (porta 445)... "
if nc -z -w2 $SERVER_IP 445 > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FALHOU${NC}"
fi

# Teste 8: NFS
echo -n "NFS (porta 2049)... "
if nc -z -w2 $SERVER_IP 2049 > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FALHOU${NC}"
fi

# Teste 9: Email SMTP
echo -n "Email SMTP (porta 25)... "
if nc -z -w2 $SERVER_IP 25 > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FALHOU${NC}"
fi

echo ""
echo "=========================================="
EOF
    chmod +x /usr/local/bin/testar_servidor.sh
    
    # Criar atalho na área de trabalho para usuários
    cat > /usr/local/bin/criar_atalhos_usuario.sh <<'EOF'
#!/bin/bash
USUARIO=${SUDO_USER:-$USER}
DESKTOP_DIR="/home/$USUARIO/Desktop"

if [ -d "$DESKTOP_DIR" ]; then
    # Atalho para compartilhamento Samba
    cat > "$DESKTOP_DIR/Servidor-Samba.desktop" <<EODESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=Compartilhamento Samba
Comment=Acessar arquivos compartilhados
Exec=nautilus /mnt/samba_servidor
Icon=folder-remote
Terminal=false
EODESKTOP
    
    # Atalho para NFS
    cat > "$DESKTOP_DIR/Servidor-NFS.desktop" <<EODESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=Compartilhamento NFS
Comment=Acessar NFS do servidor
Exec=nautilus /mnt/nfs_servidor
Icon=folder-remote
Terminal=false
EODESKTOP
    
    chmod +x "$DESKTOP_DIR"/*.desktop
    chown $USUARIO:$USUARIO "$DESKTOP_DIR"/*.desktop
    echo "Atalhos criados na área de trabalho de $USUARIO"
fi
EOF
    chmod +x /usr/local/bin/criar_atalhos_usuario.sh
    
    # Etapa 9: Testar montagens
    print_header "9. TESTANDO MONTAGENS"
    
    log_info "Tentando montar Samba..."
    /usr/local/bin/montar_samba.sh || log_warn "Falha ao montar Samba"
    
    log_info "Tentando montar NFS..."
    /usr/local/bin/montar_nfs.sh || log_warn "Falha ao montar NFS"
    
    # Etapa 10: Resumo final
    print_header "INSTALAÇÃO CONCLUÍDA!"
    echo ""
    echo "=========================================="
    echo "INFORMAÇÕES DO CLIENTE"
    echo "=========================================="
    echo "Servidor: $SERVER_IP"
    echo "Interface: $INTERFACE_LAN"
    echo ""
    echo "SERVIÇOS CONFIGURADOS:"
    echo "  • DHCP Client (automático)"
    echo "  • Proxy: http://$SERVER_IP:$PROXY_PORT"
    echo "  • Samba: $SAMBA_MOUNT_POINT"
    echo "  • NFS: $NFS_MOUNT_POINT"
    echo "  • Email relay via $SERVER_IP"
    echo ""
    echo "COMANDOS ÚTEIS:"
    echo "  • Testar servidor: sudo testar_servidor.sh"
    echo "  • Montar Samba: sudo /usr/local/bin/montar_samba.sh"
    echo "  • Montar NFS: sudo /usr/local/bin/montar_nfs.sh"
    echo "  • Criar atalhos: sudo /usr/local/bin/criar_atalhos_usuario.sh"
    echo ""
    echo "CONFIGURAÇÕES DE PROXY:"
    echo "  • Sistema: /etc/environment"
    echo "  • APT: /etc/apt/apt.conf.d/95proxies"
    echo "  • Firefox: Configure manualmente em Preferences"
    echo ""
    echo "ACESSO AO SERVIDOR:"
    echo "  • Web: http://$SERVER_IP"
    echo "  • phpMyAdmin: http://$SERVER_IP/phpmyadmin"
    echo "  • Samba: //$SERVER_IP/Compartilhado"
    echo ""
    echo "Log completo: $LOG_FILE"
    echo "=========================================="
    echo ""
    
    # Executar teste de conectividade
    log_info "Executando teste de conectividade..."
    /usr/local/bin/testar_servidor.sh
}

# ============================================================================
# EXECUÇÃO
# ============================================================================

check_root
instalar_cliente

log_info "Reinicie o sistema para garantir que todas as configurações sejam aplicadas"
read -p "Deseja reiniciar agora? (s/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Ss]$ ]]; then
    log_info "Reiniciando em 5 segundos..."
    sleep 5
    reboot
fi