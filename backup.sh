#!/bin/sh
set -eu

# Full rescue backup before rebuilding the VPS.
#
# Run on the server:
#   sudo sh /opt/semed-site/current/scripts/rescue-full-backup.sh
#
# Optional:
#   sudo BACKUP_OUTPUT_DIR=/root sh /opt/semed-site/current/scripts/rescue-full-backup.sh
#
# The script creates one .tar.gz containing database dump, Docker volumes,
# current release/source, shared secrets, web/SSH configs and diagnostics.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
umask 077

APP_ROOT=${APP_ROOT:-/opt/semed-site}
CURRENT_DIR=${CURRENT_DIR:-$APP_ROOT/current}
SHARED_DIR=${SHARED_DIR:-$APP_ROOT/shared}
BACKUP_OUTPUT_DIR=${BACKUP_OUTPUT_DIR:-$SHARED_DIR/rescue-backups}
STAMP=$(date +%Y%m%d-%H%M%S)
WORK_DIR="$BACKUP_OUTPUT_DIR/rescue-$STAMP"
ARCHIVE="$BACKUP_OUTPUT_DIR/semed-rescue-$STAMP.tar.gz"
LOG_FILE="$WORK_DIR/backup.log"

log() {
  printf '[rescue-backup] %s\n' "$*" | tee -a "$LOG_FILE"
}

warn() {
  printf '[rescue-backup] AVISO: %s\n' "$*" | tee -a "$LOG_FILE" >&2
}

run_optional() {
  description=$1
  shift

  log "$description"
  if ! "$@" >>"$LOG_FILE" 2>&1; then
    warn "falhou: $description"
    return 1
  fi
  return 0
}

copy_if_exists() {
  source_path=$1
  dest_path=$2

  if [ -e "$source_path" ]; then
    mkdir -p "$(dirname "$dest_path")"
    cp -a "$source_path" "$dest_path"
  else
    warn "nao encontrado: $source_path"
  fi
}

require_root_or_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "nao esta rodando como root; alguns arquivos protegidos podem ficar fora do backup"
  fi
}

prepare_dirs() {
  mkdir -p \
    "$WORK_DIR/database" \
    "$WORK_DIR/volumes" \
    "$WORK_DIR/app" \
    "$WORK_DIR/server-config" \
    "$WORK_DIR/diagnostics"
  chmod 700 "$BACKUP_OUTPUT_DIR" "$WORK_DIR"
  : > "$LOG_FILE"
}

load_env() {
  if [ -f "$CURRENT_DIR/.env" ]; then
    ENV_FILE="$CURRENT_DIR/.env"
  elif [ -f "$SHARED_DIR/.env" ]; then
    ENV_FILE="$SHARED_DIR/.env"
  else
    ENV_FILE=""
    warn "arquivo .env nao encontrado em $CURRENT_DIR nem $SHARED_DIR"
    return
  fi

  cp -a "$ENV_FILE" "$WORK_DIR/app/env.snapshot"
  chmod 600 "$WORK_DIR/app/env.snapshot"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

backup_database() {
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker nao encontrado; pulando backup do banco e volumes"
    return
  fi

  if [ -d "$CURRENT_DIR" ] && [ -f "$CURRENT_DIR/compose.yaml" ]; then
    (
      cd "$CURRENT_DIR"
      run_optional "subindo postgres para dump" docker compose up -d postgres
      if docker compose ps postgres >/dev/null 2>&1; then
        log "gerando dump do PostgreSQL"
        if docker compose exec -T postgres pg_dump \
          -U "${POSTGRES_USER:-semed_user}" \
          -d "${POSTGRES_DB:-semed_site}" \
          --format=custom > "$WORK_DIR/database/database.dump" 2>>"$LOG_FILE"; then
          chmod 600 "$WORK_DIR/database/database.dump"
        else
          warn "falha ao gerar database.dump via docker compose"
        fi
      fi
    )
  else
    warn "compose.yaml nao encontrado em $CURRENT_DIR; pulando pg_dump"
  fi
}

backup_named_volume() {
  volume_name=$1
  output_name=$2

  if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
    warn "volume Docker nao encontrado: $volume_name"
    return
  fi

  log "empacotando volume $volume_name"
  if docker run --rm -v "$volume_name:/data:ro" alpine:3.20 \
    tar -czf - -C /data . > "$WORK_DIR/volumes/$output_name.tar.gz" 2>>"$LOG_FILE"; then
    chmod 600 "$WORK_DIR/volumes/$output_name.tar.gz"
  else
    warn "falha ao empacotar volume $volume_name"
  fi
}

backup_volumes() {
  if ! command -v docker >/dev/null 2>&1; then
    return
  fi

  backup_named_volume semed_uploads uploads
  backup_named_volume semed_documents documents
  backup_named_volume semed_postgres_data postgres-data-raw
  backup_named_volume semed_caddy_data caddy-data
  backup_named_volume semed_caddy_config caddy-config
}

backup_app_files() {
  if [ -d "$CURRENT_DIR" ]; then
    mkdir -p "$WORK_DIR/app/current"
    tar -cf - -C "$CURRENT_DIR" . | tar -xf - -C "$WORK_DIR/app/current"
  else
    warn "diretorio atual nao encontrado: $CURRENT_DIR"
  fi

  copy_if_exists "$SHARED_DIR/.env" "$WORK_DIR/app/shared.env"

  if [ -d "$APP_ROOT/releases" ]; then
    mkdir -p "$WORK_DIR/app/releases-list"
    ls -la "$APP_ROOT/releases" > "$WORK_DIR/app/releases-list/ls-la.txt" 2>&1 || true
    latest_release=$(ls -1dt "$APP_ROOT"/releases/* 2>/dev/null | head -n 1 || true)
    if [ -n "$latest_release" ]; then
      copy_if_exists "$latest_release" "$WORK_DIR/app/latest-release"
    fi
  fi
}

backup_server_config() {
  copy_if_exists /etc/ssh "$WORK_DIR/server-config/etc-ssh"
  copy_if_exists /etc/fail2ban "$WORK_DIR/server-config/etc-fail2ban"
  copy_if_exists /etc/ufw "$WORK_DIR/server-config/etc-ufw"
  copy_if_exists /etc/caddy "$WORK_DIR/server-config/etc-caddy"
  copy_if_exists /etc/docker "$WORK_DIR/server-config/etc-docker"
  copy_if_exists /etc/systemd/system "$WORK_DIR/server-config/systemd-system"
  copy_if_exists /root/.ssh "$WORK_DIR/server-config/root-ssh"
}

write_diagnostics() {
  {
    echo "date: $(date -Is 2>/dev/null || date)"
    echo "hostname: $(hostname 2>/dev/null || true)"
    echo "kernel: $(uname -a 2>/dev/null || true)"
    echo "app_root: $APP_ROOT"
    echo "current_dir: $CURRENT_DIR"
    echo "shared_dir: $SHARED_DIR"
  } > "$WORK_DIR/diagnostics/summary.txt"

  ip addr > "$WORK_DIR/diagnostics/ip-addr.txt" 2>&1 || true
  ss -ltnp > "$WORK_DIR/diagnostics/listening-ports.txt" 2>&1 || true
  df -h > "$WORK_DIR/diagnostics/df-h.txt" 2>&1 || true
  free -h > "$WORK_DIR/diagnostics/free-h.txt" 2>&1 || true
  ps auxww > "$WORK_DIR/diagnostics/processes.txt" 2>&1 || true

  if command -v docker >/dev/null 2>&1; then
    docker ps -a > "$WORK_DIR/diagnostics/docker-ps-a.txt" 2>&1 || true
    docker images > "$WORK_DIR/diagnostics/docker-images.txt" 2>&1 || true
    docker volume ls > "$WORK_DIR/diagnostics/docker-volume-ls.txt" 2>&1 || true
  fi

  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose > "$WORK_DIR/diagnostics/ufw-status.txt" 2>&1 || true
  fi

  if command -v fail2ban-client >/dev/null 2>&1; then
    fail2ban-client status > "$WORK_DIR/diagnostics/fail2ban-status.txt" 2>&1 || true
  fi

  if [ -d "$CURRENT_DIR" ] && [ -f "$CURRENT_DIR/compose.yaml" ] && command -v docker >/dev/null 2>&1; then
    (cd "$CURRENT_DIR" && docker compose ps > "$WORK_DIR/diagnostics/docker-compose-ps.txt" 2>&1) || true
    (cd "$CURRENT_DIR" && docker compose logs --no-color --tail=300 > "$WORK_DIR/diagnostics/docker-compose-logs-tail.txt" 2>&1) || true
  fi
}

write_manifest() {
  {
    echo "SEMED rescue backup"
    echo "created_at=$STAMP"
    echo "archive=$ARCHIVE"
    echo
    echo "Main restore assets:"
    echo "- database/database.dump: pg_restore custom dump"
    echo "- volumes/uploads.tar.gz: uploaded media"
    echo "- volumes/documents.tar.gz: documents volume"
    echo "- app/current: current deployed release"
    echo "- app/env.snapshot and app/shared.env: production environment/secrets"
    echo "- server-config: SSH/firewall/Caddy/Docker/systemd configs"
    echo "- diagnostics: server state at backup time"
    echo
    echo "Warning: this archive contains secrets. Store it offline and do not share it publicly."
  } > "$WORK_DIR/MANIFEST.txt"
}

create_archive() {
  log "criando arquivo final: $ARCHIVE"
  tar -czf "$ARCHIVE" -C "$BACKUP_OUTPUT_DIR" "$(basename "$WORK_DIR")"
  chmod 600 "$ARCHIVE"
  sha256sum "$ARCHIVE" > "$ARCHIVE.sha256" 2>/dev/null || true
}

cleanup_work_dir() {
  if [ -d "$WORK_DIR" ] && [ -f "$ARCHIVE" ]; then
    rm -rf -- "$WORK_DIR"
  fi
}

main() {
  require_root_or_sudo
  prepare_dirs
  log "iniciando backup completo de resgate"

  load_env
  backup_database
  backup_volumes
  backup_app_files
  backup_server_config
  write_diagnostics
  write_manifest
  create_archive
  cleanup_work_dir

  log "backup completo criado:"
  log "$ARCHIVE"
  if [ -f "$ARCHIVE.sha256" ]; then
    log "checksum:"
    cat "$ARCHIVE.sha256"
  fi
  log "copie este arquivo para fora da VPS antes de reinstalar."
}

main "$@"
