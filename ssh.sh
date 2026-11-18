#!/usr/bin/env bash
# Execute localmente no console/VNC/serial da VPS como root.
# Não recebe senha por parâmetro nem a grava em arquivo ou histórico.
set -Eeuo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Execute como root no console local da VPS: sudo bash $0" >&2
  exit 1
fi

install_openssh() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y openssh-server
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openssh-server
  elif command -v yum >/dev/null 2>&1; then
    yum install -y openssh-server
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache openssh
  else
    echo "Não foi possível instalar OpenSSH automaticamente." >&2
    exit 1
  fi
}

if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
  echo "OpenSSH Server não encontrado; tentando instalar..."
  install_openssh
fi

SSHD_BIN=$(command -v sshd || printf '%s' /usr/sbin/sshd)
read -r -p "Usuário que poderá entrar por SSH: " SSH_USER

if ! [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "Nome de usuário inválido." >&2
  exit 1
fi

if id "$SSH_USER" >/dev/null 2>&1; then
  echo "O usuário '$SSH_USER' já existe. A senha será redefinida."
else
  useradd --create-home --shell /bin/bash "$SSH_USER"
  echo "Usuário '$SSH_USER' criado."
fi

echo "Defina agora a senha do usuário '$SSH_USER':"
passwd "$SSH_USER"

install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-semed-password-recovery.conf <<EOF
# Gerado por recuperar-ssh-por-senha.sh
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
EOF

# Em instalações antigas que não leem sshd_config.d, inclui o diretório de forma segura.
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
  printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> /etc/ssh/sshd_config
fi

"$SSHD_BIN" -t

if systemctl list-unit-files --type=service | grep -q '^ssh\.service'; then
  systemctl enable --now ssh
elif systemctl list-unit-files --type=service | grep -q '^sshd\.service'; then
  systemctl enable --now sshd
else
  service ssh restart 2>/dev/null || service sshd restart
fi

if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp
  ufw reload || true
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --reload
fi

echo
echo "SSH por senha habilitado para: $SSH_USER"
echo "Verificação local:"
ss -lntp | grep ':22' || true
echo "IP(s) detectado(s):"
hostname -I || true
echo "Atenção: se ainda não houver acesso externo, libere TCP/22 também no firewall da provedora."
