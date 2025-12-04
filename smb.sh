#!/bin/bash

# Script Gerenciador de Samba - Ubuntu/Zorin
# Funções: Instalação, Configuração, Reparo, Reset
# Autor: Samba Manager
# Data: 2025

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Função para log
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

# Verificar se é root
if [[ $EUID -ne 0 ]]; then
   error "Este script precisa ser executado como root (sudo)"
   exit 1
fi

# Detectar IP da interface principal
get_primary_ip() {
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1
}

# Verificar se Samba está instalado
check_samba_installed() {
    dpkg -l | grep -q "^ii.*samba " && return 0 || return 1
}

# Verificar se Samba está rodando
check_samba_running() {
    systemctl is-active --quiet smbd && systemctl is-active --quiet nmbd && return 0 || return 1
}

# ============================================
# MENU PRINCIPAL
# ============================================

show_menu() {
    clear
    echo -e "${CYAN}=========================================="
    echo -e "    GERENCIADOR DE SAMBA"
    echo -e "==========================================${NC}"
    echo ""
    
    # Status do Samba
    if check_samba_installed; then
        if check_samba_running; then
            echo -e "Status: ${GREEN}● Instalado e Rodando${NC}"
        else
            echo -e "Status: ${YELLOW}● Instalado mas Parado${NC}"
        fi
    else
        echo -e "Status: ${RED}● Não Instalado${NC}"
    fi
    
    echo ""
    echo -e "${MAGENTA}Opções Disponíveis:${NC}"
    echo ""
    echo "  1) Instalação Completa do Samba (Servidor)"
    echo "  2) Instalação do Cliente Samba"
    echo "  3) Reparar/Reconfigurar Samba"
    echo "  4) Adicionar Novo Usuário"
    echo "  5) Adicionar Novo Compartilhamento"
    echo "  6) Listar Compartilhamentos Ativos"
    echo "  7) Testar Conectividade Samba"
    echo "  8) Ver Logs do Samba"
    echo "  9) Resetar Completamente o Samba"
    echo "  10) Status e Informações"
    echo "  0) Sair"
    echo ""
    echo -e "${CYAN}==========================================${NC}"
}

# ============================================
# 1. INSTALAÇÃO COMPLETA DO SERVIDOR SAMBA
# ============================================

install_samba_server() {
    log "Iniciando instalação do Samba Server..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    # Atualizar repositórios
    log "Atualizando repositórios..."
    apt-get update
    
    # Instalar Samba
    log "Instalando pacotes do Samba..."
    apt-get install -y samba samba-common-bin smbclient cifs-utils
    
    # Backup da configuração original
    if [ -f /etc/samba/smb.conf ]; then
        cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.$(date +%Y%m%d_%H%M%S)
        log "Backup da configuração criado"
    fi
    
    # Obter informações
    echo ""
    read -p "Digite o nome do domínio/workgroup [WORKGROUP]: " WORKGROUP
    WORKGROUP=${WORKGROUP:-WORKGROUP}
    
    read -p "Digite o nome do servidor [$(hostname)]: " SERVERNAME
    SERVERNAME=${SERVERNAME:-$(hostname)}
    
    read -p "Digite a interface de rede (ex: enp0s3, enp0s8) [auto]: " INTERFACE
    if [ -z "$INTERFACE" ] || [ "$INTERFACE" = "auto" ]; then
        INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
        info "Interface detectada automaticamente: $INTERFACE"
    fi
    
    SERVER_IP=$(get_primary_ip)
    info "IP do servidor: $SERVER_IP"
    
    # Criar diretórios padrão
    log "Criando diretórios de compartilhamento..."
    mkdir -p /srv/samba/publico
    mkdir -p /srv/samba/privado
    mkdir -p /srv/samba/compartilhado
    
    chmod 777 /srv/samba/publico
    chmod 770 /srv/samba/privado
    chmod 775 /srv/samba/compartilhado
    
    # Criar arquivo de configuração
    log "Configurando Samba..."
    cat > /etc/samba/smb.conf <<EOF
# Configuração do Samba Server
# Gerado automaticamente em $(date)

[global]
   # Identificação
   workgroup = ${WORKGROUP}
   server string = Samba Server - ${SERVERNAME}
   netbios name = ${SERVERNAME}
   
   # Segurança
   security = user
   passdb backend = tdbsam
   map to guest = bad user
   guest account = nobody
   
   # Rede
   interfaces = ${SERVER_IP}/24 127.0.0.1
   bind interfaces only = yes
   
   # Logs
   log file = /var/log/samba/log.%m
   max log size = 1000
   log level = 1
   
   # Performance
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=65536 SO_SNDBUF=65536
   read raw = yes
   write raw = yes
   max xmit = 65535
   dead time = 15
   
   # Charset
   unix charset = UTF-8
   dos charset = CP850
   
   # Outros
   dns proxy = no
   server role = standalone server
   obey pam restrictions = yes
   unix password sync = yes
   pam password change = yes

# ========================================
# COMPARTILHAMENTOS
# ========================================

[Publico]
   comment = Compartilhamento Público - Acesso Livre
   path = /srv/samba/publico
   browseable = yes
   writable = yes
   guest ok = yes
   guest only = yes
   create mask = 0777
   directory mask = 0777
   force user = nobody
   force group = nogroup

[Privado]
   comment = Compartilhamento Privado - Autenticação Necessária
   path = /srv/samba/privado
   browseable = yes
   writable = yes
   guest ok = no
   valid users = @sambausers
   create mask = 0770
   directory mask = 0770
   force group = sambausers

[Compartilhado]
   comment = Compartilhamento Misto
   path = /srv/samba/compartilhado
   browseable = yes
   writable = yes
   guest ok = yes
   create mask = 0775
   directory mask = 0775

[homes]
   comment = Diretórios Home dos Usuários
   browseable = no
   writable = yes
   valid users = %S
   create mask = 0700
   directory mask = 0700
EOF
    
    # Criar grupo sambausers
    groupadd sambausers 2>/dev/null || true
    
    # Verificar configuração
    log "Verificando configuração..."
    if testparm -s &>/dev/null; then
        success "Configuração válida!"
    else
        error "Erro na configuração do Samba"
        testparm -s
        return 1
    fi
    
    # Configurar firewall
    log "Configurando firewall..."
    ufw allow 139/tcp comment 'Samba NetBIOS Session' 2>/dev/null || true
    ufw allow 445/tcp comment 'Samba SMB' 2>/dev/null || true
    ufw allow 137/udp comment 'Samba NetBIOS Name' 2>/dev/null || true
    ufw allow 138/udp comment 'Samba NetBIOS Datagram' 2>/dev/null || true
    
    # Habilitar e iniciar serviços
    log "Iniciando serviços..."
    systemctl enable smbd
    systemctl enable nmbd
    systemctl restart smbd
    systemctl restart nmbd
    
    # Criar usuário padrão
    echo ""
    read -p "Deseja criar um usuário Samba agora? (s/n): " CREATE_USER
    if [[ "$CREATE_USER" =~ ^[Ss]$ ]]; then
        add_samba_user
    fi
    
    # Resumo
    echo ""
    success "=========================================="
    success "SAMBA INSTALADO COM SUCESSO!"
    success "=========================================="
    echo ""
    info "📁 Compartilhamentos criados:"
    info "  • //${SERVER_IP}/Publico (sem senha)"
    info "  • //${SERVER_IP}/Privado (com senha)"
    info "  • //${SERVER_IP}/Compartilhado (misto)"
    echo ""
    info "🔧 Comandos úteis:"
    info "  • Ver compartilhamentos: smbclient -L ${SERVER_IP} -N"
    info "  • Status: systemctl status smbd"
    info "  • Logs: tail -f /var/log/samba/log.smbd"
    echo ""
    
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# 2. INSTALAÇÃO DO CLIENTE SAMBA
# ============================================

install_samba_client() {
    log "Iniciando instalação do Cliente Samba..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    # Instalar pacotes
    apt-get update
    apt-get install -y smbclient cifs-utils
    
    echo ""
    read -p "Digite o IP do servidor Samba: " SERVER_IP
    read -p "Digite o nome de usuário: " USERNAME
    read -sp "Digite a senha: " PASSWORD
    echo ""
    
    # Criar diretórios de montagem
    mkdir -p /mnt/samba/publico
    mkdir -p /mnt/samba/privado
    mkdir -p /mnt/samba/compartilhado
    
    # Criar arquivo de credenciais
    cat > /root/.smbcredentials <<EOF
username=${USERNAME}
password=${PASSWORD}
domain=WORKGROUP
EOF
    chmod 600 /root/.smbcredentials
    
    # Adicionar ao fstab
    if ! grep -q "/mnt/samba" /etc/fstab; then
        cat >> /etc/fstab <<EOF

# Compartilhamentos Samba
//${SERVER_IP}/Publico /mnt/samba/publico cifs guest,uid=1000,iocharset=utf8,vers=3.0,_netdev 0 0
//${SERVER_IP}/Privado /mnt/samba/privado cifs credentials=/root/.smbcredentials,uid=1000,iocharset=utf8,vers=3.0,_netdev 0 0
//${SERVER_IP}/Compartilhado /mnt/samba/compartilhado cifs guest,uid=1000,iocharset=utf8,vers=3.0,_netdev 0 0
EOF
    fi
    
    # Tentar montar
    log "Montando compartilhamentos..."
    mount -a 2>/dev/null || warning "Alguns compartilhamentos não puderam ser montados"
    
    # Verificar montagens
    echo ""
    if mount | grep -q "/mnt/samba"; then
        success "Cliente Samba instalado e compartilhamentos montados!"
        echo ""
        info "Compartilhamentos disponíveis em:"
        mount | grep "/mnt/samba" | awk '{print "  • "$3}'
    else
        warning "Cliente instalado, mas compartilhamentos não foram montados"
        info "Verifique a conectividade com: ping ${SERVER_IP}"
    fi
    
    echo ""
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# 3. REPARAR/RECONFIGURAR SAMBA
# ============================================

repair_samba() {
    log "Iniciando reparo do Samba..."
    
    if ! check_samba_installed; then
        error "Samba não está instalado. Use a opção 1 para instalar."
        read -p "Pressione ENTER para continuar..."
        return
    fi
    
    echo ""
    echo "Opções de reparo:"
    echo "  1) Reparar serviços (reiniciar)"
    echo "  2) Reparar permissões"
    echo "  3) Reparar configuração (resetar para padrão)"
    echo "  4) Reparar tudo"
    echo ""
    read -p "Escolha uma opção: " REPAIR_OPTION
    
    case $REPAIR_OPTION in
        1)
            log "Reparando serviços..."
            systemctl stop smbd nmbd 2>/dev/null || true
            sleep 2
            systemctl start smbd nmbd
            systemctl enable smbd nmbd
            success "Serviços reiniciados"
            ;;
        2)
            log "Reparando permissões..."
            chmod 777 /srv/samba/publico 2>/dev/null || true
            chmod 770 /srv/samba/privado 2>/dev/null || true
            chmod 775 /srv/samba/compartilhado 2>/dev/null || true
            chown -R root:sambausers /srv/samba/privado 2>/dev/null || true
            success "Permissões reparadas"
            ;;
        3)
            log "Reparando configuração..."
            if [ -f /etc/samba/smb.conf.backup.* ]; then
                LATEST_BACKUP=$(ls -t /etc/samba/smb.conf.backup.* | head -1)
                cp "$LATEST_BACKUP" /etc/samba/smb.conf
                success "Configuração restaurada do backup"
            else
                warning "Nenhum backup encontrado. Reconfigure manualmente ou reinstale."
            fi
            testparm -s
            systemctl restart smbd nmbd
            ;;
        4)
            log "Reparando tudo..."
            systemctl stop smbd nmbd 2>/dev/null || true
            chmod 777 /srv/samba/publico 2>/dev/null || true
            chmod 770 /srv/samba/privado 2>/dev/null || true
            chmod 775 /srv/samba/compartilhado 2>/dev/null || true
            testparm -s &>/dev/null || warning "Configuração pode estar inválida"
            systemctl start smbd nmbd
            systemctl enable smbd nmbd
            success "Reparo completo realizado"
            ;;
        *)
            error "Opção inválida"
            ;;
    esac
    
    echo ""
    if check_samba_running; then
        success "Samba está rodando corretamente"
    else
        error "Samba ainda apresenta problemas. Verifique os logs."
    fi
    
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# 4. ADICIONAR NOVO USUÁRIO
# ============================================

add_samba_user() {
    echo ""
    read -p "Nome do usuário: " NEW_USER
    
    # Verificar se usuário Unix existe
    if ! id "$NEW_USER" &>/dev/null; then
        read -p "Usuário Unix não existe. Criar? (s/n): " CREATE_UNIX
        if [[ "$CREATE_UNIX" =~ ^[Ss]$ ]]; then
            useradd -m -s /bin/bash "$NEW_USER"
            success "Usuário Unix criado"
        else
            error "Usuário precisa existir no sistema Unix primeiro"
            return 1
        fi
    fi
    
    # Adicionar ao grupo sambausers
    usermod -aG sambausers "$NEW_USER" 2>/dev/null || true
    
    # Definir senha do Samba
    smbpasswd -a "$NEW_USER"
    smbpasswd -e "$NEW_USER"
    
    # Criar diretório home se não existir
    mkdir -p /srv/samba/privado/"$NEW_USER"
    chown "$NEW_USER":sambausers /srv/samba/privado/"$NEW_USER"
    chmod 700 /srv/samba/privado/"$NEW_USER"
    
    success "Usuário $NEW_USER adicionado ao Samba"
    
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# 5. ADICIONAR NOVO COMPARTILHAMENTO
# ============================================

add_share() {
    echo ""
    read -p "Nome do compartilhamento: " SHARE_NAME
    read -p "Caminho completo: " SHARE_PATH
    read -p "Comentário/Descrição: " SHARE_COMMENT
    
    # Criar diretório se não existir
    if [ ! -d "$SHARE_PATH" ]; then
        mkdir -p "$SHARE_PATH"
        chmod 775 "$SHARE_PATH"
    fi
    
    echo ""
    echo "Opções de acesso:"
    echo "  1) Público (sem senha)"
    echo "  2) Privado (com autenticação)"
    read -p "Escolha: " ACCESS_TYPE
    
    # Adicionar ao smb.conf
    if [ "$ACCESS_TYPE" = "1" ]; then
        cat >> /etc/samba/smb.conf <<EOF

[${SHARE_NAME}]
   comment = ${SHARE_COMMENT}
   path = ${SHARE_PATH}
   browseable = yes
   writable = yes
   guest ok = yes
   create mask = 0775
   directory mask = 0775
EOF
    else
        cat >> /etc/samba/smb.conf <<EOF

[${SHARE_NAME}]
   comment = ${SHARE_COMMENT}
   path = ${SHARE_PATH}
   browseable = yes
   writable = yes
   guest ok = no
   valid users = @sambausers
   create mask = 0770
   directory mask = 0770
EOF
    fi
    
    # Verificar e reiniciar
    if testparm -s &>/dev/null; then
        systemctl reload smbd
        success "Compartilhamento '${SHARE_NAME}' adicionado!"
    else
        error "Erro na configuração. Verifique /etc/samba/smb.conf"
    fi
    
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# 6. LISTAR COMPARTILHAMENTOS
# ============================================

list_shares() {
    log "Compartilhamentos ativos:"
    echo ""
    
    if check_samba_running; then
        SERVER_IP=$(get_primary_ip)
        smbclient -L "${SERVER_IP}" -N 2>/dev/null | grep "Disk" || warning "Nenhum compartilhamento encontrado"
    else
        error "Samba não está rodando"
    fi
    
    echo ""
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# 7. TESTAR CONECTIVIDADE
# ============================================

test_samba() {
    log "Testando Samba..."
    echo ""
    
    # Verificar se está rodando
    if check_samba_running; then
        success "Serviços Samba: Rodando"
    else
        error "Serviços Samba: Parados"
    fi
    
    # Testar portas
    SERVER_IP=$(get_primary_ip)
    
    echo ""
    info "Testando portas..."
    
    if timeout 2 bash -c "cat < /dev/null > /dev/tcp/${SERVER_IP}/139" 2>/dev/null; then
        success "Porta 139 (NetBIOS): Aberta"
    else
        error "Porta 139: Fechada"
    fi
    
    if timeout 2 bash -c "cat < /dev/null > /dev/tcp/${SERVER_IP}/445" 2>/dev/null; then
        success "Porta 445 (SMB): Aberta"
    else
        error "Porta 445: Fechada"
    fi
    
    # Listar compartilhamentos
    echo ""
    info "Compartilhamentos disponíveis:"
    smbclient -L "${SERVER_IP}" -N 2>/dev/null | grep "Disk" || warning "Erro ao listar"
    
    echo ""
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# 8. VER LOGS
# ============================================

view_logs() {
    echo ""
    echo "Opções de logs:"
    echo "  1) Log principal (últimas 50 linhas)"
    echo "  2) Log em tempo real (Ctrl+C para sair)"
    echo "  3) Log de erros"
    echo ""
    read -p "Escolha: " LOG_OPTION
    
    case $LOG_OPTION in
        1)
            tail -n 50 /var/log/samba/log.smbd 2>/dev/null || error "Log não encontrado"
            ;;
        2)
            tail -f /var/log/samba/log.smbd 2>/dev/null || error "Log não encontrado"
            ;;
        3)
            grep -i "error\|failed\|denied" /var/log/samba/log.smbd 2>/dev/null | tail -n 30 || warning "Nenhum erro encontrado"
            ;;
        *)
            error "Opção inválida"
            ;;
    esac
    
    echo ""
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# 9. RESET COMPLETO
# ============================================

reset_samba() {
    echo ""
    echo -e "${RED}=========================================="
    echo -e "  AVISO: RESET COMPLETO DO SAMBA"
    echo -e "==========================================${NC}"
    echo ""
    echo "Esta ação irá:"
    echo "  • Parar todos os serviços Samba"
    echo "  • Remover todos os pacotes"
    echo "  • Deletar todas as configurações"
    echo "  • Remover compartilhamentos"
    echo ""
    read -p "Tem certeza? Digite 'RESETAR' para confirmar: " CONFIRM
    
    if [ "$CONFIRM" != "RESETAR" ]; then
        warning "Reset cancelado"
        read -p "Pressione ENTER para continuar..."
        return
    fi
    
    log "Parando serviços..."
    systemctl stop smbd nmbd 2>/dev/null || true
    
    log "Removendo pacotes..."
    apt-get remove --purge -y samba samba-common samba-common-bin smbclient 2>/dev/null || true
    apt-get autoremove -y
    
    log "Removendo configurações..."
    rm -rf /etc/samba
    rm -rf /var/lib/samba
    rm -rf /var/log/samba
    rm -rf /srv/samba
    rm -f /root/.smbcredentials
    
    log "Removendo montagens..."
    sed -i '/samba/d' /etc/fstab
    umount /mnt/samba/* 2>/dev/null || true
    rm -rf /mnt/samba
    
    success "Samba completamente removido!"
    
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# 10. STATUS E INFORMAÇÕES
# ============================================

show_status() {
    clear
    echo -e "${CYAN}=========================================="
    echo -e "    STATUS DO SAMBA"
    echo -e "==========================================${NC}"
    echo ""
    
    # Status de instalação
    if check_samba_installed; then
        success "Samba: Instalado"
        
        # Versão
        SAMBA_VERSION=$(smbd --version | awk '{print $2}')
        info "Versão: $SAMBA_VERSION"
        echo ""
        
        # Status dos serviços
        if check_samba_running; then
            success "Serviços: Rodando"
        else
            error "Serviços: Parados"
        fi
        
        echo ""
        
        # Compartilhamentos
        info "Compartilhamentos configurados:"
        grep "^\[" /etc/samba/smb.conf 2>/dev/null | grep -v "global\|homes" || warning "Nenhum"
        
        echo ""
        
        # Usuários
        info "Usuários Samba:"
        pdbedit -L 2>/dev/null || warning "Nenhum usuário cadastrado"
        
        echo ""
        
        # IP e acesso
        SERVER_IP=$(get_primary_ip)
        info "Acesso aos compartilhamentos:"
        info "  smb://${SERVER_IP}/"
        info "  \\\\${SERVER_IP}\\"
        
    else
        error "Samba: Não instalado"
    fi
    
    echo ""
    echo -e "${CYAN}==========================================${NC}"
    read -p "Pressione ENTER para continuar..."
}

# ============================================
# LOOP PRINCIPAL
# ============================================

while true; do
    show_menu
    read -p "Escolha uma opção: " option
    
    case $option in
        1) install_samba_server ;;
        2) install_samba_client ;;
        3) repair_samba ;;
        4) add_samba_user ;;
        5) add_share ;;
        6) list_shares ;;
        7) test_samba ;;
        8) view_logs ;;
        9) reset_samba ;;
        10) show_status ;;
        0)
            echo ""
            log "Saindo..."
            exit 0
            ;;
        *)
            error "Opção inválida!"
            sleep 2
            ;;
    esac
done
