#!/usr/bin/env bash
# Recuperação e resiliência da VPS SEMED.
#
# Uso no console da VPS:
#   sudo bash recover-vps-services.sh \
#     --compose /opt/semed-site/releases/20261020-125613/compose.yaml \
#     --domain semed.varzeadapalma.mg.gov.br
#
# O script NÃO executa docker system prune, docker volume rm, docker compose
# down -v ou qualquer ação que remova volumes. Os dados de PostgreSQL, MariaDB,
# uploads, certificados e documentos são preservados.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

DEFAULT_DOMAIN="semed.varzeadapalma.mg.gov.br"
DEFAULT_COMPOSE="/opt/semed-site/releases/20261020-125613/compose.yaml"

DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
STACK_COMPOSE="${STACK_COMPOSE:-$DEFAULT_COMPOSE}"
INSTALL_RESILIENCE=true
LOG_DIR="/var/log/semed-recovery"
BACKUP_DIR="/root/semed-recovery-backups"

usage() {
  cat <<'EOF'
Uso:
  sudo bash recover-vps-services.sh [opções]

Opções:
  --compose ARQUIVO  Caminho absoluto ao compose.yaml ativo.
  --domain DOMÍNIO   Domínio público do portal.
  --no-resilience    Não instala o serviço de boot e o watchdog systemd.
  -h, --help         Mostra esta ajuda.

O arquivo Compose é informado explicitamente para nunca selecionar por engano
arquivos como compose.payload.yaml ou uma release antiga.
EOF
}

log() {
  printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

warn() {
  printf '\n\033[1;33mAVISO: %s\033[0m\n' "$*" >&2
}

fail() {
  printf '\n\033[1;31mERRO: %s\033[0m\n' "$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"

while (($#)); do
  case "$1" in
    --compose)
      [[ $# -ge 2 ]] || fail "--compose requer um caminho"
      STACK_COMPOSE="$2"
      shift 2
      ;;
    --domain)
      [[ $# -ge 2 ]] || fail "--domain requer um domínio"
      DOMAIN="$2"
      shift 2
      ;;
    --no-resilience)
      INSTALL_RESILIENCE=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Opção desconhecida: $1"
      ;;
  esac
done

[[ "$STACK_COMPOSE" = /* ]] || fail "--compose deve ser um caminho absoluto"
[[ -f "$STACK_COMPOSE" ]] || fail "Arquivo Compose não encontrado: $STACK_COMPOSE"
[[ "$DOMAIN" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || fail "Domínio inválido: $DOMAIN"

COMPOSE_DIR="$(dirname "$STACK_COMPOSE")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

command -v docker >/dev/null 2>&1 || fail "Docker não está instalado"
command -v curl >/dev/null 2>&1 || fail "curl não está instalado"
command -v systemctl >/dev/null 2>&1 || fail "systemd não está disponível"
command -v ss >/dev/null 2>&1 || fail "comando ss não está disponível"

# IMPORTANTE: não use o nome COMPOSE_FILE nesta variável. Ele pode estar
# definido no ambiente e apontar para compose.payload.yaml.
compose() {
  env \
    -u COMPOSE_FILE \
    -u COMPOSE_PROJECT_NAME \
    -u COMPOSE_PROFILES \
    docker compose \
      --project-directory "$COMPOSE_DIR" \
      -f "$STACK_COMPOSE" \
      "$@"
}

caddy_id() {
  compose ps -q caddy 2>/dev/null | head -n 1 || true
}

show_diagnostics() {
  local id
  id="$(caddy_id)"
  printf '\n========== Diagnóstico de recuperação ==========\n' >&2
  systemctl status ssh docker nginx --no-pager -n 30 2>&1 || true
  docker ps -a 2>&1 || true
  ss -ltnp 2>&1 || true
  if [[ -n "$id" ]]; then
    docker logs --tail 120 "$id" 2>&1 || true
  fi
  printf 'Log: %s/recover-%s.log\n' "$LOG_DIR" "$TIMESTAMP" >&2
}

mkdir -p -m 0750 "$LOG_DIR" "$BACKUP_DIR"
exec > >(tee -a "$LOG_DIR/recover-$TIMESTAMP.log") 2>&1
trap show_diagnostics ERR

log "Validando a pilha SEMED"
cd "$COMPOSE_DIR"
compose config --quiet
compose config --services | grep -qx 'caddy' || fail "O compose informado não possui o serviço caddy"

log "Preservando diagnóstico do proxy atual"
docker inspect semed-caddy > "$BACKUP_DIR/semed-caddy-$TIMESTAMP.json" 2>/dev/null || true

log "Restaurando SSH e liberando portas públicas"
systemctl unmask ssh 2>/dev/null || true
systemctl enable --now ssh
systemctl restart ssh

# Não habilita um UFW que esteja inativo: ligar um firewall novo pode bloquear
# regras específicas do provedor. Se estiver ativo, garante SSH, HTTP e HTTPS.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi '^Status: active'; then
  ufw allow 22/tcp comment 'SEMED SSH' || true
  ufw allow 80/tcp comment 'SEMED HTTP' || true
  ufw allow 443/tcp comment 'SEMED HTTPS' || true
  ufw allow 443/udp comment 'SEMED HTTP3' || true
  ufw reload || true
else
  warn "UFW inativo ou ausente; confirme no provedor que 22/TCP, 80/TCP e 443/TCP estão liberadas"
fi

log "Removendo conflito confirmado de proxy"
# O Nginx do host já conflitou com o Caddy Docker. Não apaga seus arquivos,
# mas impede que ele retome 80/443 no próximo boot.
if systemctl list-unit-files nginx.service --no-legend 2>/dev/null | grep -q '^nginx.service'; then
  systemctl disable --now nginx || true
  systemctl mask nginx || true
fi

log "Habilitando Docker e recuperação de containers após reboot"
systemctl unmask docker 2>/dev/null || true
systemctl enable --now docker

# Garante que os containers que já estão em execução sejam reiniciados após
# queda de energia/reboot. Não inicia containers históricos que já estavam
# parados e não altera ou remove volumes.
mapfile -t RUNNING_CONTAINERS < <(docker ps -q)
if ((${#RUNNING_CONTAINERS[@]})); then
  docker update --restart unless-stopped "${RUNNING_CONTAINERS[@]}"
fi

# live-restore mantém containers em execução durante reinícios do daemon Docker
# quando o kernel e a rede ainda estiverem saudáveis. O arquivo é validado e
# copiado antes de ser alterado.
if command -v jq >/dev/null 2>&1; then
  mkdir -p /etc/docker
  if [[ -f /etc/docker/daemon.json ]]; then
    jq -e . /etc/docker/daemon.json >/dev/null || fail "/etc/docker/daemon.json contém JSON inválido"
    cp -a /etc/docker/daemon.json "$BACKUP_DIR/daemon.json-$TIMESTAMP"
    tmp_daemon="$(mktemp)"
    jq '. + {"live-restore": true}' /etc/docker/daemon.json > "$tmp_daemon"
    install -m 0644 "$tmp_daemon" /etc/docker/daemon.json
    rm -f "$tmp_daemon"
  else
    cat > /etc/docker/daemon.json <<'EOF'
{
  "live-restore": true
}
EOF
  fi
else
  warn "jq não encontrado; live-restore não foi alterado para não corromper daemon.json"
fi

log "Reiniciando Docker e recuperando a pilha SEMED"
systemctl restart docker

# Remove APENAS o proxy SEMED caso uma versão inválida tenha ficado reservando
# o nome. Os volumes caddy_data e caddy_config continuam preservados.
docker rm -f semed-caddy >/dev/null 2>&1 || true

# Não usa down, -v, prune nem remove-orphans. Os bancos e uploads persistem.
compose up -d --no-build

log "Verificando Caddy, portas e saúde local"
CADDY_ID=""
for attempt in {1..30}; do
  CADDY_ID="$(caddy_id)"
  if [[ -n "$CADDY_ID" ]] && \
     [[ "$(docker inspect --format '{{.State.Running}}' "$CADDY_ID" 2>/dev/null || true)" == "true" ]] && \
     ss -ltn | grep -qE ':(80)[[:space:]]' && \
     ss -ltn | grep -qE ':(443)[[:space:]]'; then
    break
  fi
  sleep 2
done

[[ -n "$CADDY_ID" ]] || fail "O Compose não criou o serviço caddy"
[[ "$(docker inspect --format '{{.State.Running}}' "$CADDY_ID")" == "true" ]] || fail "Caddy foi criado, mas não está em execução"

LOCAL_HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H "Host: $DOMAIN" http://127.0.0.1/ || true)"
LOCAL_HTTPS="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 30 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" || true)"
API_HEALTH="$(curl -ksS --max-time 30 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/health" || true)"

echo "HTTP local:  $LOCAL_HTTP"
echo "HTTPS local: $LOCAL_HTTPS"
echo "API local:   $API_HEALTH"

case "$LOCAL_HTTP" in 200|301|302|307|308) ;; *) fail "HTTP local falhou: $LOCAL_HTTP" ;; esac
[[ "$LOCAL_HTTPS" == "200" ]] || fail "HTTPS local falhou: $LOCAL_HTTPS"
[[ "$API_HEALTH" == *'"status":"ok"'* ]] || fail "API não retornou status OK"

install_resilience() {
  log "Instalando recuperação automática após reboot"
  install -d -m 0750 /etc/semed-recovery
  {
    printf 'COMPOSE_DIR=%q\n' "$COMPOSE_DIR"
    printf 'STACK_COMPOSE=%q\n' "$STACK_COMPOSE"
    printf 'DOMAIN=%q\n' "$DOMAIN"
  } > /etc/semed-recovery/stack.env
  chmod 0600 /etc/semed-recovery/stack.env

  cat > /usr/local/sbin/semed-stack-recover <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/semed-recovery/stack.env

compose() {
  env -u COMPOSE_FILE -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES \
    docker compose --project-directory "$COMPOSE_DIR" -f "$STACK_COMPOSE" "$@"
}

[[ -f "$STACK_COMPOSE" ]]
compose config --quiet
compose up -d --no-build
EOF
  chmod 0750 /usr/local/sbin/semed-stack-recover

  cat > /usr/local/sbin/semed-stack-watchdog <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/semed-recovery/stack.env

compose() {
  env -u COMPOSE_FILE -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES \
    docker compose --project-directory "$COMPOSE_DIR" -f "$STACK_COMPOSE" "$@"
}

if ! systemctl is-active --quiet docker; then
  systemctl restart docker
  sleep 5
fi

caddy_id="$(compose ps -q caddy 2>/dev/null | head -n 1 || true)"
running=false
if [[ -n "$caddy_id" ]]; then
  running="$(docker inspect --format '{{.State.Running}}' "$caddy_id" 2>/dev/null || true)"
fi

if [[ "$running" != true ]]; then
  compose up -d --no-build caddy
  sleep 5
fi

# O teste é local e usa SNI correto. Portanto, uma falha da operadora não
# provoca loops de reinicialização apenas porque o DNS/Internet está offline.
if ! curl -ksSf --max-time 20 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/health" >/dev/null; then
  compose up -d --no-build --force-recreate caddy
  sleep 8
  curl -ksSf --max-time 20 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/health" >/dev/null
fi
EOF
  chmod 0750 /usr/local/sbin/semed-stack-watchdog

  cat > /etc/systemd/system/semed-stack-recover.service <<'EOF'
[Unit]
Description=Recupera a pilha Docker da SEMED após boot
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/semed-stack-recover
RemainAfterExit=yes
Restart=on-failure
RestartSec=20
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/semed-stack-watchdog.service <<'EOF'
[Unit]
Description=Verifica e recupera localmente o portal SEMED
After=docker.service semed-stack-recover.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/semed-stack-watchdog
TimeoutStartSec=120
EOF

  cat > /etc/systemd/system/semed-stack-watchdog.timer <<'EOF'
[Unit]
Description=Timer de saúde local do portal SEMED

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
RandomizedDelaySec=20s
Persistent=true
Unit=semed-stack-watchdog.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable semed-stack-recover.service
  systemctl enable --now semed-stack-watchdog.timer
  systemctl restart semed-stack-recover.service
  systemctl start semed-stack-watchdog.service
}

if [[ "$INSTALL_RESILIENCE" == true ]]; then
  install_resilience
fi

log "Recuperação concluída"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo
echo "Site local validado em HTTPS: https://$DOMAIN"
echo "Log de recuperação: $LOG_DIR/recover-$TIMESTAMP.log"
echo
echo "Limites externos: uma queda física de energia ou da operadora só é coberta"
echo "com UPS, boot automático no painel/BIOS do provedor e monitoramento externo."
