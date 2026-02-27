#!/bin/bash

# ============================================================================
# SCRIPT DE LIMPEZA TOTAL DO SERVIDOR
# ATENÇÃO: Este script remove TODAS as configurações e dados
# Use apenas se tiver CERTEZA absoluta do que está fazendo
# ============================================================================

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║     ATENÇÃO: SCRIPT DE LIMPEZA TOTAL DO SERVIDOR            ║${NC}"
echo -e "${RED}║     TODOS OS DADOS SERÃO PERMANENTEMENTE REMOVIDOS          ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

# Verificar se está rodando como root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Este script deve ser executado como root (use sudo)${NC}"
   exit 1
fi

# Confirmação em três níveis
echo -e "${YELLOW}NÍVEL 1: Você tem certeza que deseja limpar TUDO? (s/N)${NC}"
read -r confirm1
if [[ ! "$confirm1" =~ ^[sS]$ ]]; then
    echo -e "${GREEN}Operação cancelada.${NC}"
    exit 0
fi

echo -e "${YELLOW}NÍVEL 2: TODOS OS DADOS SERÃO PERDIDOS. Confirma? (SIM/NÃO)${NC}"
read -r confirm2
if [[ "$confirm2" != "SIM" ]]; then
    echo -e "${GREEN}Operação cancelada.${NC}"
    exit 0
fi

echo -e "${YELLOW}NÍVEL 3: ÚLTIMA CHANCE! Digite 'EXCLUIR TUDO' para confirmar:${NC}"
read -r confirm3
if [[ "$confirm3" != "EXCLUIR TUDO" ]]; then
    echo -e "${GREEN}Operação cancelada.${NC}"
    exit 0
fi

echo -e "${RED}Iniciando limpeza total em 5 segundos... Pressione CTRL+C para cancelar AGORA${NC}"
sleep 5

# ============================================================================
# 1. PARAR TODOS OS SERVIÇOS
# ============================================================================
echo -e "${YELLOW}[1/10] Parando todos os serviços...${NC}"

services=(
    "postgresql"
    "nginx"
    "vsftpd"
    "fail2ban"
    "ssh"
    "ufw"
    "cron"
    "auditd"
)

for service in "${services[@]}"; do
    systemctl stop "$service" 2>/dev/null
    systemctl disable "$service" 2>/dev/null
done

# ============================================================================
# 2. REMOVER PACOTES INSTALADOS
# ============================================================================
echo -e "${YELLOW}[2/10] Removendo pacotes instalados...${NC}"

packages=(
    "postgresql*"
    "nginx*"
    "vsftpd*"
    "fail2ban*"
    "ufw"
    "openjdk-*"
    "auditd"
    "lynis"
    "aide*"
    "unattended-upgrades"
    "mailutils"
    "postfix*"
    "cron"
    "macchanger"
)

for pkg in "${packages[@]}"; do
    apt-get remove --purge -y $pkg 2>/dev/null
    apt-get autoremove --purge -y 2>/dev/null
done

# ============================================================================
# 3. REMOVER USUÁRIOS CRIADOS
# ============================================================================
echo -e "${YELLOW}[3/10] Removendo usuários criados...${NC}"

# Identificar usuários criados (UID >= 1000)
for user in $(awk -F: '$3>=1000 && $3<60000 {print $1}' /etc/passwd); do
    if [[ "$user" != "ubuntu" && "$user" != "admin" && "$user" != "downloaduser" ]]; then
        # Só remove se for um dos usuários que criamos
        continue
    fi
    echo "Removendo usuário: $user"
    pkill -u "$user" 2>/dev/null
    userdel -r -f "$user" 2>/dev/null
done

# Remover usuários específicos que criamos
for user in admin downloaduser; do
    if id "$user" &>/dev/null; then
        pkill -u "$user" 2>/dev/null
        userdel -r -f "$user" 2>/dev/null
    fi
done

# ============================================================================
# 4. REMOVER DIRETÓRIOS CRIADOS
# ============================================================================
echo -e "${YELLOW}[4/10] Removendo diretórios criados...${NC}"

directories=(
    "/opt/sistemas"
    "/srv/ftp"
    "/var/www/site"
    "/backup"
    "/var/log/servidor"
    "/etc/ssl/private"
    "/etc/fail2ban/jail.d"
    "/root/setup_harden_backup_*"
    "/root/.fingerprint_reset_backup"
)

for dir in "${directories[@]}"; do
    rm -rf "$dir" 2>/dev/null
done

# ============================================================================
# 5. RESTAURAR CONFIGURAÇÕES ORIGINAIS DO SSH
# ============================================================================
echo -e "${YELLOW}[5/10] Restaurando configurações originais do SSH...${NC}"

if [ -f "/etc/ssh/sshd_config.bak"* ]; then
    cp /etc/ssh/sshd_config.bak* /etc/ssh/sshd_config 2>/dev/null
else
    # Recriar configuração padrão
    cat > /etc/ssh/sshd_config << EOF
# Package generated configuration file
# See the sshd_config(5) manpage for details
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_dsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
UsePrivilegeSeparation yes
KeyRegenerationInterval 3600
ServerKeyBits 1024
SyslogFacility AUTH
LogLevel INFO
LoginGraceTime 120
PermitRootLogin prohibit-password
StrictModes yes
RSAAuthentication yes
PubkeyAuthentication yes
IgnoreRhosts yes
RhostsRSAAuthentication no
HostbasedAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
X11Forwarding yes
X11DisplayOffset 10
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
UsePAM yes
EOF
fi

# ============================================================================
# 6. RESTAURAR HOSTNAME PADRÃO
# ============================================================================
echo -e "${YELLOW}[6/10] Restaurando hostname...${NC}"

# Gerar hostname padrão baseado no MAC
new_hostname="ubuntu-$(cat /sys/class/net/$(ip route show default | awk '/default/ {print $5}')/address 2>/dev/null | tr -d ':' | tail -c 7)"
echo "$new_hostname" > /etc/hostname
hostname "$new_hostname"

# ============================================================================
# 7. LIMPAR ARQUIVOS DE CONFIGURAÇÃO
# ============================================================================
echo -e "${YELLOW}[7/10] Limpando arquivos de configuração...${NC}"

config_files=(
    "/etc/apt/sources.list.d/*.list"
    "/etc/cron.d/backups"
    "/etc/nginx/sites-available/*"
    "/etc/nginx/sites-enabled/*"
    "/etc/postgresql/*/main/pg_hba.conf"
    "/etc/postgresql/*/main/postgresql.conf"
    "/etc/vsftpd.conf"
    "/etc/vsftpd.userlist"
    "/etc/fail2ban/jail.d/*"
    "/etc/ufw/*.rules"
    "/etc/apt/apt.conf.d/20auto-upgrades"
    "/etc/apt/apt.conf.d/50unattended-upgrades"
    "/etc/security/limits.d/*.conf"
    "/etc/sysctl.d/99-du-hardening.conf"
    "/usr/local/bin/backup-*.sh"
)

for file in "${config_files[@]}"; do
    rm -f $file 2>/dev/null
done

# ============================================================================
# 8. RESTAURAR FIREWALL (UFW)
# ============================================================================
echo -e "${YELLOW}[8/10] Resetando firewall...${NC}"

ufw --force disable 2>/dev/null
ufw --force reset 2>/dev/null
rm -f /etc/ufw/user.rules 2>/dev/null
rm -f /etc/ufw/user6.rules 2>/dev/null

# ============================================================================
# 9. LIMPAR LOGS E HISTÓRICOS
# ============================================================================
echo -e "${YELLOW}[9/10] Limpando logs e históricos...${NC}"

# Limpar logs do sistema
find /var/log -type f -name "*.log" -delete 2>/dev/null
find /var/log -type f -name "*.gz" -delete 2>/dev/null
find /var/log -type f -name "*.1" -delete 2>/dev/null
find /var/log -type f -name "*.old" -delete 2>/dev/null

# Recriar arquivos de log vazios
touch /var/log/syslog
touch /var/log/auth.log
touch /var/log/kern.log
touch /var/log/dpkg.log
touch /var/log/apt/history.log
touch /var/log/apt/term.log

# Limpar histórico de comandos
> /root/.bash_history
for user_home in /home/*; do
    if [ -d "$user_home" ]; then
        > "$user_home/.bash_history" 2>/dev/null
    fi
done

# Limpar histórico do mysql/client
> /root/.mysql_history 2>/dev/null
> /root/.psql_history 2>/dev/null

# ============================================================================
# 10. LIMPAR IDs DE MÁQUINA (OPCIONAL)
# ============================================================================
echo -e "${YELLOW}[10/10] Resetando identificadores do sistema...${NC}"

# Backup dos IDs originais (por segurança)
cp /etc/machine-id /etc/machine-id.backup 2>/dev/null
cp /var/lib/dbus/machine-id /var/lib/dbus/machine-id.backup 2>/dev/null

# Gerar novos IDs
rm -f /etc/machine-id 2>/dev/null
rm -f /var/lib/dbus/machine-id 2>/dev/null
systemd-machine-id-setup 2>/dev/null

# ============================================================================
# FINALIZAÇÃO
# ============================================================================
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}LIMPEZA CONCLUÍDA!${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo -e "${YELLOW}O sistema foi restaurado para o estado inicial.${NC}"
echo -e "${YELLOW}Recomendações finais:${NC}"
echo
echo "1. Reinicie o sistema agora: sudo reboot"
echo "2. Após o reboot, faça uma instalação limpa se necessário"
echo "3. Verifique se todos os serviços padrão estão funcionando"
echo
echo -e "${RED}IMPORTANTE: Todos os dados foram permanentemente removidos.${NC}"
echo

# Perguntar sobre reboot
echo -e "${YELLOW}Deseja reiniciar o sistema agora? (s/N)${NC}"
read -r reboot_confirm
if [[ "$reboot_confirm" =~ ^[sS]$ ]]; then
    echo "Reiniciando em 10 segundos..."
    sleep 10
    reboot
fi

exit 0
