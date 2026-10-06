#!/usr/bin/env bash
set -Eeuo pipefail

# Aggressive SSH recovery for SEMED VPS.
#
# Run from a server console, rescue shell, or provider web terminal when SSH is
# not reachable from outside.
#
# Examples:
#   sudo bash scripts/aggressive-ssh-fix.sh
#   sudo env SSH_USER=edu SSH_PORT=22 SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' bash scripts/aggressive-ssh-fix.sh
#   sudo env SSH_USER=edu PUBLIC_KEY_FILE=/tmp/semed.pub NEW_PASSWORD='TroqueEssaSenha123' bash scripts/aggressive-ssh-fix.sh
#
# Defaults:
#   SSH_USER: first sudo user, first regular user, or root
#   SSH_PORT: 22
#   PERMIT_ROOT_LOGIN: prohibit-password
#   PASSWORD_AUTH: yes
#   RESTART_SSH: yes

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
BACKUP_ROOT="${BACKUP_ROOT:-/root}"
SSH_PORT="${SSH_PORT:-22}"
PASSWORD_AUTH="${PASSWORD_AUTH:-yes}"
PERMIT_ROOT_LOGIN="${PERMIT_ROOT_LOGIN:-prohibit-password}"
RESTART_SSH="${RESTART_SSH:-yes}"

log() {
  printf '[semed-ssh-fix] %s\n' "$*"
}

fail() {
  printf '[semed-ssh-fix] ERRO: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "execute como root: sudo bash $0"
  fi
}

validate_port() {
  if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    fail "SSH_PORT deve ser um numero entre 1 e 65535"
  fi
}

validate_options() {
  case "${PASSWORD_AUTH}" in
    yes|no) ;;
    *) fail "PASSWORD_AUTH deve ser yes ou no" ;;
  esac

  case "${PERMIT_ROOT_LOGIN}" in
    yes|no|prohibit-password|forced-commands-only) ;;
    *) fail "PERMIT_ROOT_LOGIN deve ser yes, no, prohibit-password ou forced-commands-only" ;;
  esac
}

detect_sshd() {
  if command -v sshd >/dev/null 2>&1; then
    command -v sshd
    return
  fi

  if [[ -x /usr/sbin/sshd ]]; then
    printf '/usr/sbin/sshd\n'
    return
  fi

  fail "sshd nao encontrado; instale openssh-server antes de rodar este script"
}

detect_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files --type=service --no-legend ssh.service 2>/dev/null | grep -q '^ssh\.service'; then
      printf 'ssh\n'
      return
    fi

    if systemctl list-unit-files --type=service --no-legend sshd.service 2>/dev/null | grep -q '^sshd\.service'; then
      printf 'sshd\n'
      return
    fi
  fi

  if command -v service >/dev/null 2>&1; then
    if service ssh status >/dev/null 2>&1; then
      printf 'ssh\n'
      return
    fi

    if service sshd status >/dev/null 2>&1; then
      printf 'sshd\n'
      return
    fi
  fi

  printf ''
}

find_recovery_user() {
  if [[ -n "${SSH_USER:-}" ]]; then
    printf '%s\n' "${SSH_USER}"
    return
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && getent passwd "${SUDO_USER}" >/dev/null; then
    printf '%s\n' "${SUDO_USER}"
    return
  fi

  local regular_user
  regular_user="$(awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ { print $1; exit }' /etc/passwd)"
  if [[ -n "${regular_user}" ]]; then
    printf '%s\n' "${regular_user}"
    return
  fi

  printf 'root\n'
}

backup_ssh() {
  local timestamp backup_dir
  timestamp="$(date +%Y%m%d%H%M%S)"
  backup_dir="${BACKUP_ROOT%/}/semed-aggressive-ssh-fix-${timestamp}"
  mkdir -p "${backup_dir}"

  [[ -f "${SSHD_CONFIG}" ]] && cp -a "${SSHD_CONFIG}" "${backup_dir}/sshd_config"
  if [[ -d "${SSHD_CONFIG_D}" ]]; then
    mkdir -p "${backup_dir}/sshd_config.d"
    cp -a "${SSHD_CONFIG_D}/." "${backup_dir}/sshd_config.d/"
  fi

  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose > "${backup_dir}/ufw-status.txt" 2>&1 || true
  fi

  printf '%s\n' "${backup_dir}"
}

restore_ssh_config() {
  local backup_dir="$1"
  log "restaurando configuracao SSH de ${backup_dir}"

  [[ -f "${backup_dir}/sshd_config" ]] && cp -a "${backup_dir}/sshd_config" "${SSHD_CONFIG}"
  if [[ -d "${backup_dir}/sshd_config.d" ]]; then
    mkdir -p "${SSHD_CONFIG_D}"
    cp -a "${backup_dir}/sshd_config.d/." "${SSHD_CONFIG_D}/"
  fi
}

neutralize_dropins() {
  local backup_dir="$1"
  mkdir -p "${SSHD_CONFIG_D}" "${backup_dir}/disabled-dropins"

  shopt -s nullglob
  local file
  for file in "${SSHD_CONFIG_D}"/*.conf; do
    cp -a "${file}" "${backup_dir}/disabled-dropins/$(basename "${file}")"
    mv -f "${file}" "${file}.disabled-by-aggressive-fix"
    log "drop-in desativado: ${file}"
  done
  shopt -u nullglob
}

install_public_keys() {
  local ssh_user="$1"
  local user_home user_group authorized_keys key_material public_key tmp_key

  getent passwd "${ssh_user}" >/dev/null || fail "usuario nao existe: ${ssh_user}"
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
    [[ -r "${PUBLIC_KEY_FILE}" ]] || fail "PUBLIC_KEY_FILE nao pode ser lido: ${PUBLIC_KEY_FILE}"
    key_material="$(cat "${PUBLIC_KEY_FILE}")"
  fi

  if [[ -z "${key_material}" ]]; then
    log "nenhuma chave publica informada; mantendo authorized_keys atual"
    return
  fi

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
      log "chave publica adicionada em ${authorized_keys}"
    fi
  done <<< "${key_material}"

  chown "${ssh_user}:${user_group}" "${authorized_keys}"
  chmod 600 "${authorized_keys}"
}

set_user_password() {
  local ssh_user="$1"

  if [[ -z "${NEW_PASSWORD:-}" ]]; then
    log "NEW_PASSWORD nao informado; senha do usuario nao foi alterada"
    return
  fi

  printf '%s:%s\n' "${ssh_user}" "${NEW_PASSWORD}" | chpasswd
  passwd -u "${ssh_user}" >/dev/null 2>&1 || true
  log "senha definida e usuario destravado: ${ssh_user}"
}

write_recovery_sshd_config() {
  cat > "${SSHD_CONFIG}" <<EOF
# Managed by scripts/aggressive-ssh-fix.sh.
# Backup created in ${BACKUP_ROOT}/semed-aggressive-ssh-fix-* before changes.

Port ${SSH_PORT}
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

SyslogFacility AUTH
LogLevel VERBOSE

LoginGraceTime 120
PermitRootLogin ${PERMIT_ROOT_LOGIN}
StrictModes yes
MaxAuthTries 10
MaxSessions 10

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication ${PASSWORD_AUTH}
KbdInteractiveAuthentication ${PASSWORD_AUTH}
PermitEmptyPasswords no
UsePAM yes

X11Forwarding no
AllowAgentForwarding yes
AllowTcpForwarding yes
PermitTunnel no
PermitUserEnvironment no

ClientAliveInterval 300
ClientAliveCountMax 3
TCPKeepAlive yes
Compression delayed

AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
EOF

  chmod 644 "${SSHD_CONFIG}"
  log "sshd_config de recuperacao escrito em ${SSHD_CONFIG}"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi '^Status: active'; then
      log "liberando SSH no ufw: ${SSH_PORT}/tcp"
      ufw allow "${SSH_PORT}/tcp" >/dev/null || true
      ufw reload >/dev/null || true
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "liberando SSH no firewalld: ${SSH_PORT}/tcp"
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
  fi

  if command -v iptables >/dev/null 2>&1; then
    if ! iptables -C INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT >/dev/null 2>&1; then
      iptables -I INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT || true
      log "regra permissiva adicionada ao iptables para ${SSH_PORT}/tcp"
    fi
  fi
}

unban_fail2ban() {
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    return
  fi

  local jail
  while IFS= read -r jail; do
    jail="${jail//[[:space:]]/}"
    [[ -z "${jail}" ]] && continue
    fail2ban-client unban --all >/dev/null 2>&1 || true
    fail2ban-client set "${jail}" unbanip --all >/dev/null 2>&1 || true
  done < <(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' '\n')

  log "fail2ban destravado quando disponivel"
}

restart_ssh_service() {
  local service_name="$1"

  if [[ "${RESTART_SSH}" != "yes" ]]; then
    log "RESTART_SSH=${RESTART_SSH}; servico SSH nao foi reiniciado"
    return
  fi

  if [[ -n "${service_name}" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl enable "${service_name}" >/dev/null 2>&1 || true
    systemctl restart "${service_name}"
    log "servico ${service_name} reiniciado"
    return
  fi

  if [[ -n "${service_name}" ]] && command -v service >/dev/null 2>&1; then
    service "${service_name}" restart
    log "servico ${service_name} reiniciado"
    return
  fi

  fail "nao foi possivel detectar servico ssh/sshd"
}

print_diagnostics() {
  local ssh_user="$1"
  local service_name="$2"

  log "diagnostico:"
  log "usuario: ${ssh_user}"
  log "porta: ${SSH_PORT}"
  log "servico: ${service_name:-nao detectado}"

  if command -v ss >/dev/null 2>&1; then
    ss -ltnp | grep -E ":((${SSH_PORT}))\\b" || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp | grep -E ":((${SSH_PORT}))\\b" || true
  fi
}

main() {
  require_root
  validate_port
  validate_options

  local backup_dir sshd_bin service_name ssh_user
  sshd_bin="$(detect_sshd)"
  service_name="$(detect_service)"
  ssh_user="$(find_recovery_user)"

  backup_dir="$(backup_ssh)"
  log "backup criado em ${backup_dir}"

  neutralize_dropins "${backup_dir}"
  install_public_keys "${ssh_user}"
  set_user_password "${ssh_user}"

  ssh-keygen -A >/dev/null 2>&1 || true
  write_recovery_sshd_config
  open_firewall
  unban_fail2ban

  if ! "${sshd_bin}" -t -f "${SSHD_CONFIG}"; then
    restore_ssh_config "${backup_dir}"
    fail "configuracao SSH invalida; backup restaurado"
  fi

  restart_ssh_service "${service_name}"
  print_diagnostics "${ssh_user}" "${service_name}"

  log "pronto. Teste agora em outro terminal:"
  log "ssh -p ${SSH_PORT} ${ssh_user}@SEU_SERVIDOR"
  log "mantenha o console/recovery aberto ate confirmar que o acesso voltou"
}

main "$@"
