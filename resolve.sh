#!/usr/bin/env bash
set -Eeuo pipefail

# Rebuilds the OpenSSH server configuration used by SEMED and ensures that
# remote access by public key is available before sshd is reloaded.
#
# Usage:
#   sudo env SSH_USER=deploy SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' bash scripts/reconfigure-ssh-hardening.sh
#   sudo env SSH_USER=deploy PUBLIC_KEY_FILE=/tmp/access.pub bash scripts/reconfigure-ssh-hardening.sh
#
# Optional:
#   SSH_PORT=22
#   ALLOW_PASSWORD_AUTH=no
#   ALLOW_ROOT_LOGIN=no
#   ALLOW_USERS='deploy ubuntu'
#   RESTART_SSH=yes

SSHD_CONFIG="/etc/ssh/sshd_config"
SSH_DIR="/etc/ssh"
BACKUP_ROOT="${BACKUP_ROOT:-/root}"
SSH_PORT="${SSH_PORT:-22}"
ALLOW_PASSWORD_AUTH="${ALLOW_PASSWORD_AUTH:-no}"
ALLOW_ROOT_LOGIN="${ALLOW_ROOT_LOGIN:-no}"
RESTART_SSH="${RESTART_SSH:-yes}"

log() {
  printf '[semed-ssh] %s\n' "$*"
}

fail() {
  printf '[semed-ssh] ERRO: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "execute este script como root, por exemplo: sudo env SSH_USER=deploy SSH_PUBLIC_KEY='ssh-ed25519 ...' bash $0"
  fi
}

find_default_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && getent passwd "${SUDO_USER}" >/dev/null; then
    printf '%s\n' "${SUDO_USER}"
    return 0
  fi

  awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ { print $1; exit }' /etc/passwd
}

normalize_yes_no() {
  local name="$1"
  local value="$2"

  case "${value}" in
    yes|no) printf '%s\n' "${value}" ;;
    *) fail "${name} deve ser 'yes' ou 'no', recebido: ${value}" ;;
  esac
}

validate_port() {
  if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    fail "SSH_PORT deve ser um numero entre 1 e 65535"
  fi
}

detect_sshd() {
  if command -v sshd >/dev/null 2>&1; then
    command -v sshd
    return 0
  fi

  if [[ -x /usr/sbin/sshd ]]; then
    printf '/usr/sbin/sshd\n'
    return 0
  fi

  fail "sshd nao encontrado. Instale openssh-server antes de rodar este script."
}

detect_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files --type=service --no-legend ssh.service 2>/dev/null | grep -q '^ssh\.service'; then
      printf 'ssh\n'
      return 0
    fi

    if systemctl list-unit-files --type=service --no-legend sshd.service 2>/dev/null | grep -q '^sshd\.service'; then
      printf 'sshd\n'
      return 0
    fi
  fi

  if command -v service >/dev/null 2>&1; then
    if service ssh status >/dev/null 2>&1; then
      printf 'ssh\n'
      return 0
    fi

    if service sshd status >/dev/null 2>&1; then
      printf 'sshd\n'
      return 0
    fi
  fi

  printf ''
}

backup_ssh_config() {
  local timestamp backup_dir

  timestamp="$(date +%Y%m%d%H%M%S)"
  backup_dir="${BACKUP_ROOT%/}/semed-ssh-backup-${timestamp}"
  mkdir -p "${backup_dir}"

  if [[ -f "${SSHD_CONFIG}" ]]; then
    cp -a "${SSHD_CONFIG}" "${backup_dir}/sshd_config"
  fi

  if [[ -d "${SSH_DIR}/sshd_config.d" ]]; then
    mkdir -p "${backup_dir}/sshd_config.d"
    cp -a "${SSH_DIR}/sshd_config.d/." "${backup_dir}/sshd_config.d/"
  fi

  printf '%s\n' "${backup_dir}"
}

restore_ssh_config() {
  local backup_dir="$1"

  log "restaurando backup em ${backup_dir}"
  if [[ -f "${backup_dir}/sshd_config" ]]; then
    cp -a "${backup_dir}/sshd_config" "${SSHD_CONFIG}"
  fi
}

prepare_authorized_keys() {
  local ssh_user="$1"
  local user_home user_group authorized_keys key_material installed_any public_key tmp_key

  user_home="$(getent passwd "${ssh_user}" | cut -d: -f6)"
  user_group="$(id -gn "${ssh_user}")"
  authorized_keys="${user_home}/.ssh/authorized_keys"

  install -d -m 700 -o "${ssh_user}" -g "${user_group}" "${user_home}/.ssh"
  touch "${authorized_keys}"
  chown "${ssh_user}:${user_group}" "${authorized_keys}"
  chmod 600 "${authorized_keys}"

  key_material=""
  if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    key_material="${SSH_PUBLIC_KEY}"
  elif [[ -n "${PUBLIC_KEY_FILE:-}" ]]; then
    [[ -r "${PUBLIC_KEY_FILE}" ]] || fail "PUBLIC_KEY_FILE nao existe ou nao pode ser lido: ${PUBLIC_KEY_FILE}"
    key_material="$(cat "${PUBLIC_KEY_FILE}")"
  fi

  installed_any="no"
  if [[ -n "${key_material}" ]]; then
    while IFS= read -r public_key || [[ -n "${public_key}" ]]; do
      public_key="${public_key%$'\r'}"
      [[ -z "${public_key}" || "${public_key}" =~ ^[[:space:]]*# ]] && continue

      tmp_key="$(mktemp)"
      printf '%s\n' "${public_key}" > "${tmp_key}"
      if ! ssh-keygen -l -f "${tmp_key}" >/dev/null 2>&1; then
        rm -f "${tmp_key}"
        fail "chave publica invalida: ${public_key%% *}"
      fi
      rm -f "${tmp_key}"

      if ! grep -qxF "${public_key}" "${authorized_keys}"; then
        printf '%s\n' "${public_key}" >> "${authorized_keys}"
        installed_any="yes"
      fi
    done <<< "${key_material}"

    chown "${ssh_user}:${user_group}" "${authorized_keys}"
    chmod 600 "${authorized_keys}"
  fi

  if [[ ! -s "${authorized_keys}" ]]; then
    fail "nenhuma chave autorizada encontrada para ${ssh_user}; informe SSH_PUBLIC_KEY ou PUBLIC_KEY_FILE"
  fi

  if [[ "${installed_any}" == "yes" ]]; then
    log "chave publica adicionada em ${authorized_keys}"
  else
    log "usando chaves ja existentes em ${authorized_keys}"
  fi
}

write_sshd_config() {
  local ssh_user="$1"
  local permit_root_login="$2"
  local password_auth="$3"
  local allow_users_line=""

  if [[ -n "${ALLOW_USERS:-}" ]]; then
    allow_users_line="AllowUsers ${ALLOW_USERS}"
  fi

  cat > "${SSHD_CONFIG}" <<EOF
# Managed by scripts/reconfigure-ssh-hardening.sh.
# Backup is created in /root/semed-ssh-backup-* before changes.

Port ${SSH_PORT}
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

SyslogFacility AUTH
LogLevel VERBOSE

LoginGraceTime 30
PermitRootLogin ${permit_root_login}
StrictModes yes
MaxAuthTries 3
MaxSessions 4

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM yes

X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
PermitUserEnvironment no

ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive yes
Compression delayed

AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
${allow_users_line}
EOF

  chmod 644 "${SSHD_CONFIG}"
  log "sshd_config reescrito para login por chave publica do usuario ${ssh_user}"
}

open_firewall_port() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    log "liberando porta ${SSH_PORT}/tcp no ufw"
    ufw allow "${SSH_PORT}/tcp" >/dev/null
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "liberando porta ${SSH_PORT}/tcp no firewalld"
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
  fi
}

reload_sshd() {
  local service_name="$1"

  if [[ "${RESTART_SSH}" != "yes" ]]; then
    log "RESTART_SSH=${RESTART_SSH}; configuracao validada, mas servico nao foi recarregado"
    return 0
  fi

  if [[ -n "${service_name}" ]] && command -v systemctl >/dev/null 2>&1; then
    if systemctl reload "${service_name}" >/dev/null 2>&1; then
      log "servico ${service_name} recarregado"
      return 0
    fi

    systemctl restart "${service_name}"
    log "servico ${service_name} reiniciado"
    return 0
  fi

  if [[ -n "${service_name}" ]] && command -v service >/dev/null 2>&1; then
    service "${service_name}" reload >/dev/null 2>&1 || service "${service_name}" restart
    log "servico ${service_name} recarregado"
    return 0
  fi

  fail "nao foi possivel detectar o servico ssh/sshd para recarregar"
}

main() {
  require_root

  local ssh_user backup_dir sshd_bin service_name password_auth permit_root_login

  SSH_USER="${SSH_USER:-$(find_default_user)}"
  [[ -n "${SSH_USER}" ]] || fail "informe SSH_USER, por exemplo SSH_USER=deploy"
  getent passwd "${SSH_USER}" >/dev/null || fail "usuario nao existe: ${SSH_USER}"

  validate_port
  password_auth="$(normalize_yes_no "ALLOW_PASSWORD_AUTH" "${ALLOW_PASSWORD_AUTH}")"
  permit_root_login="${ALLOW_ROOT_LOGIN}"

  if [[ "${SSH_USER}" == "root" && "${permit_root_login}" == "no" ]]; then
    permit_root_login="prohibit-password"
    log "SSH_USER=root; ajustando PermitRootLogin para prohibit-password"
  fi

  case "${permit_root_login}" in
    yes|no|prohibit-password|forced-commands-only) ;;
    *) fail "ALLOW_ROOT_LOGIN deve ser yes, no, prohibit-password ou forced-commands-only" ;;
  esac

  sshd_bin="$(detect_sshd)"
  service_name="$(detect_service)"
  backup_dir="$(backup_ssh_config)"
  log "backup criado em ${backup_dir}"

  prepare_authorized_keys "${SSH_USER}"

  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A
  fi

  write_sshd_config "${SSH_USER}" "${permit_root_login}" "${password_auth}"
  open_firewall_port

  if ! "${sshd_bin}" -t -f "${SSHD_CONFIG}"; then
    restore_ssh_config "${backup_dir}"
    fail "configuracao SSH invalida; backup restaurado"
  fi

  reload_sshd "${service_name}"

  log "pronto. Teste em outro terminal: ssh -p ${SSH_PORT} ${SSH_USER}@SEU_SERVIDOR"
  log "mantenha esta sessao aberta ate confirmar que o novo acesso SSH funciona"
}

main "$@"
