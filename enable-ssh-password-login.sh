#!/usr/bin/env bash
set -Eeuo pipefail

# Removes the SEMED SSH hardening profile and enables remote password login.
#
# Run from a server console/recovery shell if SSH access is currently broken.
#
# Usage:
#   sudo bash scripts/enable-ssh-password-login.sh
#
# Optional:
#   SSH_PORT=22
#   PERMIT_ROOT_LOGIN=no
#   RESTART_SSH=yes
#   BACKUP_ROOT=/root
#
# If the target user has no password or the password is locked, set it after
# this script with: sudo passwd USERNAME

SSHD_CONFIG="/etc/ssh/sshd_config"
SSH_DIR="/etc/ssh"
SSHD_CONFIG_D="${SSH_DIR}/sshd_config.d"
BACKUP_ROOT="${BACKUP_ROOT:-/root}"
SSH_PORT="${SSH_PORT:-22}"
PERMIT_ROOT_LOGIN="${PERMIT_ROOT_LOGIN:-no}"
RESTART_SSH="${RESTART_SSH:-yes}"

log() {
  printf '[semed-ssh-password] %s\n' "$*"
}

fail() {
  printf '[semed-ssh-password] ERRO: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "execute este script como root, por exemplo: sudo bash $0"
  fi
}

validate_port() {
  if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    fail "SSH_PORT deve ser um numero entre 1 e 65535"
  fi
}

validate_root_login_mode() {
  case "${PERMIT_ROOT_LOGIN}" in
    yes|no|prohibit-password|forced-commands-only) ;;
    *) fail "PERMIT_ROOT_LOGIN deve ser yes, no, prohibit-password ou forced-commands-only" ;;
  esac
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
  backup_dir="${BACKUP_ROOT%/}/semed-ssh-password-backup-${timestamp}"
  mkdir -p "${backup_dir}"

  if [[ -f "${SSHD_CONFIG}" ]]; then
    cp -a "${SSHD_CONFIG}" "${backup_dir}/sshd_config"
  fi

  if [[ -d "${SSHD_CONFIG_D}" ]]; then
    mkdir -p "${backup_dir}/sshd_config.d"
    cp -a "${SSHD_CONFIG_D}/." "${backup_dir}/sshd_config.d/"
  fi

  printf '%s\n' "${backup_dir}"
}

restore_ssh_config() {
  local backup_dir="$1"

  log "restaurando backup em ${backup_dir}"

  if [[ -f "${backup_dir}/sshd_config" ]]; then
    cp -a "${backup_dir}/sshd_config" "${SSHD_CONFIG}"
  fi

  if [[ -d "${backup_dir}/sshd_config.d" ]]; then
    mkdir -p "${SSHD_CONFIG_D}"
    find "${SSHD_CONFIG_D}" -maxdepth 1 -type f -name '*semed*.conf.disabled' -exec rm -f {} +
    cp -a "${backup_dir}/sshd_config.d/." "${SSHD_CONFIG_D}/"
  fi
}

disable_semed_dropins() {
  local backup_dir="$1"
  local found="no"
  local file

  [[ -d "${SSHD_CONFIG_D}" ]] || return 0

  mkdir -p "${backup_dir}/disabled-semed-dropins"

  shopt -s nullglob
  for file in \
    "${SSHD_CONFIG_D}/99-semed-ssh-hardening.conf" \
    "${SSHD_CONFIG_D}/"*semed*".conf"; do
    [[ -f "${file}" ]] || continue
    found="yes"
    cp -a "${file}" "${backup_dir}/disabled-semed-dropins/$(basename "${file}")"
    mv -f "${file}" "${file}.disabled"
    log "drop-in SEMED desativado: ${file}"
  done
  shopt -u nullglob

  if [[ "${found}" == "no" ]]; then
    log "nenhum drop-in SEMED encontrado em ${SSHD_CONFIG_D}"
  fi
}

write_password_sshd_config() {
  cat > "${SSHD_CONFIG}" <<EOF
# Managed by scripts/enable-ssh-password-login.sh.
# Backup is created in /root/semed-ssh-password-backup-* before changes.

Port ${SSH_PORT}
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

SyslogFacility AUTH
LogLevel INFO

LoginGraceTime 60
PermitRootLogin ${PERMIT_ROOT_LOGIN}
StrictModes yes
MaxAuthTries 6
MaxSessions 10

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitEmptyPasswords no
UsePAM yes

X11Forwarding yes
PrintMotd no
TCPKeepAlive yes
Compression delayed

AcceptEnv LANG LC_*
Subsystem sftp internal-sftp

Include /etc/ssh/sshd_config.d/*.conf
EOF

  chmod 644 "${SSHD_CONFIG}"
  log "sshd_config reescrito com PasswordAuthentication yes"
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
  validate_port
  validate_root_login_mode

  local backup_dir sshd_bin service_name

  sshd_bin="$(detect_sshd)"
  service_name="$(detect_service)"
  backup_dir="$(backup_ssh_config)"
  log "backup criado em ${backup_dir}"

  disable_semed_dropins "${backup_dir}"

  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A
  fi

  write_password_sshd_config
  open_firewall_port

  if ! "${sshd_bin}" -t -f "${SSHD_CONFIG}"; then
    restore_ssh_config "${backup_dir}"
    fail "configuracao SSH invalida; backup restaurado"
  fi

  reload_sshd "${service_name}"

  log "pronto. Teste em outro terminal: ssh -p ${SSH_PORT} USUARIO@SEU_SERVIDOR"
  log "se o usuario nao tiver senha definida, use: sudo passwd USUARIO"
  log "mantenha esta sessao aberta ate confirmar que o login por senha funciona"
}

main "$@"
