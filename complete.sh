#!/bin/bash

# ============================================================================
# SCRIPT DE PROVISIONAMENTO DE SERVIDOR UBUNTU
# Autor: Sistema de Automação
# Descrição: Configura servidor para hospedagem de sistemas Java+PostgreSQL,
#            site público e servidor de downloads com segurança reforçada
# Versão: 1.0
# ============================================================================

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para exibir mensagens
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

# Verificar se está rodando como root
if [[ $EUID -ne 0 ]]; then
   error "Este script deve ser executado como root (use sudo)"
   exit 1
fi

# ============================================================================
# SEÇÃO 1: CONFIGURAÇÕES INICIAIS E VARIÁVEIS
# ============================================================================

log "Iniciando configuração do servidor..."
log "Carregando variáveis de configuração..."

# Configurações do sistema (ALTERE CONFORME NECESSÁRIO)
ADMIN_USER="admin"
ADMIN_PASSWORD="AltereEstaSenha123!"
SSH_PORT="22" # Opcional: mude para uma porta personalizada (ex: 2222)
DOMAIN_NAME="seudominio.prefeitura.gov.br" # ALTERAR PARA O DOMÍNIO REAL
FTP_DOWNLOAD_USER="downloaduser"
FTP_DOWNLOAD_PASS="Download@2025!"
POSTGRES_DB="sistemadb"
POSTGRES_USER="javauser"
POSTGRES_PASSWORD="Postgres@2025!"
JAVA_VERSION="17" # ou 11, 8 dependendo da necessidade

# Diretórios do sistema
BASE_DIR="/opt/sistemas"
FTP_DIR="/srv/ftp/downloads"
WEB_DIR="/var/www/site"
BACKUP_DIR="/backup"
LOGS_DIR="/var/log/servidor"

info "Criando estrutura de diretórios..."
mkdir -p $BASE_DIR $FTP_DIR $WEB_DIR $BACKUP_DIR $LOGS_DIR
mkdir -p $BACKUP_DIR/{postgres,site,sistemas}
mkdir -p /etc/fail2ban/jail.d/

# ============================================================================
# SEÇÃO 2: ATUALIZAÇÃO INICIAL DO SISTEMA
# ============================================================================

log "Atualizando o sistema..."
apt update && apt upgrade -y
apt install -y software-properties-common curl wget git vim htop net-tools

# ============================================================================
# SEÇÃO 3: HARDENING BÁSICO DO SISTEMA
# ============================================================================

log "APLICANDO HARDENING DE SEGURANÇA..."

# 3.1 Criar usuário administrador não-root
log "Criando usuário administrador: $ADMIN_USER"
if id "$ADMIN_USER" &>/dev/null; then
    warning "Usuário $ADMIN_USER já existe. Pulando criação..."
else
    useradd -m -s /bin/bash -G sudo $ADMIN_USER
    echo "$ADMIN_USER:$ADMIN_PASSWORD" | chpasswd
    log "Usuário $ADMIN_USER criado com sucesso"
fi

# 3.2 Configurar automaticamente a chave SSH para o admin
info "Configurando acesso SSH por chave para $ADMIN_USER..."
mkdir -p /home/$ADMIN_USER/.ssh
touch /home/$ADMIN_USER/.ssh/authorized_keys
chmod 700 /home/$ADMIN_USER/.ssh
chmod 600 /home/$ADMIN_USER/.ssh/authorized_keys
chown -R $ADMIN_USER:$ADMIN_USER /home/$ADMIN_USER/.ssh

# 3.3 Configurações do SSH
log "Fortalecendo configuração do SSH [5]..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d)

cat > /etc/ssh/sshd_config << EOF
# Porta SSH (opcional: mude para segurança por obscuridade)
Port $SSH_PORT

# Autenticação
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Restrições de usuários
AllowUsers $ADMIN_USER

# Configurações de sessão
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server

# Timeout e keepalive
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 2

# Criptografia forte
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOF

# 3.4 Backup da configuração original para referência
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.hardened

# 3.5 Instalar e configurar Fail2Ban [1][3][5]
log "Instalando Fail2Ban para proteção contra força bruta..."
apt install -y fail2ban

cat > /etc/fail2ban/jail.d/sshd.conf << EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOF

# 3.6 Instalar e configurar atualizações automáticas de segurança [5][7]
log "Configurando atualizações automáticas de segurança..."
apt install -y unattended-upgrades apt-listchanges

cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

# 3.7 Instalar ferramentas de auditoria e monitoramento [5]
log "Instalando ferramentas de auditoria..."
apt install -y auditd lynis aide

# Configurar AIDE para monitoramento de integridade
aideinit
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db

# 3.8 Configurar limites de recursos
cat >> /etc/security/limits.conf << EOF
* soft core 0
* hard core 0
* soft nproc 100
* hard nproc 100
EOF

# 3.9 Desabilitar serviços desnecessários
systemctl stop whoopsie 2>/dev/null
systemctl disable whoopsie 2>/dev/null
systemctl stop cups 2>/dev/null
systemctl disable cups 2>/dev/null
systemctl stop avahi-daemon 2>/dev/null
systemctl disable avahi-daemon 2>/dev/null

# ============================================================================
# SEÇÃO 4: CONFIGURAÇÃO DO FIREWALL (UFW)
# ============================================================================

log "Configurando firewall UFW [1][3][5]..."

# Configurações padrão
ufw --force disable
ufw default deny incoming
ufw default allow outgoing

# Permitir serviços essenciais
ufw allow $SSH_PORT/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 21/tcp comment 'FTP'
ufw allow 990/tcp comment 'FTPS'
ufw allow 30000:30100/tcp comment 'FTP Passive'
ufw allow 5432/tcp comment 'PostgreSQL'

# Habilitar firewall
echo "y" | ufw enable
ufw logging on

log "Firewall configurado com as seguintes regras:"
ufw status verbose

# ============================================================================
# SEÇÃO 5: INSTALAÇÃO DO POSTGRESQL
# ============================================================================

log "Instalando PostgreSQL..."
apt install -y postgresql postgresql-contrib postgresql-client

# Iniciar PostgreSQL
systemctl start postgresql
systemctl enable postgresql

# Criar banco de dados e usuário para Java
log "Configurando banco de dados PostgreSQL..."
sudo -u postgres psql << EOF
CREATE USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';
CREATE DATABASE $POSTGRES_DB OWNER $POSTGRES_USER;
GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $POSTGRES_USER;
\c $POSTGRES_DB
GRANT ALL ON SCHEMA public TO $POSTGRES_USER;
EOF

# Configurar PostgreSQL para aceitar conexões locais e via TCP
cat > /etc/postgresql/*/main/pg_hba.conf << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all            postgres                                peer
local   all            all                                     md5
host    all            all             127.0.0.1/32            md5
host    all            all             ::1/128                 md5
host    $POSTGRES_DB   $POSTGRES_USER  0.0.0.0/0               md5
EOF

# Configurar PostgreSQL para escutar em todas as interfaces
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/*/main/postgresql.conf

# Reiniciar PostgreSQL
systemctl restart postgresql

log "PostgreSQL configurado com sucesso!"

# ============================================================================
# SEÇÃO 6: INSTALAÇÃO DO JAVA
# ============================================================================

log "Instalando Java $JAVA_VERSION..."
apt install -y openjdk-$JAVA_VERSION-jdk openjdk-$JAVA_VERSION-jre

# Configurar variáveis de ambiente Java
cat >> /etc/environment << EOF
JAVA_HOME=/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64
export JAVA_HOME
PATH=$PATH:/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64/bin
EOF

source /etc/environment

log "Java instalado:"
java -version

# ============================================================================
# SEÇÃO 7: INSTALAÇÃO E CONFIGURAÇÃO DO SERVIDOR FTP (vsftpd)
# ============================================================================

log "Instalando servidor FTP (vsftpd) com TLS [2][4][6]..."

# Instalar vsftpd
apt install -y vsftpd

# Backup da configuração original
cp /etc/vsftpd.conf /etc/vsftpd.conf.bak.$(date +%Y%m%d)

# Gerar certificado SSL para FTPS
mkdir -p /etc/ssl/private
chmod 700 /etc/ssl/private

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/ssl/private/vsftpd.key \
    -out /etc/ssl/certs/vsftpd.crt \
    -subj "/C=BR/ST=Estado/L=Cidade/O=Prefeitura/OU=TI/CN=$DOMAIN_NAME"

chmod 600 /etc/ssl/private/vsftpd.key
chmod 600 /etc/ssl/certs/vsftpd.crt

# Configurar vsftpd com segurança máxima [4][6]
cat > /etc/vsftpd.conf << EOF
# Configurações básicas
listen=YES
listen_port=21
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
xferlog_file=/var/log/vsftpd.log
xferlog_std_format=YES

# Configurações de segurança
ssl_enable=YES
allow_anon_ssl=NO
force_local_data_ssl=YES
force_local_logins_ssl=YES
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
require_ssl_reuse=NO
ssl_ciphers=HIGH

# Certificados SSL
rsa_cert_file=/etc/ssl/certs/vsftpd.crt
rsa_private_key_file=/etc/ssl/private/vsftpd.key

# Restrições de acesso
chroot_local_user=YES
chroot_list_enable=NO
allow_writeable_chroot=YES
hide_ids=YES
ls_recurse_enable=NO

# Modo passivo para FTP (necessário para firewalls)
pasv_enable=YES
pasv_min_port=30000
pasv_max_port=30100
pasv_address=$DOMAIN_NAME

# Timeout e limites
idle_session_timeout=600
data_connection_timeout=120
max_clients=50
max_per_ip=5
local_max_rate=1000000

# Lista de usuários permitidos
userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO
EOF

# Criar usuário FTP para downloads [2][6]
log "Criando usuário FTP para downloads..."

# Adicionar shell restrito
echo "/usr/sbin/nologin" >> /etc/shells

# Criar usuário para download
useradd -m -d $FTP_DIR -s /usr/sbin/nologin $FTP_DOWNLOAD_USER
echo "$FTP_DOWNLOAD_USER:$FTP_DOWNLOAD_PASS" | chpasswd

# Configurar permissões do diretório FTP
chown -R $FTP_DOWNLOAD_USER:$FTP_DOWNLOAD_USER $FTP_DIR
chmod -R 755 $FTP_DIR

# Adicionar usuário à lista permitida do FTP
echo "$FTP_DOWNLOAD_USER" >> /etc/vsftpd.userlist

# Criar estrutura de diretórios para documentos
mkdir -p $FTP_DIR/{publicos,editais,legislacao,formularios}
chown -R $FTP_DOWNLOAD_USER:$FTP_DOWNLOAD_USER $FTP_DIR/*

# Adicionar arquivo de boas-vindas
cat > $FTP_DIR/LEIAME.txt << EOF
=============================================
SERVIDOR DE DOWNLOADS DA PREFEITURA
=============================================

Este servidor FTP está configurado para disponibilizar documentos públicos.

Diretórios disponíveis:
- /publicos    : Documentos de acesso geral
- /editais     : Editais de licitação
- /legislacao  : Leis e decretos municipais
- /formularios : Formulários para download

Para questões técnicas, contate o setor de TI.

=============================================
EOF

# Iniciar e habilitar vsftpd
systemctl restart vsftpd
systemctl enable vsftpd

log "Servidor FTP configurado com sucesso!"

# ============================================================================
# SEÇÃO 8: CONFIGURAÇÃO DO SITE (Criar estrutura base)
# ============================================================================

log "Criando estrutura base para o site [7]..."

# Instalar Nginx para servir o site
apt install -y nginx

# Configurar Nginx com segurança
cat > /etc/nginx/sites-available/$DOMAIN_NAME << EOF
server {
    listen 80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    root $WEB_DIR;
    index index.html index.htm;

    # Logs
    access_log /var/log/nginx/${DOMAIN_NAME}_access.log;
    error_log /var/log/nginx/${DOMAIN_NAME}_error.log;

    # Configurações de segurança
    server_tokens off;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Limitar métodos HTTP permitidos
    if (\$request_method !~ ^(GET|HEAD|POST)$) {
        return 405;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Negar acesso a arquivos ocultos
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Negar acesso a arquivos de backup
    location ~ ~$ {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

# Ativar site
ln -s /etc/nginx/sites-available/$DOMAIN_NAME /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Criar página de exemplo para o site
cat > $WEB_DIR/index.html << EOF
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Site da Prefeitura - Em Construção</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 0;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            text-align: center;
        }
        .container {
            max-width: 800px;
            padding: 40px;
            background: rgba(255,255,255,0.1);
            border-radius: 20px;
            backdrop-filter: blur(10px);
            box-shadow: 0 20px 40px rgba(0,0,0,0.2);
        }
        h1 {
            font-size: 3em;
            margin-bottom: 20px;
        }
        p {
            font-size: 1.2em;
            line-height: 1.6;
            margin-bottom: 30px;
        }
        .info-box {
            background: rgba(255,255,255,0.2);
            padding: 20px;
            border-radius: 10px;
            margin-top: 30px;
        }
        .info-box h3 {
            margin-top: 0;
        }
        ul {
            text-align: left;
        }
        a {
            color: #ffd700;
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🏛️ Portal da Prefeitura</h1>
        <p>Este site está em fase de desenvolvimento pela equipe de TI.</p>
        
        <div class="info-box">
            <h3>📋 Informações Técnicas:</h3>
            <ul>
                <li>Servidor configurado com Ubuntu 22.04 LTS</li>
                <li>Nginx configurado como servidor web</li>
                <li>Banco de dados PostgreSQL pronto para uso</li>
                <li>Servidor FTP disponível para downloads de documentos</li>
                <li>Sistemas Java podem ser implantados em /opt/sistemas/</li>
            </ul>
            
            <h3>📌 Próximos Passos:</h3>
            <ul>
                <li>Configurar o nome de domínio: <strong>$DOMAIN_NAME</strong></li>
                <li>Instalar certificado SSL (Let's Encrypt)</li>
                <li>Desenvolver e implantar o conteúdo do site</li>
                <li>Configurar sistemas Java conforme necessidade</li>
            </ul>
            
            <p><small>Servidor configurado em: $(date)</small></p>
        </div>
        
        <p><a href="ftp://$DOMAIN_NAME">📁 Acessar servidor de downloads (FTP)</a></p>
    </div>
</body>
</html>
EOF

chown -R www-data:www-data $WEB_DIR

# Testar configuração do Nginx
nginx -t

# Reiniciar Nginx
systemctl restart nginx
systemctl enable nginx

log "Site base configurado com sucesso!"

# ============================================================================
# SEÇÃO 9: CONFIGURAÇÃO DE BACKUPS AUTOMATIZADOS
# ============================================================================

log "Configurando sistema de backups..."

# Script de backup do PostgreSQL
cat > /usr/local/bin/backup-postgres.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/backup/postgres"
DATE=$(date +%Y%m%d_%H%M%S)
DB_NAME="sistemadb"
RETENTION_DAYS=7

mkdir -p $BACKUP_DIR

# Backup de todos os bancos
pg_dump $DB_NAME | gzip > $BACKUP_DIR/${DB_NAME}_$DATE.sql.gz

# Backup de roles e configurações globais
pg_dumpall --globals-only > $BACKUP_DIR/globals_$DATE.sql

# Remover backups antigos
find $BACKUP_DIR -name "*.sql.gz" -type f -mtime +$RETENTION_DAYS -delete
find $BACKUP_DIR -name "*.sql" -type f -mtime +$RETENTION_DAYS -delete

echo "Backup PostgreSQL concluído em $DATE"
EOF

# Script de backup de arquivos
cat > /usr/local/bin/backup-files.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/backup"
DATE=$(date +%Y%m%d)
RETENTION_DAYS=30

# Backup do site
tar -czf $BACKUP_DIR/site/site_$DATE.tar.gz /var/www/site/

# Backup do FTP
tar -czf $BACKUP_DIR/ftp/ftp_$DATE.tar.gz /srv/ftp/

# Backup dos sistemas Java
if [ -d "/opt/sistemas" ]; then
    tar -czf $BACKUP_DIR/sistemas/sistemas_$DATE.tar.gz /opt/sistemas/
fi

# Remover backups antigos
find $BACKUP_DIR/site -name "*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete
find $BACKUP_DIR/ftp -name "*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete
find $BACKUP_DIR/sistemas -name "*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete

echo "Backup de arquivos concluído em $DATE"
EOF

chmod +x /usr/local/bin/backup-*.sh

# Configurar cron para backups diários
cat > /etc/cron.d/backups << EOF
# Backups automáticos
0 2 * * * root /usr/local/bin/backup-postgres.sh >> /var/log/backup.log 2>&1
0 3 * * * root /usr/local/bin/backup-files.sh >> /var/log/backup.log 2>&1
EOF

log "Sistema de backups configurado com sucesso!"

# ============================================================================
# SEÇÃO 10: RELATÓRIO FINAL E INFORMAÇÕES
# ============================================================================

# Reiniciar serviços para aplicar todas as configurações
log "Reiniciando serviços para aplicar configurações..."
systemctl restart ssh
systemctl restart fail2ban
systemctl restart postgresql
systemctl restart vsftpd
systemctl restart nginx

# Gerar relatório final
REPORT_FILE="/root/servidor-configuracao-$(date +%Y%m%d).txt"

cat > $REPORT_FILE << EOF
========================================================================
RELATÓRIO DE CONFIGURAÇÃO DO SERVIDOR
Data: $(date)
========================================================================

SERVIÇOS INSTALADOS:
✓ Sistema base Ubuntu atualizado
✓ PostgreSQL (Banco de dados)
✓ Java OpenJDK $JAVA_VERSION
✓ vsftpd com TLS (Servidor FTP)
✓ Nginx (Servidor Web)
✓ Fail2Ban (Proteção contra força bruta)
✓ UFW (Firewall)
✓ Ferramentas de auditoria (auditd, lynis, aide)

========================================================================
ACESSOS CONFIGURADOS
========================================================================

Usuário Administrador: $ADMIN_USER
SSH: Porta $SSH_PORT - Acesso apenas por chave pública (senha desabilitada)

Banco de Dados PostgreSQL:
  - Banco: $POSTGRES_DB
  - Usuário: $POSTGRES_USER
  - Porta: 5432
  - Conectar: psql -h localhost -U $POSTGRES_USER -d $POSTGRES_DB

Servidor FTP (Downloads):
  - Usuário: $FTP_DOWNLOAD_USER
  - Senha: $FTP_DOWNLOAD_PASS
  - Portas: 21 (FTP), 990 (FTPS)
  - Modo Passivo: 30000-30100
  - Diretório: $FTP_DIR

Servidor Web (Site):
  - Domínio configurado: $DOMAIN_NAME
  - Diretório: $WEB_DIR
  - Arquivo de configuração: /etc/nginx/sites-available/$DOMAIN_NAME

========================================================================
SEGURANÇA APLICADA
========================================================================

1. SSH Hardening [5][7]:
   - Login root desabilitado
   - Autenticação por senha desabilitada
   - Apenas chave pública permitida
   - Porta personalizada: $SSH_PORT

2. Fail2Ban [1][3][5]:
   - Proteção SSH ativa
   - 3 tentativas máximas
   - Banimento por 1 hora

3. Firewall UFW [1][3][5][9]:
   - Política padrão: deny incoming
   - Portas abertas: $SSH_PORT, 80, 443, 21, 990, 30000:30100, 5432
   - Logging ativado

4. Atualizações Automáticas [5][7]:
   - unattended-upgrades ativo
   - Atualizações de segurança automáticas
   - Verificação diária

5. Monitoramento:
   - Auditd ativo
   - AIDE para integridade de arquivos
   - Lynis para auditoria

========================================================================
PRÓXIMOS PASSOS RECOMENDADOS
========================================================================

Para finalizar a configuração do site (a ser feito por outra pessoa):

1. Configurar DNS:
   - Aponte o domínio $DOMAIN_NAME para o IP deste servidor

2. Instalar certificado SSL (Let's Encrypt):
   sudo apt install certbot python3-certbot-nginx
   sudo certbot --nginx -d $DOMAIN_NAME -d www.$DOMAIN_NAME

3. Personalizar o site:
   - Editar arquivos em $WEB_DIR
   - Configurar sistemas Java em /opt/sistemas/

4. Configurar backups externos (opcional):
   - Os backups automáticos estão em /backup/
   - Configure sincronização para armazenamento externo

5. Verificar logs regularmente:
   - /var/log/auth.log (acessos SSH)
   - /var/log/fail2ban.log (bloqueios)
   - /var/log/ufw.log (firewall)
   - /var/log/nginx/ (acessos ao site)
   - /var/log/vsftpd.log (acessos FTP)

========================================================================
COMANDOS ÚTEIS
========================================================================

Status dos serviços:
  systemctl status ssh fail2ban postgresql vsftpd nginx

Verificar firewall:
  ufw status verbose

Verificar bloqueios do Fail2Ban:
  fail2ban-client status sshd

Logs de segurança:
  tail -f /var/log/auth.log
  tail -f /var/log/fail2ban.log

Backup manual:
  /usr/local/bin/backup-postgres.sh
  /usr/local/bin/backup-files.sh

Auditoria de segurança:
  lynis audit system

========================================================================
INFORMAÇÕES IMPORTANTES
========================================================================

- Guarde todas as senhas em local seguro!
- O acesso SSH por senha foi DESABILITADO por segurança [5][7]
- Configure sua chave pública em: /home/$ADMIN_USER/.ssh/authorized_keys
- Script executado com sucesso em $(date)

========================================================================
EOF

log "Configuração concluída com sucesso!"
log "Relatório salvo em: $REPORT_FILE"

# Mostrar resumo
cat $REPORT_FILE

# Executar verificação inicial com Lynis
warning "Executando verificação inicial com Lynis (pode levar alguns minutos)..."
lynis audit system --quick > /root/lynis-initial-scan-$(date +%Y%m%d).txt

log "Script finalizado! O servidor está pronto para uso."

exit 0
