#!/bin/bash
# Script de Correção do Samba no Cliente - Ubuntu 24.04
# Corrige erro "falha ao acessar /usr/libexec/gvfsd-smb"

set -euo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error() { echo -e "${RED}[ERRO]${NC} $1"; }

# ============================================================================
# DIAGNÓSTICO DO PROBLEMA
# ============================================================================

diagnosticar_problema() {
    print_header "DIAGNÓSTICO DO PROBLEMA DO SAMBA"
    
    echo "Problema relatado: 'falha ao acessar /usr/libexec/gvfsd-smb'"
    echo ""
    
    # 1. Verificar se o arquivo realmente existe
    echo "1. Verificando localização do gvfsd-smb..."
    if [ -f "/usr/libexec/gvfsd-smb" ]; then
        log_info "Arquivo encontrado em /usr/libexec/gvfsd-smb"
        ls -la /usr/libexec/gvfsd-smb
    elif [ -f "/usr/lib/gvfs/gvfsd-smb" ]; then
        log_warn "Arquivo está em /usr/lib/gvfs/gvfsd-smb (localização correta para Ubuntu 24.04)"
        ls -la /usr/lib/gvfs/gvfsd-smb
    else
        log_error "Arquivo gvfsd-smb não encontrado em lugar nenhum!"
    fi
    
    echo ""
    
    # 2. Verificar pacotes gvfs instalados
    echo "2. Verificando pacotes GVFS instalados..."
    dpkg -l | grep -i gvfs | head -10
    
    echo ""
    
    # 3. Verificar link simbólico incorreto
    echo "3. Verificando links simbólicos..."
    if [ -L "/usr/libexec" ]; then
        log_warn "/usr/libexec é um link simbólico"
        ls -la /usr/libexec
    fi
    
    if [ -L "/usr/libexec/gvfsd-smb" ]; then
        log_warn "Link simbólico gvfsd-smb encontrado"
        ls -la /usr/libexec/gvfsd-smb
    fi
    
    echo ""
    
    # 4. Verificar variáveis de ambiente
    echo "4. Verificando variáveis de ambiente relacionadas..."
    env | grep -i "libexec\|gvfs" | head -5 || echo "Nenhuma variável encontrada"
    
    echo ""
}

# ============================================================================
# SOLUÇÃO 1: CRIAR LINK SIMBÓLICO CORRETO
# ============================================================================

criar_link_simbolico() {
    print_header "SOLUÇÃO 1: CRIANDO LINK SIMBÓLICO CORRETO"
    
    # Verificar se o arquivo real existe
    if [ -f "/usr/lib/gvfs/gvfsd-smb" ]; then
        log_info "Arquivo real encontrado: /usr/lib/gvfs/gvfsd-smb"
        
        # Criar diretório /usr/libexec se não existir
        if [ ! -d "/usr/libexec" ]; then
            log_info "Criando diretório /usr/libexec..."
            mkdir -p /usr/libexec
        fi
        
        # Criar link simbólico
        if [ -L "/usr/libexec/gvfsd-smb" ] || [ -f "/usr/libexec/gvfsd-smb" ]; then
            log_warn "Removendo arquivo/link existente..."
            rm -f /usr/libexec/gvfsd-smb
        fi
        
        log_info "Criando link simbólico..."
        ln -s /usr/lib/gvfs/gvfsd-smb /usr/libexec/gvfsd-smb
        
        # Verificar
        if [ -L "/usr/libexec/gvfsd-smb" ]; then
            log_info "Link criado com sucesso:"
            ls -la /usr/libexec/gvfsd-smb
        else
            log_error "Falha ao criar link simbólico"
        fi
    else
        log_error "Arquivo /usr/lib/gvfs/gvfsd-smb não encontrado!"
        log_info "Instalando pacotes necessários..."
        return 1
    fi
    
    echo ""
}

# ============================================================================
# SOLUÇÃO 2: REINSTALAR PACOTES GVFS
# ============================================================================

reinstalar_gvfs() {
    print_header "SOLUÇÃO 2: REINSTALANDO PACOTES GVFS"
    
    echo "Pacotes GVFS atualmente instalados:"
    echo "-----------------------------------"
    dpkg -l | grep -i gvfs
    
    echo ""
    read -p "Deseja reinstalar os pacotes GVFS? (s/n): " REINSTALAR
    
    if [ "$REINSTALAR" = "s" ] || [ "$REINSTALAR" = "S" ]; then
        log_info "Reinstalando pacotes GVFS..."
        
        # Atualizar repositórios
        apt update
        
        # Reinstalar pacotes GVFS
        apt install --reinstall -y \
            gvfs \
            gvfs-backends \
            gvfs-common \
            gvfs-daemons \
            gvfs-fuse \
            gvfs-libs
        
        # Instalar pacotes específicos do Samba
        apt install --reinstall -y \
            gvfs-backends-gphoto2 \
            gvfs-backends-smb
        
        log_info "Pacotes GVFS reinstalados"
    else
        log_info "Reinstalação cancelada"
    fi
    
    echo ""
}

# ============================================================================
# SOLUÇÃO 3: CRIAR ESTRUTURA DE DIRETÓRIOS COMPATÍVEL
# ============================================================================

criar_estrutura_diretorios() {
    print_header "SOLUÇÃO 3: CRIANDO ESTRUTURA DE DIRETÓRIOS COMPATÍVEL"
    
    # Em versões mais recentes do Ubuntu, /usr/libexec não existe mais
    # Mas alguns programas ainda procuram por ele
    
    log_info "Criando estrutura de diretórios compatível..."
    
    # Criar diretório
    mkdir -p /usr/libexec
    
    # Encontrar todos os executáveis do gvfs que deveriam estar em libexec
    find /usr/lib/gvfs -type f -name "gvfsd-*" -executable | while read -r binario; do
        nome=$(basename "$binario")
        if [ ! -e "/usr/libexec/$nome" ]; then
            log_info "Criando link para $nome..."
            ln -s "$binario" "/usr/libexec/$nome"
        fi
    done
    
    # Verificar
    echo ""
    log_info "Binários do GVFS agora disponíveis em /usr/libexec:"
    ls -la /usr/libexec/gvfsd-* 2>/dev/null || echo "Nenhum arquivo encontrado"
    
    echo ""
}

# ============================================================================
# SOLUÇÃO 4: CORRIGIR VARIÁVEIS DE AMBIENTE
# ============================================================================

corrigir_variaveis_ambiente() {
    print_header "SOLUÇÃO 4: CORRIGINDO VARIÁVEIS DE AMBIENTE"
    
    # Adicionar /usr/libexec ao PATH se não estiver
    if ! echo "$PATH" | grep -q "/usr/libexec"; then
        log_info "Adicionando /usr/libexec ao PATH..."
        echo 'export PATH="/usr/libexec:$PATH"' >> /etc/environment
        export PATH="/usr/libexec:$PATH"
    else
        log_info "/usr/libexec já está no PATH"
    fi
    
    # Adicionar ao ld.so.conf se necessário
    if [ ! -f "/etc/ld.so.conf.d/libexec.conf" ]; then
        log_info "Criando arquivo de configuração do ld.so..."
        echo "/usr/libexec" > /etc/ld.so.conf.d/libexec.conf
        ldconfig
    fi
    
    echo ""
}

# ============================================================================
# SOLUÇÃO 5: INSTALAR SAMBA CLIENT COMPLETO
# ============================================================================

instalar_samba_cliente() {
    print_header "SOLUÇÃO 5: INSTALANDO SAMBA CLIENT COMPLETO"
    
    log_info "Instalando pacotes do cliente Samba..."
    
    apt update
    apt install -y \
        samba-client \
        cifs-utils \
        gvfs-backends-smb \
        smbclient \
        libsmbclient
    
    # Pacotes do GNOME para integração
    if dpkg -l | grep -q "gnome-shell"; then
        log_info "Instalando integração com GNOME..."
        apt install -y \
            gnome-control-center \
            nautilus-share \
            gvfs-bin
    fi
    
    # Pacotes do KDE
    if dpkg -l | grep -q "plasma-desktop"; then
        log_info "Instalando integração com KDE..."
        apt install -y \
            kio-extras \
            kdenetwork-filesharing
    fi
    
    log_info "Pacotes do cliente Samba instalados"
    echo ""
}

# ============================================================================
# SOLUÇÃO 6: CORRIGIR PERMISSÕES
# ============================================================================

corrigir_permissoes() {
    print_header "SOLUÇÃO 6: CORRIGINDO PERMISSÕES"
    
    log_info "Corrigindo permissões do GVFS..."
    
    # Verificar permissões dos binários
    chmod 755 /usr/lib/gvfs/gvfsd-* 2>/dev/null || true
    chmod 755 /usr/libexec/gvfsd-* 2>/dev/null || true
    
    # Corrigir permissões dos diretórios
    chmod 755 /usr/lib/gvfs 2>/dev/null || true
    chmod 755 /usr/libexec 2>/dev/null || true
    
    # Corrigir proprietário
    chown root:root /usr/lib/gvfs/gvfsd-* 2>/dev/null || true
    chown root:root /usr/libexec/gvfsd-* 2>/dev/null || true
    
    log_info "Permissões corrigidas"
    echo ""
}

# ============================================================================
# SOLUÇÃO 7: CRIAR SCRIPT DE FALLBACK
# ============================================================================

criar_script_fallback() {
    print_header "SOLUÇÃO 7: CRIANDO SCRIPT DE FALLBACK"
    
    # Se nada mais funcionar, criar um wrapper script
    SCRIPT_PATH="/usr/libexec/gvfsd-smb"
    
    log_info "Criando script wrapper para gvfsd-smb..."
    
    cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash
# Wrapper script para gvfsd-smb no Ubuntu 24.04
# Corrige problema de localização do binário

# Localização real do binário
REAL_BINARY="/usr/lib/gvfs/gvfsd-smb"

# Verificar se o binário real existe
if [ -x "$REAL_BINARY" ]; then
    # Executar o binário real com todos os argumentos
    exec "$REAL_BINARY" "$@"
else
    echo "Erro: $REAL_BINARY não encontrado ou não é executável" >&2
    echo "Instale o pacote gvfs-backends-smb:" >&2
    echo "  sudo apt install gvfs-backends-smb" >&2
    exit 1
fi
EOF
    
    # Tornar executável
    chmod +x "$SCRIPT_PATH"
    
    log_info "Script wrapper criado em $SCRIPT_PATH"
    echo ""
}

# ============================================================================
# SOLUÇÃO 8: TESTAR CONEXÃO SAMBA
# ============================================================================

testar_conexao_samba() {
    print_header "SOLUÇÃO 8: TESTANDO CONEXÃO SAMBA"
    
    read -p "Digite o IP do servidor Samba (ou pressione Enter para pular): " SERVER_IP
    
    if [ -n "$SERVER_IP" ]; then
        log_info "Testando conexão com servidor Samba..."
        
        # Teste 1: Ping
        echo "1. Testando ping..."
        if ping -c 2 "$SERVER_IP" &>/dev/null; then
            log_info "✓ Servidor responde ao ping"
        else
            log_error "✗ Servidor não responde ao ping"
        fi
        
        # Teste 2: Portas Samba
        echo ""
        echo "2. Testando portas Samba..."
        for porta in 139 445; do
            if timeout 2 bash -c "cat < /dev/null > /dev/tcp/$SERVER_IP/$porta" 2>/dev/null; then
                log_info "✓ Porta $porta acessível"
            else
                log_error "✗ Porta $porta bloqueada"
            fi
        done
        
        # Teste 3: Listar compartilhamentos
        echo ""
        echo "3. Listando compartilhamentos..."
        smbclient -L "$SERVER_IP" -N 2>/dev/null && \
            log_info "✓ Compartilhamentos listados com sucesso" || \
            log_error "✗ Falha ao listar compartilhamentos"
        
        # Teste 4: Usando smbclient
        echo ""
        echo "4. Testando acesso anônimo..."
        smbclient "//$SERVER_IP/public" -N -c "ls" 2>/dev/null && \
            log_info "✓ Acesso anônimo funcionando" || \
            log_warn "⚠ Acesso anônimo falhou (pode ser normal)"
    else
        log_info "Teste de conexão pulado"
    fi
    
    echo ""
}

# ============================================================================
# SOLUÇÃO 9: CONFIGURAR MONTAGEM AUTOMÁTICA
# ============================================================================

configurar_montagem_automatica() {
    print_header "SOLUÇÃO 9: CONFIGURANDO MONTAGEM AUTOMÁTICA"
    
    echo "Opcional: Configurar montagem automática de compartilhamentos Samba"
    echo ""
    
    read -p "Deseja configurar montagem via fstab? (s/n): " CONFIG_FSTAB
    
    if [ "$CONFIG_FSTAB" = "s" ] || [ "$CONFIG_FSTAB" = "S" ]; then
        read -p "IP do servidor: " SERVER_IP
        read -p "Nome do compartilhamento: " SHARE_NAME
        read -p "Ponto de montagem local (ex: /mnt/samba): " MOUNT_POINT
        
        mkdir -p "$MOUNT_POINT"
        
        echo ""
        echo "Exemplo de entrada para /etc/fstab:"
        echo "//$SERVER_IP/$SHARE_NAME  $MOUNT_POINT  cifs  guest,uid=$(id -u),iocharset=utf8  0  0"
        echo ""
        
        read -p "Adicionar esta entrada ao fstab? (s/n): " ADD_FSTAB
        
        if [ "$ADD_FSTAB" = "s" ] || [ "$ADD_FSTAB" = "S" ]; then
            echo "//$SERVER_IP/$SHARE_NAME  $MOUNT_POINT  cifs  guest,uid=$(id -u),iocharset=utf8  0  0" >> /etc/fstab
            log_info "Entrada adicionada ao fstab"
            
            # Testar montagem
            mount "$MOUNT_POINT" && \
                log_info "✓ Compartilhamento montado com sucesso" || \
                log_error "✗ Falha ao montar compartilhamento"
        fi
    fi
    
    echo ""
}

# ============================================================================
# SOLUÇÃO 10: REINICIAR SERVIÇOS
# ============================================================================

reiniciar_servicos() {
    print_header "SOLUÇÃO 10: REINICIANDO SERVIÇOS"
    
    log_info "Reiniciando serviços relacionados..."
    
    # Parar serviços do gvfs
    systemctl --user stop gvfs-* 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    
    # Reiniciar daemon do gvfs
    killall -9 gvfsd 2>/dev/null || true
    
    # Reiniciar serviços do sistema
    systemctl restart udisks2 2>/dev/null || true
    
    log_info "Serviços reiniciados"
    
    echo ""
    log_warn "⚠ É recomendado REINICIAR o sistema para aplicar todas as correções"
    echo ""
}

# ============================================================================
# FUNÇÃO PRINCIPAL
# ============================================================================

main() {
    print_header "CORRETOR DE PROBLEMAS DO SAMBA NO CLIENTE"
    echo "Erro: 'falha ao acessar /usr/libexec/gvfsd-smb'"
    echo ""
    
    # Verificar se é root (algumas correções precisam)
    if [ "$EUID" -ne 0 ]; then
        log_warn "Algumas correções exigem privilégios de root"
        read -p "Continuar mesmo assim? (s/n): " CONTINUAR
        if [ "$CONTINUAR" != "s" ] && [ "$CONTINUAR" != "S" ]; then
            exit 1
        fi
    fi
    
    # Diagnóstico
    diagnosticar_problema
    
    # Menu de soluções
    echo "Selecione a solução para aplicar:"
    echo "1) Criar link simbólico (Recomendado)"
    echo "2) Reinstalar pacotes GVFS"
    echo "3) Criar estrutura de diretórios"
    echo "4) Corrigir variáveis de ambiente"
    echo "5) Instalar Samba client completo"
    echo "6) Corrigir permissões"
    echo "7) Criar script de fallback"
    echo "8) Testar conexão Samba"
    echo "9) Configurar montagem automática"
    echo "10) Reiniciar serviços"
    echo "11) APLICAR TODAS AS CORREÇÕES"
    echo "0) Sair"
    
    read -p "Opção: " OPCAO
    
    case $OPCAO in
        1) criar_link_simbolico ;;
        2) reinstalar_gvfs ;;
        3) criar_estrutura_diretorios ;;
        4) corrigir_variaveis_ambiente ;;
        5) instalar_samba_cliente ;;
        6) corrigir_permissoes ;;
        7) criar_script_fallback ;;
        8) testar_conexao_samba ;;
        9) configurar_montagem_automatica ;;
        10) reiniciar_servicos ;;
        11)
            # Aplicar todas as correções
            criar_link_simbolico || true
            reinstalar_gvfs || true
            criar_estrutura_diretorios || true
            corrigir_variaveis_ambiente || true
            instalar_samba_cliente || true
            corrigir_permissoes || true
            criar_script_fallback || true
            testar_conexao_samba || true
            reiniciar_servicos || true
            ;;
        0) exit 0 ;;
        *) echo "Opção inválida"; exit 1 ;;
    esac
    
    # Resumo final
    print_header "CORREÇÃO APLICADA"
    echo ""
    echo "Para verificar se o problema foi resolvido:"
    echo ""
    echo "1. Tente acessar novamente o compartilhamento Samba"
    echo "2. Verifique os logs: journalctl -xe | grep -i gvfs"
    echo "3. Teste via linha de comando: smbclient -L //IP_DO_SERVIDOR"
    echo ""
    echo "Se o problema persistir, reinicie o sistema e tente novamente."
    echo ""
    
    read -p "Deseja reiniciar o sistema agora? (s/n): " REBOOT
    if [ "$REBOOT" = "s" ] || [ "$REBOOT" = "S" ]; then
        log_info "Reiniciando sistema..."
        reboot
    fi
}

# Executar
main "$@"