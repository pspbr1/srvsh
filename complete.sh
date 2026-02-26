#!/bin/bash
# Script de instalação do servidor - Secretaria Municipal de Educação
# Versão: 1.0
# Autor: SEMED - TI
# Data: 2024

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configurações iniciais
HOSTNAME="semed-server"
USUARIO="semed"
SENHA="semed"
DOMINIO="educacao.semed.gov.br"

# Função para exibir mensagens de progresso
print_message() {
    echo -e "${GREEN}[$(date +"%H:%M:%S")] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[$(date +"%H:%M:%S")] $1${NC}"
}

print_error() {
    echo -e "${RED}[$(date +"%H:%M:%S")] $1${NC}"
}

# Verificar se está rodando como root
if [[ $EUID -ne 0 ]]; then
   print_error "Este script deve ser executado como root!"
   exit 1
fi

# Início da instalação
clear
echo "=================================================="
echo "  INSTALAÇÃO DO SERVIDOR SEMED - EDUCAÇÃO        "
echo "=================================================="
echo ""

# 1. Configurações básicas do sistema
print_message "1. Configurando sistema básico..."

# Configurar hostname
echo "$HOSTNAME" > /etc/hostname
hostnamectl set-hostname $HOSTNAME

# Atualizar repositórios
print_message "Atualizando repositórios..."
apt-get update -qq

# Instalar pacotes básicos
print_message "Instalando pacotes essenciais..."
apt-get install -y -qq \
    curl \
    wget \
    git \
    vim \
    htop \
    net-tools \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    ufw \
    fail2ban \
    unattended-upgrades \
    openssl \
    tree \
    unzip \
    zip \
    python3 \
    python3-pip

# 2. Configurar usuário semed
print_message "2. Configurando usuário $USUARIO..."

# Criar usuário se não existir
if id "$USUARIO" &>/dev/null; then
    print_warning "Usuário $USUARIO já existe"
else
    useradd -m -s /bin/bash -G sudo $USUARIO
    echo "$USUARIO:$SENHA" | chpasswd
    print_message "Usuário $USUARIO criado com sucesso"
fi

# 3. Configurar firewall (UFW)
print_message "3. Configurando firewall..."

ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 25/tcp comment 'SMTP'
ufw allow 587/tcp comment 'SMTP Submission'
ufw allow 993/tcp comment 'IMAPS'
ufw allow 995/tcp comment 'POP3S'
ufw allow 3306/tcp comment 'MySQL'
ufw allow 5432/tcp comment 'PostgreSQL'
ufw allow 8080/tcp comment 'Serviços Web Alternativos'

echo "y" | ufw enable
print_message "Firewall configurado"

# 4. Instalação e configuração do banco de dados
print_message "4. Instalando bancos de dados..."

# 4.1 Instalar MySQL/MariaDB
print_message "4.1 Instalando MariaDB..."
apt-get install -y -qq mariadb-server mariadb-client

# Configurar MySQL
systemctl start mariadb
systemctl enable mariadb

# Configurar senha root e segurança básica
mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$SENHA';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

# Criar banco de dados para aplicações educacionais
mysql -u root -p$SENHA <<EOF
CREATE DATABASE IF NOT EXISTS semed_educacao;
CREATE DATABASE IF NOT EXISTS semed_escolas;
CREATE DATABASE IF NOT EXISTS semed_alunos;
CREATE DATABASE IF NOT EXISTS semed_professores;
GRANT ALL PRIVILEGES ON semed_*.* TO 'semed'@'localhost' IDENTIFIED BY '$SENHA';
GRANT ALL PRIVILEGES ON semed_*.* TO 'semed'@'%' IDENTIFIED BY '$SENHA';
FLUSH PRIVILEGES;
EOF

print_message "MariaDB configurado com sucesso"

# 4.2 Instalar PostgreSQL (opcional, para sistemas mais robustos)
print_message "4.2 Instalando PostgreSQL..."
apt-get install -y -qq postgresql postgresql-contrib

systemctl start postgresql
systemctl enable postgresql

# Configurar PostgreSQL
sudo -u postgres psql <<EOF
CREATE USER semed WITH PASSWORD '$SENHA';
CREATE DATABASE semed_sistema OWNER semed;
CREATE DATABASE semed_relatorios OWNER semed;
GRANT ALL PRIVILEGES ON DATABASE semed_sistema TO semed;
GRANT ALL PRIVILEGES ON DATABASE semed_relatorios TO semed;
EOF

print_message "PostgreSQL configurado com sucesso"

# 5. Configuração de armazenamento de arquivos
print_message "5. Configurando sistema de arquivos..."

# Criar estrutura de diretórios
mkdir -p /dados/{documentos,imagens,videos,backups,relatorios,logs,aplicacoes,temporario}
mkdir -p /dados/documentos/{alunos,professores,escolas,administrativo}
mkdir -p /dados/imagens/{perfil,eventos,patrimonio}
mkdir -p /dados/videos/{aulas,eventos}
mkdir -p /dados/backups/{diario,semanal,mensal}
mkdir -p /dados/logs/{sistemas,acessos,erros}
mkdir -p /dados/aplicacoes/{portal,sige,gestao}

# Configurar permissões
chown -R $USUARIO:$USUARIO /dados
chmod -R 755 /dados
chmod -R 775 /dados/documentos
chmod -R 775 /dados/backups

# Criar link simbólico na home do usuário
ln -s /dados /home/$USUARIO/dados
chown -h $USUARIO:$USUARIO /home/$USUARIO/dados

print_message "Estrutura de diretórios criada em /dados"

# 6. Instalar e configurar servidor web (Nginx)
print_message "6. Instalando servidor web Nginx..."

apt-get install -y -qq nginx

# Configurar Nginx
cat > /etc/nginx/sites-available/semed.conf <<EOF
server {
    listen 80;
    server_name $DOMINIO www.$DOMINIO;
    root /var/www/semed/public;
    
    access_log /dados/logs/acessos/semed_access.log;
    error_log /dados/logs/erros/semed_error.log;
    
    index index.php index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    }
    
    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -s /etc/nginx/sites-available/semed.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Criar diretório web
mkdir -p /var/www/semed/public
echo "<?php phpinfo(); ?>" > /var/www/semed/public/index.php
chown -R www-data:www-data /var/www/semed

# 7. Instalar PHP e extensões
print_message "7. Instalando PHP e extensões..."

apt-get install -y -qq php8.1-fpm php8.1-cli php8.1-common php8.1-mysql \
    php8.1-pgsql php8.1-mongodb php8.1-sqlite3 php8.1-redis \
    php8.1-memcached php8.1-curl php8.1-gd php8.1-xml php8.1-mbstring \
    php8.1-zip php8.1-bcmath php8.1-intl php8.1-readline \
    php8.1-soap php8.1-ldap php8.1-imap php8.1-opcache \
    php-pear

# Configurar PHP
sed -i 's/memory_limit = .*/memory_limit = 512M/' /etc/php/8.1/fpm/php.ini
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 100M/' /etc/php/8.1/fpm/php.ini
sed -i 's/post_max_size = .*/post_max_size = 100M/' /etc/php/8.1/fpm/php.ini
sed -i 's/max_execution_time = .*/max_execution_time = 300/' /etc/php/8.1/fpm/php.ini

systemctl restart php8.1-fpm
systemctl restart nginx

print_message "PHP configurado com sucesso"

# 8. Instalar e configurar servidor de email
print_message "8. Configurando servidor de email..."

# 8.1 Instalar Postfix
debconf-set-selections <<< "postfix postfix/mailname string $DOMINIO"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"

apt-get install -y -qq postfix postfix-mysql postfix-doc \
    mailutils libsasl2-2 libsasl2-modules dovecot-core dovecot-imapd \
    dovecot-pop3d dovecot-mysql dovecot-lmtpd

# Configuração básica do Postfix
postconf -e "myhostname = $DOMINIO"
postconf -e "mydomain = $DOMINIO"
postconf -e "myorigin = /etc/mailname"
postconf -e "inet_interfaces = all"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
postconf -e "home_mailbox = Maildir/"
postconf -e "smtpd_banner = \$myhostname ESMTP"
postconf -e "biff = no"

# 8.2 Instalar Dovecot
cat > /etc/dovecot/dovecot.conf <<EOF
# Configuração Dovecot
protocols = imap pop3 lmtp
listen = *, ::
base_dir = /var/run/dovecot/

ssl = no

mail_location = maildir:~/Maildir

namespace inbox {
  inbox = yes
  separator = /
}

protocol imap {
  mail_plugins = \$mail_plugins
}

protocol pop3 {
  pop3_uidl_format = %08Xu%08Xv
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
}

auth_mechanisms = plain login
!include auth-system.conf.ext
EOF

# 8.3 Instalar SpamAssassin e ClamAV para segurança de email
print_message "8.3 Instalando ferramentas de segurança de email..."
apt-get install -y -qq spamassassin clamav-daemon amavisd-new

systemctl restart postfix dovecot
systemctl enable postfix dovecot

print_message "Servidor de email configurado"

# 9. Configurar backups automáticos
print_message "9. Configurando sistema de backups..."

cat > /usr/local/bin/backup-semed.sh <<EOF
#!/bin/bash
# Script de backup automático - SEMED

DATA=\$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/dados/backups/diario"

# Backup MySQL
mysqldump -u root -p$SENHA --all-databases > \$BACKUP_DIR/mysql_all_\$DATA.sql
gzip \$BACKUP_DIR/mysql_all_\$DATA.sql

# Backup PostgreSQL
sudo -u postgres pg_dumpall > \$BACKUP_DIR/postgres_all_\$DATA.sql
gzip \$BACKUP_DIR/postgres_all_\$DATA.sql

# Backup dos documentos
tar -czf \$BACKUP_DIR/documentos_\$DATA.tar.gz /dados/documentos/

# Backup das configurações
tar -czf \$BACKUP_DIR/config_\$DATA.tar.gz /etc/{nginx,php,postfix,dovecot,mysql}

# Remover backups antigos (mais de 30 dias)
find \$BACKUP_DIR -type f -name "*.gz" -mtime +30 -delete

echo "Backup concluído em \$DATA" >> /dados/logs/backup.log
EOF

chmod +x /usr/local/bin/backup-semed.sh

# Agendar backup diário
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/backup-semed.sh") | crontab -

print_message "Backup automático configurado"

# 10. Configurar monitoramento básico
print_message "10. Configurando monitoramento..."

cat > /usr/local/bin/monitor-semed.sh <<EOF
#!/bin/bash
# Script de monitoramento - SEMED

# Verificar espaço em disco
DISK_USAGE=\$(df -h / | awk 'NR==2 {print \$5}' | sed 's/%//')
if [ \$DISK_USAGE -gt 80 ]; then
    echo "ALERTA: Uso de disco em \$DISK_USAGE%" >> /dados/logs/monitoramento.log
fi

# Verificar serviços
for service in nginx mysql postfix dovecot; do
    if ! systemctl is-active --quiet \$service; then
        echo "ALERTA: Serviço \$service está inativo" >> /dados/logs/monitoramento.log
    fi
done

# Verificar memória
MEM_USAGE=\$(free | grep Mem | awk '{print (\$3/\$2)*100}' | cut -d. -f1)
if [ \$MEM_USAGE -gt 90 ]; then
    echo "ALERTA: Uso de memória em \$MEM_USAGE%" >> /dados/logs/monitoramento.log
fi
EOF

chmod +x /usr/local/bin/monitor-semed.sh

# Agendar monitoramento a cada hora
(crontab -l 2>/dev/null; echo "0 * * * * /usr/local/bin/monitor-semed.sh") | crontab -

print_message "Monitoramento configurado"

# 11. Configurar segurança avançada
print_message "11. Configurando segurança avançada..."

# Fail2ban para proteção contra brute force
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true

[nginx-http-auth]
enabled = true

[postfix]
enabled = true

[dovecot]
enabled = true
EOF

systemctl restart fail2ban

# Configurar atualizações automáticas
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

print_message "Segurança avançada configurada"

# 12. Instalar ferramentas educacionais recomendadas
print_message "12. Instalando ferramentas educacionais..."

# Moodle (plataforma de ensino)
cd /var/www
git clone git://git.moodle.org/moodle.git
cd moodle
git checkout MOODLE_401_STABLE
cp -r * /var/www/semed/public/
chown -R www-data:www-data /var/www/semed/

# Configurar diretório de dados do Moodle
mkdir -p /dados/moodle
chown -R www-data:www-data /dados/moodle
chmod -R 755 /dados/moodle

# Nextcloud (compartilhamento de arquivos)
cd /tmp
wget https://download.nextcloud.com/server/releases/latest.zip
unzip latest.zip
mv nextcloud /var/www/semed/public/cloud
chown -R www-data:www-data /var/www/semed/public/cloud

print_message "Ferramentas educacionais instaladas"

# 13. Configurar acesso remoto seguro
print_message "13. Configurando acesso remoto..."

# Configurar chave SSH para o usuário semed
mkdir -p /home/$USUARIO/.ssh
ssh-keygen -t rsa -b 4096 -f /home/$USUARIO/.ssh/id_rsa -N ""
cat /home/$USUARIO/.ssh/id_rsa.pub >> /home/$USUARIO/.ssh/authorized_keys
chown -R $USUARIO:$USUARIO /home/$USUARIO/.ssh
chmod 700 /home/$USUARIO/.ssh
chmod 600 /home/$USUARIO/.ssh/authorized_keys

# 14. Gerar relatório final
print_message "14. Gerando relatório de instalação..."

cat > /home/$USUARIO/relatorio_instalacao.txt <<EOF
==================================================
RELATÓRIO DE INSTALAÇÃO DO SERVIDOR SEMED
==================================================
Data: $(date)
Hostname: $HOSTNAME
Domínio: $DOMINIO

SERVIÇOS INSTALADOS:
--------------------
✓ Sistema Base: Ubuntu Server
✓ Bancos de Dados: MariaDB e PostgreSQL
✓ Servidor Web: Nginx + PHP 8.1
✓ Servidor de Email: Postfix + Dovecot
✓ Armazenamento: Estrutura em /dados
✓ Backup Automático: Configurado para 02:00
✓ Monitoramento: Configurado (check a cada hora)
✓ Firewall: UFW ativo com regras básicas
✓ Fail2ban: Proteção contra brute force

ACESSOS:
--------
Usuário padrão: $USUARIO
Senha padrão: $SENHA
Acesso SSH: ssh $USUARIO@$(hostname -I | awk '{print $1}')

BANCOS DE DADOS:
----------------
MySQL: mysql -u root -p
Senha root MySQL: $SENHA
Bancos criados: semed_educacao, semed_escolas, semed_alunos, semed_professores

PostgreSQL: sudo -u postgres psql
Senha user semed PostgreSQL: $SENHA
Bancos criados: semed_sistema, semed_relatorios

DIRETÓRIOS IMPORTANTES:
-----------------------
Dados: /dados/
Backups: /dados/backups/
Logs: /dados/logs/
Documentos: /dados/documentos/
Aplicações Web: /var/www/semed/

SERVIÇOS WEB:
-------------
Site padrão: http://$(hostname -I | awk '{print $1}')
Moodle: http://$(hostname -I | awk '{print $1}')/moodle
Nextcloud: http://$(hostname -I | awk '{print $1}')/cloud

CHAVE SSH PÚBLICA (para acesso remoto):
$(cat /home/$USUARIO/.ssh/id_rsa.pub)

PRÓXIMOS PASSOS RECOMENDADOS:
-----------------------------
1. Configurar DNS para apontar $DOMINIO para este servidor
2. Obter e configurar certificado SSL (Let's Encrypt)
3. Configurar regras específicas de firewall conforme necessidade
4. Testar serviços de email com domínio real
5. Configurar backups externos adicionais
6. Revisar e ajustar senhas conforme política de segurança

==================================================
Instalação concluída com sucesso!
==================================================
EOF

chown $USUARIO:$USUARIO /home/$USUARIO/relatorio_instalacao.txt

# Finalização
print_message "✅ INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
print_message "📁 Relatório salvo em: /home/$USUARIO/relatorio_instalacao.txt"
print_message "🔑 Usuário: $USUARIO | Senha: $SENHA"
print_message "🌐 Acesse o servidor via: ssh $USUARIO@$(hostname -I | awk '{print $1}')"
print_message "📊 Recomendamos reiniciar o servidor agora."

# Perguntar se deseja reiniciar
read -p "Deseja reiniciar o servidor agora? (s/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Ss]$ ]]; then
    print_message "Reiniciando em 10 segundos..."
    sleep 10
    reboot
else
    print_message "Lembre-se de reiniciar o servidor em breve para aplicar todas as configurações."
fi
