#!/bin/bash
# Script de RESET COMPLETO - Servidor SEMED
# Versão: 1.0
# ATENÇÃO: Este script APAGA todas as configurações e dados!
# Use apenas para reiniciar do zero ou em emergências

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configurações
BACKUP_ANTES="true"  # Fazer backup antes de resetar?
BACKUP_DIR="/root/reset_backup_$(date +%Y%m%d_%H%M%S)"
USUARIO="semed"
SENHA="semed"

# Funções de mensagem
print_message() { echo -e "${GREEN}[$(date +"%H:%M:%S")] $1${NC}"; }
print_warning() { echo -e "${YELLOW}[$(date +"%H:%M:%S")] ⚠️ $1${NC}"; }
print_error() { echo -e "${RED}[$(date +"%H:%M:%S")] ❌ $1${NC}"; }
print_info() { echo -e "${BLUE}[$(date +"%H:%M:%S")] ℹ️ $1${NC}"; }

# Verificar se é root
if [[ $EUID -ne 0 ]]; then
   print_error "Este script deve ser executado como root!"
   exit 1
fi

# BANNER DE AVISO
clear
echo -e "${RED}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                     ⚠️  ATENÇÃO  ⚠️                          ║"
echo "║                                                            ║"
echo "║   Este script irá APAGAR COMPLETAMENTE:                   ║"
echo "║   ✓ Todas as configurações de serviços                     ║"
echo "║   ✓ Todos os bancos de dados                               ║"
echo "║   ✓ Todos os arquivos e documentos                         ║"
echo "║   ✓ Configurações de email                                 ║"
echo "║   ✓ Logs e dados de aplicações                             ║"
echo "║                                                            ║"
echo "║   O sistema voltará ao estado PÓS-INSTALAÇÃO do Ubuntu!    ║"
echo "║                                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo ""
print_warning "DADOS QUE SERÃO APAGADOS:"
echo "- Bancos de dados (MySQL, PostgreSQL)"
echo "- Arquivos em /dados (documentos, imagens, vídeos)"
echo "- Configurações do Nginx, PHP, Postfix, Dovecot"
echo "- Logs do sistema"
echo "- Aplicações web (Moodle, Nextcloud)"
echo ""
print_info "Será criado um backup em: $BACKUP_DIR (se a opção estiver ativada)"
echo ""

# Pergunta de confirmação
read -p "Digite 'RESETAR SEMED' para confirmar: " confirmacao
if [[ "$confirmacao" != "RESETAR SEMED" ]]; then
    print_error "Confirmação incorreta. Operação cancelada."
    exit 1
fi

# Segunda confirmação
read -p "Tem CERTEZA? Esta ação é IRREVERSÍVEL! (s/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    print_error "Operação cancelada."
    exit 1
fi

# INÍCIO DO RESET
print_message "INICIANDO RESET COMPLETO DO SERVIDOR..."
echo "=================================================="

# 1. FAZER BACKUP (opcional)
if [[ "$BACKUP_ANTES" == "true" ]]; then
    print_message "1. Criando backup de segurança..."
    mkdir -p $BACKUP_DIR
    
    # Backup de configurações importantes
    print_info "Backup de configurações..."
    cp -r /etc/nginx $BACKUP_DIR/nginx.conf 2>/dev/null
    cp -r /etc/mysql $BACKUP_DIR/mysql.conf 2>/dev/null
    cp -r /etc/postfix $BACKUP_DIR/postfix.conf 2>/dev/null
    cp -r /etc/dovecot $BACKUP_DIR/dovecot.conf 2>/dev/null
    cp -r /etc/php $BACKUP_DIR/php.conf 2>/dev/null
    cp -r /etc/fail2ban $BACKUP_DIR/fail2ban.conf 2>/dev/null
    
    # Backup de listas de usuários
    cp /etc/passwd $BACKUP_DIR/passwd.backup
    cp /etc/shadow $BACKUP_DIR/shadow.backup
    cp /etc/group $BACKUP_DIR/group.backup
    
    # Backup de bancos de dados (se ainda estiverem funcionando)
    if systemctl is-active --quiet mysql; then
        print_info "Backup dos bancos MySQL..."
        mysqldump -u root -p$SENHA --all-databases > $BACKUP_DIR/mysql_backup.sql 2>/dev/null
    fi
    
    if systemctl is-active --quiet postgresql; then
        print_info "Backup dos bancos PostgreSQL..."
        sudo -u postgres pg_dumpall > $BACKUP_DIR/postgres_backup.sql 2>/dev/null
    fi
    
    # Backup de dados importantes
    if [ -d "/dados" ]; then
        print_info "Backup de dados (isso pode levar alguns minutos)..."
        tar -czf $BACKUP_DIR/dados_backup.tar.gz /dados 2>/dev/null
    fi
    
    print_message "Backup concluído em: $BACKUP_DIR"
fi

# 2. PARAR TODOS OS SERVIÇOS
print_message "2. Parando todos os serviços..."

SERVICOS=(
    "nginx"
    "php8.1-fpm"
    "mysql"
    "mariadb"
    "postgresql"
    "postfix"
    "dovecot"
    "fail2ban"
    "ufw"
    "clamav-daemon"
    "spamassassin"
    "amavis"
    "redis-server"
    "memcached"
)

for servico in "${SERVICOS[@]}"; do
    if systemctl is-active --quiet $servico 2>/dev/null; then
        print_info "Parando $servico..."
        systemctl stop $servico
        systemctl disable $servico 2>/dev/null
    fi
done

# 3. REMOVER PACOTES E CONFIGURAÇÕES
print_message "3. Removendo pacotes e configurações..."

# 3.1 Remover servidores web
print_info "Removendo Nginx e PHP..."
apt-get purge -y nginx* php* --auto-remove

# 3.2 Remover bancos de dados
print_info "Removendo bancos de dados..."
apt-get purge -y mysql* mariadb* postgresql* --auto-remove

# 3.3 Remover servidor de email
print_info "Removendo servidor de email..."
apt-get purge -y postfix* dovecot* mailutils --auto-remove

# 3.4 Remover ferramentas de segurança
print_info "Removendo ferramentas de segurança..."
apt-get purge -y fail2ban* clamav* spamassassin* amavisd* --auto-remove

# 3.5 Remover outras ferramentas
print_info "Removendo outras ferramentas..."
apt-get purge -y redis* memcached* --auto-remove

# 4. APAGAR ARQUIVOS DE CONFIGURAÇÃO
print_message "4. Apagando arquivos de configuração..."

# Diretórios de configuração
CONFIG_DIRS=(
    "/etc/nginx"
    "/etc/php"
    "/etc/mysql"
    "/etc/postgresql"
    "/etc/postfix"
    "/etc/dovecot"
    "/etc/fail2ban"
    "/etc/clamav"
    "/etc/spamassassin"
    "/etc/amavis"
    "/etc/redis"
    "/etc/memcached"
    "/etc/phpmyadmin"
    "/var/lib/mysql"
    "/var/lib/postgresql"
    "/var/lib/redis"
    "/var/lib/clamav"
    "/var/spool/postfix"
    "/var/lib/dovecot"
)

for dir in "${CONFIG_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        print_info "Removendo $dir..."
        rm -rf "$dir"
    fi
done

# 5. APAGAR DADOS E ARQUIVOS
print_message "5. Apagando dados e arquivos..."

# Diretórios de dados
DATA_DIRS=(
    "/dados"
    "/var/www"
    "/var/www/html"
    "/var/www/semed"
    "/var/mail"
    "/home/$USUARIO/dados"
    "/home/$USUARIO/.moodle"
    "/home/$USUARIO/.nextcloud"
    "/var/log/nginx"
    "/var/log/mysql"
    "/var/log/postgresql"
    "/var/log/postfix"
    "/var/log/dovecot"
    "/var/log/fail2ban"
    "/var/log/clamav"
    "/tmp/moodle_*"
    "/tmp/nextcloud_*"
)

for dir in "${DATA_DIRS[@]}"; do
    if [ -e "$dir" ]; then
        print_info "Removendo $dir..."
        rm -rf "$dir"
    fi
done

# 6. APAGAR CONFIGURAÇÕES DE USUÁRIOS
print_message "6. Resetando configurações de usuários..."

# Remover usuário semed se existir
if id "$USUARIO" &>/dev/null; then
    print_info "Removendo usuário $USUARIO..."
    userdel -r "$USUARIO" 2>/dev/null
fi

# Remover grupos criados
for grupo in semed www-data semed-admins; do
    if getent group "$grupo" >/dev/null; then
        groupdel "$grupo" 2>/dev/null
    fi
done

# 7. LIMPAR ARQUIVOS TEMPORÁRIOS
print_message "7. Limpando arquivos temporários..."

rm -rf /tmp/*
rm -rf /var/tmp/*
apt-get clean
apt-get autoclean
apt-get autoremove -y

# 8. RESETAR FIREWALL
print_message "8. Resetando firewall..."

ufw --force disable
ufw --force reset
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# 9. RECRIAR ESTRUTURA BÁSICA
print_message "9. Recriando estrutura mínima..."

# Recriar usuário semed
useradd -m -s /bin/bash -G sudo "$USUARIO"
echo "$USUARIO:$SENHA" | chpasswd

# Criar diretório web básico
mkdir -p /var/www/html
echo "<h1>Servidor SEMED - Resetado com sucesso!</h1>" > /var/www/html/index.html
chmod 755 /var/www/html

# 10. REINSTALAR PACOTES BÁSICOS
print_message "10. Reinstalando pacotes básicos..."

apt-get update
apt-get install -y \
    curl \
    wget \
    git \
    vim \
    htop \
    net-tools \
    ufw \
    openssh-server \
    ca-certificates

# 11. REINSTALAR FIREWALL BÁSICO
print_message "11. Configurando firewall básico..."

ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
echo "y" | ufw enable

# 12. LIMPAR LOGS E HISTÓRICOS
print_message "12. Limpando logs e históricos..."

# Limpar logs do sistema
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.old" -delete

# Limpar histórico dos usuários
for user_home in /home/* /root; do
    if [ -f "$user_home/.bash_history" ]; then
        > "$user_home/.bash_history"
    fi
    if [ -f "$user_home/.mysql_history" ]; then
        > "$user_home/.mysql_history"
    fi
    if [ -f "$user_home/.psql_history" ]; then
        > "$user_home/.psql_history"
    fi
done

# 13. VERIFICAÇÃO FINAL
print_message "13. Verificando limpeza..."

# Verificar serviços removidos
SERVICOS_VERIFICAR=(
    "nginx"
    "mysql"
    "postgresql"
    "postfix"
    "dovecot"
)

print_info "Serviços ainda presentes no sistema:"
for servico in "${SERVICOS_VERIFICAR[@]}"; do
    if systemctl list-unit-files | grep -q "$servico"; then
        print_warning "⚠️ $servico ainda encontrado"
    else
        print_message "✅ $servico removido"
    fi
done

# 14. GERAR RELATÓRIO DE RESET
print_message "14. Gerando relatório de reset..."

cat > /root/relatorio_reset.txt <<EOF
==================================================
RELATÓRIO DE RESET DO SERVIDOR SEMED
==================================================
Data do reset: $(date)
Executado por: root

BACKUP REALIZADO:
----------------
Diretório de backup: $BACKUP_DIR
Tamanho do backup: $(du -sh $BACKUP_DIR 2>/dev/null | cut -f1)

SERVIÇOS REMOVIDOS:
------------------
✓ Nginx + PHP
✓ MySQL/MariaDB
✓ PostgreSQL
✓ Postfix + Dovecot (email)
✓ Fail2ban + ClamAV (segurança)
✓ Redis + Memcached (cache)

ARQUIVOS APAGADOS:
-----------------
✓ Configurações (/etc/*)
✓ Dados (/dados/*)
✓ Logs (/var/log/*)
✓ Web (/var/www/*)

ESTADO ATUAL:
------------
Sistema base: $(lsb_release -d | cut -f2)
Kernel: $(uname -r)
Usuário padrão: $USUARIO
Senha: $SENHA
Firewall: Ativo (apenas SSH)
Espaço em disco: $(df -h / | awk 'NR==2 {print $4}') livres

PRÓXIMOS PASSOS:
---------------
1. Execute o script de instalação novamente (se desejar)
2. Ou mantenha apenas como servidor básico
3. Configure backups externos
4. Altere a senha do usuário $USUARIO

==================================================
SERVIDOR RESETADO COM SUCESSO!
==================================================
EOF

# RESULTADO FINAL
echo ""
echo "=================================================="
print_message "✅ RESET CONCLUÍDO COM SUCESSO!"
echo "=================================================="
echo ""
print_info "📁 Relatório do reset: /root/relatorio_reset.txt"
if [[ "$BACKUP_ANTES" == "true" ]]; then
    print_info "💾 Backup dos dados: $BACKUP_DIR"
fi
print_info "👤 Usuário recriado: $USUARIO / $SENHA"
print_info "🌐 IP do servidor: $(hostname -I | awk '{print $1}')"
print_info "🔒 Firewall ativo: apenas porta SSH liberada"
echo ""
print_warning "⚠️  Recomendações:"
echo "   - Altere a senha do usuário $USUARIO imediatamente"
echo "   - Verifique se todos os dados foram realmente apagados"
echo "   - Execute o script de instalação novamente se necessário"
echo "   - Configure um backup externo antes de reinstalar"
echo ""

# Perguntar sobre reinicialização
read -p "Deseja reiniciar o servidor agora? (s/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Ss]$ ]]; then
    print_message "Reiniciando em 10 segundos..."
    sleep 10
    reboot
else
    print_info "Lembre-se de reiniciar o servidor em breve para aplicar todas as mudanças."
    print_info "Para reiniciar manualmente: sudo reboot"
fi
