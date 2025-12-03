#!/bin/bash
# Script de Remoção Completa do Samba - Cliente e Servidor
# Remove Samba e todas as suas dependências/configurações

set -euo pipefail

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LOG_FILE="/var/log/remocao_samba_$(date +%Y%m%d_%H%M%S).log"
BACKUP_DIR="/root/backup_samba_$(date +%Y%m%d_%H%M%S)"

# Funções de logging
print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "INFO: $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
    echo "AVISO: $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERRO]${NC} $1"
    echo "ERRO: $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Verificar se é root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Execute como root: sudo $0"
        exit 1
    fi
}

# Detectar se é cliente ou servidor
detectar_tipo() {
    print_header "DETECTANDO TIPO DE SISTEMA"
    
    # Verificar se está rodando serviços de servidor Samba
    if systemctl list-unit-files | grep -q "smbd.service" && \
       systemctl is-active --quiet smbd 2>/dev/null; then
        echo -e "${YELLOW}Serviços Samba ativos detectados${NC}"
        read -p "Este sistema parece ser um SERVIDOR Samba. Confirmar? (s/n): " confirm
        
        if [ "$confirm" = "s" ] || [ "$confirm" = "S" ]; then
            TIPO="servidor"
            log_info "Sistema identificado como SERVIDOR Samba"
        else
            TIPO="cliente"
            log_info "Sistema identificado como CLIENTE Samba"
        fi
    else
        # Verificar se pacotes Samba estão instalados
        if dpkg -l | grep -q "samba\|smbclient"; then
            TIPO="cliente"
            log_info "Sistema identificado como CLIENTE Samba (pacotes instalados)"
        else
            TIPO="desconhecido"
            log_warn "Samba não parece estar instalado neste sistema"
        fi
    fi
    
    echo ""
}

# Criar backup de configurações
criar_backup() {
    print_header "CRIANDO BACKUP DE CONFIGURAÇÕES"
    
    mkdir -p "$BACKUP_DIR"
    log_info "Backup será salvo em: $BACKUP_DIR"
    
    # Backup de arquivos de configuração
    if [ -f "/etc/samba/smb.conf" ]; then
        cp /etc/samba/smb.conf "$BACKUP_DIR/smb.conf"
        log_info "Backup do smb.conf criado"
    fi
    
    if [ -f "/etc/samba/smb.conf.backup" ]; then
        cp /etc/samba/smb.conf.backup "$BACKUP_DIR/smb.conf.backup"
    fi
    
    # Backup de usuários Samba
    if [ -f "/etc/samba/smbpasswd" ]; then
        cp /etc/samba/smbpasswd "$BACKUP_DIR/smbpasswd"
        log_info "Backup do smbpasswd criado"
    fi
    
    if [ -f "/var/lib/samba/private/secrets.tdb" ]; then
        cp /var/lib/samba/private/secrets.tdb "$BACKUP_DIR/secrets.tdb" 2>/dev/null || true
    fi
    
    # Listar compartilhamentos ativos
    if command -v smbstatus &>/dev/null; then
        smbstatus > "$BACKUP_DIR/smbstatus.txt" 2>/dev/null || true
    fi
    
    # Backup de configurações de rede relacionadas
    if [ -f "/etc/netplan/"* ]; then
        cp /etc/netplan/*.yaml "$BACKUP_DIR/" 2>/dev/null || true
    fi
    
    # Listar pacotes instalados
    dpkg -l | grep -i samba > "$BACKUP_DIR/pacotes_samba.txt" 2>/dev/null || true
    
    log_info "Backup completo criado em $BACKUP_DIR"
    echo ""
}

# Remover serviços Samba
remover_servicos() {
    print_header "PARANDO E REMOVENDO SERVIÇOS SAMBA"
    
    # Lista de serviços Samba
    SERVICOS=("smbd" "nmbd" "winbind" "samba-ad-dc")
    
    for servico in "${SERVICOS[@]}"; do
        if systemctl list-unit-files | grep -q "$servico.service"; then
            log_info "Parando serviço: $servico"
            systemctl stop "$servico" 2>/dev/null || true
            systemctl disable "$servico" 2>/dev/null || true
            systemctl mask "$servico" 2>/dev/null || true
            log_info "Serviço $servico parado e desabilitado"
        fi
    done
    
    # Remover timers
    if systemctl list-timers | grep -q samba; then
        systemctl stop samba.timer 2>/dev/null || true
        systemctl disable samba.timer 2>/dev/null || true
    fi
    
    echo ""
}

# Remover pacotes Samba
remover_pacotes() {
    print_header "REMOVENDO PACOTES SAMBA"
    
    # Lista de pacotes Samba para remover
    PACOTES_SAMBA=(
        "samba" "samba-common" "samba-common-bin" "samba-libs" "samba-vfs-modules"
        "smbclient" "libsmbclient" "libwbclient0" "samba-dsdb-modules"
        "samba-client" "samba-client-libs" "cifs-utils"
        "winbind" "libpam-winbind" "libnss-winbind"
        "samba-ad-dc" "samba-dc" "samba-tools"
    )
    
    echo "Pacotes Samba instalados atualmente:"
    echo "-------------------------------------"
    dpkg -l | grep -i samba | awk '{print $2 " (" $3 ")"}' || echo "Nenhum pacote encontrado"
    echo ""
    
    # Remover pacotes
    for pacote in "${PACOTES_SAMBA[@]}"; do
        if dpkg -l | grep -q "^ii.*$pacote"; then
            log_info "Removendo pacote: $pacote"
            apt-get remove --purge -y "$pacote" 2>/dev/null || \
            apt-get remove --purge -y "$pacote" 2>/dev/null || true
        fi
    done
    
    # Remover pacotes restantes relacionados a Samba
    log_info "Removendo pacotes restantes relacionados ao Samba..."
    apt-get remove --purge -y '*samba*' '*smb*' '*winbind*' '*cifs*' 2>/dev/null || true
    
    # Limpar dependências não utilizadas
    log_info "Limpando dependências não utilizadas..."
    apt-get autoremove -y
    apt-get autoclean
    
    echo ""
}

# Remover configurações e arquivos residuais
limpar_configuracoes() {
    print_header "REMOVENDO CONFIGURAÇÕES E ARQUIVOS RESIDUAIS"
    
    # Remover arquivos de configuração
    CONFIG_FILES=(
        "/etc/samba"
        "/var/lib/samba"
        "/var/cache/samba"
        "/var/log/samba"
        "/var/run/samba"
        "/var/spool/samba"
        "/usr/share/samba"
        "/usr/lib/samba"
        "/etc/default/samba"
    )
    
    for dir in "${CONFIG_FILES[@]}"; do
        if [ -d "$dir" ] || [ -f "$dir" ]; then
            log_info "Removendo: $dir"
            rm -rf "$dir" 2>/dev/null || true
        fi
    done
    
    # Remover arquivos específicos
    rm -f /etc/cron.daily/samba 2>/dev/null || true
    rm -f /etc/logrotate.d/samba 2>/dev/null || true
    rm -f /etc/ufw/applications.d/samba 2>/dev/null || true
    
    # Remover do PAM
    if [ -f "/etc/pam.d/common-session" ]; then
        sed -i '/pam_winbind.so/d' /etc/pam.d/common-session 2>/dev/null || true
        sed -i '/pam_mkhomedir.so/d' /etc/pam.d/common-session 2>/dev/null || true
    fi
    
    # Remover do NSS
    if [ -f "/etc/nsswitch.conf" ]; then
        sed -i 's/ winbind//g' /etc/nsswitch.conf 2>/dev/null || true
        sed -i 's/ wins//g' /etc/nsswitch.conf 2>/dev/null || true
    fi
    
    # Remover do fstab (montagens CIFS)
    if [ -f "/etc/fstab" ]; then
        cp /etc/fstab /etc/fstab.backup.samba
        grep -v "//" /etc/fstab | grep -v "type cifs" > /etc/fstab.tmp
        mv /etc/fstab.tmp /etc/fstab
        log_info "Montagens CIFS removidas do fstab (backup em /etc/fstab.backup.samba)"
    fi
    
    echo ""
}

# Remover compartilhamentos e diretórios
remover_compartilhamentos() {
    print_header "REMOVENDO COMPARTILHAMENTOS E DIRETÓRIOS"
    
    # Lista de diretórios comuns de compartilhamento
    DIRS_COMPARTILHADOS=(
        "/srv/samba"
        "/var/samba"
        "/home/samba"
        "/compartilhado"
        "/Compartilhado"
        "/shared"
        "/srv/compartilhado"
        "/data/share"
    )
    
    read -p "Deseja remover diretórios de compartilhamento? (s/n): " remover_dirs
    
    if [ "$remover_dirs" = "s" ] || [ "$remover_dirs" = "S" ]; then
        for dir in "${DIRS_COMPARTILHADOS[@]}"; do
            if [ -d "$dir" ]; then
                echo "Diretório encontrado: $dir"
                echo "Conteúdo:"
                ls -la "$dir/" 2>/dev/null | head -10 || true
                
                read -p "Remover este diretório? (s/n): " confirm_dir
                if [ "$confirm_dir" = "s" ] || [ "$confirm_dir" = "S" ]; then
                    # Fazer backup do conteúdo
                    if [ "$(ls -A "$dir" 2>/dev/null)" ]; then
                        mkdir -p "$BACKUP_DIR/compartilhamentos"
                        cp -r "$dir" "$BACKUP_DIR/compartilhamentos/" 2>/dev/null || true
                        log_info "Backup do compartilhamento $dir criado"
                    fi
                    
                    rm -rf "$dir"
                    log_info "Diretório $dir removido"
                else
                    log_info "Diretório $dir mantido"
                fi
            fi
        done
    else
        log_info "Diretórios de compartilhamento mantidos"
    fi
    
    echo ""
}

# Remover usuários Samba
remover_usuarios() {
    print_header "REMOVENDO USUÁRIOS SAMBA"
    
    # Listar usuários Samba
    if [ -f "/etc/passwd" ]; then
        echo "Usuários de sistema que podem ser do Samba:"
        echo "------------------------------------------"
        
        # Usuários com UID baixo e shell /sbin/nologin ou /bin/false (comuns no Samba)
        getent passwd | awk -F: '$3 < 1000 && ($7 ~ /nologin|false/) {print $1 " (UID:" $3 ")"}' | head -20
        
        echo ""
        read -p "Deseja remover usuários do Samba? (s/n): " remover_users
        
        if [ "$remover_users" = "s" ] || [ "$remover_users" = "S" ]; then
            read -p "Digite os nomes de usuário para remover (separados por espaço): " users_to_remove
            
            for user in $users_to_remove; do
                if id "$user" &>/dev/null; then
                    # Verificar se é seguro remover
                    HOME_DIR=$(getent passwd "$user" | cut -d: -f6)
                    echo "Usuário: $user"
                    echo "Diretório home: $HOME_DIR"
                    
                    read -p "Remover usuário $user e seu diretório home? (s/n): " confirm_user
                    if [ "$confirm_user" = "s" ] || [ "$confirm_user" = "S" ]; then
                        # Fazer backup
                        if [ -d "$HOME_DIR" ]; then
                            mkdir -p "$BACKUP_DIR/usuarios"
                            cp -r "$HOME_DIR" "$BACKUP_DIR/usuarios/$user" 2>/dev/null || true
                        fi
                        
                        userdel -r "$user" 2>/dev/null || true
                        log_info "Usuário $user removido"
                    else
                        log_info "Usuário $user mantido"
                    fi
                fi
            done
        fi
    fi
    
    # Remover entradas do smbpasswd do /etc/passwd
    if command -v pdbedit &>/dev/null; then
        pdbedit -L 2>/dev/null | while read -r line; do
            user=$(echo "$line" | cut -d: -f1)
            log_warn "Usuário Samba ainda existe: $user (use 'pdbedit -x $user' para remover)"
        done
    fi
    
    echo ""
}

# Remover regras de firewall
remover_firewall() {
    print_header "REMOVENDO REGRAS DE FIREWALL"
    
    if command -v ufw &>/dev/null; then
        if ufw status | grep -q "Status: active"; then
            echo "Regras UFW relacionadas ao Samba:"
            echo "---------------------------------"
            ufw status numbered | grep -i "samba\|smb\|netbios\|137\|138\|139\|445" || echo "Nenhuma regra encontrada"
            
            echo ""
            read -p "Deseja remover regras do Samba do UFW? (s/n): " remover_ufw
            
            if [ "$remover_ufw" = "s" ] || [ "$remover_ufw" = "S" ]; then
                # Remover por número ou aplicação
                ufw delete allow samba 2>/dev/null || true
                ufw delete allow 'Samba' 2>/dev/null || true
                
                # Remover por porta
                for porta in 137 138 139 445; do
                    ufw delete allow $porta/tcp 2>/dev/null || true
                    ufw delete allow $porta/udp 2>/dev/null || true
                done
                
                log_info "Regras Samba removidas do UFW"
            fi
        fi
    fi
    
    # iptables direto
    if iptables -L -n | grep -q "samba\|smb\|137\|138\|139\|445"; then
        log_warn "Regras iptables relacionadas ao Samba detectadas"
        echo "Use 'iptables -L -n' para visualizar e 'iptables -D' para remover"
    fi
    
    echo ""
}

# Limpar cache e temporários
limpar_cache() {
    print_header "LIMPANDO CACHE E ARQUIVOS TEMPORÁRIOS"
    
    # Limpar cache do sistema
    log_info "Limpando cache do sistema..."
    apt-get clean
    updatedb 2>/dev/null || true
    
    # Limpar arquivos .tdb
    find /var/lib /var/cache /tmp /run -name "*.tdb" -type f -delete 2>/dev/null || true
    
    # Limpar sockets antigos
    find /run -name "*samba*" -type s -delete 2>/dev/null || true
    
    # Limpar lock files
    find /var/lock -name "*samba*" -type f -delete 2>/dev/null || true
    
    log_info "Cache limpo"
    echo ""
}

# Verificar remoção completa
verificar_remocao() {
    print_header "VERIFICANDO REMOÇÃO COMPLETA"
    
    echo "1. Verificando pacotes remanescentes..."
    PACOTES_RESTANTES=$(dpkg -l | grep -i samba | wc -l)
    if [ "$PACOTES_RESTANTES" -gt 0 ]; then
        log_warn "Ainda existem $PACOTES_RESTANTES pacotes Samba instalados:"
        dpkg -l | grep -i samba
    else
        log_info "✓ Nenhum pacote Samba encontrado"
    fi
    
    echo ""
    echo "2. Verificando serviços ativos..."
    SERVICOS_ATIVOS=$(systemctl list-units --all | grep -i samba | wc -l)
    if [ "$SERVICOS_ATIVOS" -gt 0 ]; then
        log_warn "Serviços Samba ainda existem:"
        systemctl list-units --all | grep -i samba
    else
        log_info "✓ Nenhum serviço Samba ativo"
    fi
    
    echo ""
    echo "3. Verificando processos em execução..."
    PROCESSOS=$(ps aux | grep -i "[s]mbd\|[n]mbd\|[w]inbind" | wc -l)
    if [ "$PROCESSOS" -gt 0 ]; then
        log_warn "Processos Samba ainda em execução:"
        ps aux | grep -i "[s]mbd\|[n]mbd\|[w]inbind"
    else
        log_info "✓ Nenhum processo Samba em execução"
    fi
    
    echo ""
    echo "4. Verificando portas em uso..."
    for porta in 137 138 139 445; do
        if netstat -tuln | grep -q ":$porta "; then
            log_warn "Porta $porta ainda em uso (pode não ser do Samba):"
            netstat -tuln | grep ":$porta "
        fi
    done
    
    echo ""
}

# Opção de remoção segura (mantém dados)
remocao_segura() {
    print_header "OPÇÃO DE REMOÇÃO SEGURA"
    
    echo "Esta opção remove o Samba mas mantém:"
    echo "  • Diretórios de compartilhamento"
    echo "  • Arquivos de dados"
    echo "  • Usuários do sistema"
    echo "  • Configurações de rede"
    echo ""
    
    read -p "Deseja fazer remoção segura? (s/n): " opcao_segura
    
    if [ "$opcao_segura" = "s" ] || [ "$opcao_segura" = "S" ]; then
        REMOCAO_SEGURA=true
        log_info "Modo de remoção segura ativado"
    else
        REMOCAO_SEGURA=false
        log_info "Modo de remoção completa ativado"
    fi
    
    echo ""
}

# Função principal
main() {
    print_header "SCRIPT DE REMOÇÃO COMPLETA DO SAMBA"
    
    echo "Este script irá remover completamente o Samba do sistema."
    echo "Isso inclui:"
    echo "  • Todos os pacotes Samba"
    echo "  • Serviços e daemons"
    echo "  • Configurações"
    echo "  • Compartilhamentos (opcional)"
    echo "  • Usuários Samba (opcional)"
    echo ""
    
    read -p "Deseja continuar? (s/n): " confirmar
    if [ "$confirmar" != "s" ] && [ "$confirmar" != "S" ]; then
        echo "Operação cancelada."
        exit 0
    fi
    
    # Iniciar processo
    check_root
    detectar_tipo
    
    if [ "$TIPO" = "desconhecido" ]; then
        log_warn "Samba não parece estar instalado. Deseja continuar para limpeza residual?"
        read -p "Continuar? (s/n): " continuar
        if [ "$continuar" != "s" ] && [ "$continuar" != "S" ]; then
            exit 0
        fi
    fi
    
    # Escolher modo
    remocao_segura
    
    # Criar backup
    criar_backup
    
    # Parar serviços
    remover_servicos
    
    if [ "$REMOCAO_SEGURA" = false ]; then
        # Remover usuários (apenas no modo completo)
        remover_usuarios
    fi
    
    # Remover pacotes
    remover_pacotes
    
    # Limpar configurações
    limpar_configuracoes
    
    if [ "$REMOCAO_SEGURA" = false ]; then
        # Remover compartilhamentos (apenas no modo completo)
        remover_compartilhamentos
    fi
    
    # Remover regras de firewall
    remover_firewall
    
    # Limpar cache
    limpar_cache
    
    # Verificar remoção
    verificar_remocao
    
    # Resumo final
    print_header "REMOÇÃO CONCLUÍDA"
    echo ""
    echo "✅ Samba removido com sucesso!"
    echo ""
    echo "📁 Backup criado em: $BACKUP_DIR"
    echo "📝 Log completo em: $LOG_FILE"
    echo ""
    
    if [ "$REMOCAO_SEGURA" = true ]; then
        echo "🔒 Modo de remoção segura:"
        echo "   • Diretórios de compartilhamento MANTIDOS"
        echo "   • Usuários do sistema MANTIDOS"
        echo "   • Para remover completamente, execute novamente sem o modo seguro"
    else
        echo "🔥 Modo de remoção completa:"
        echo "   • Todos os dados relacionados ao Samba foram removidos"
    fi
    
    echo ""
    echo "🔄 Recomendações pós-remoção:"
    echo "   1. Reinicie o sistema: sudo reboot"
    echo "   2. Verifique se outros serviços não foram afetados"
    echo "   3. Se precisar restaurar, use os arquivos em $BACKUP_DIR"
    echo ""
    echo "⚠️  Aviso: Se este era um controlador de domínio, certifique-se de:"
    echo "   • Migrar FSMO roles primeiro"
    echo "   • Remover do DNS"
    echo "   • Atualizar outros servidores membros"
    echo ""
    
    read -p "Deseja reiniciar o sistema agora? (s/n): " reiniciar
    if [ "$reiniciar" = "s" ] || [ "$reiniciar" = "S" ]; then
        log_info "Reiniciando sistema..."
        reboot
    fi
}

# Tratamento de sinais
trap 'echo -e "\n${RED}Operação interrompida pelo usuário${NC}"; exit 1' INT TERM

# Executar
main "$@"