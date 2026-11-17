#!/usr/bin/env bash
# recuperacao-total-semed.sh
#
# Execute no console da VPS:
#   sudo bash recuperacao-total-semed.sh
#
# NÃO executa "docker system prune", "docker volume rm",
# "docker compose down -v" ou qualquer comando que apague volumes.

set -Eeuo pipefail

DOMAIN="semed.varzeadapalma.mg.gov.br"
COMPOSE_DIR="/opt/semed-site/releases/20261020-125613"
STACK_COMPOSE="$COMPOSE_DIR/compose.yaml"
CADDY_NAME="semed-caddy"
LOG_FILE="/root/recuperacao-semed-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '\n\033[1;36m========== %s ==========\033[0m\n' "$*"
}

fail() {
  printf '\n\033[1;31mERRO: %s\033[0m\n' "$*" >&2
  exit 1
}

show_diagnostics() {
  echo
  echo "========== DIAGNÓSTICO DE FALHA =========="
  systemctl status docker ssh nginx --no-pager -n 20 2>&1 || true
  docker ps -a 2>&1 || true
  docker logs --tail 120 "$CADDY_NAME" 2>&1 || true
  ss -ltnp 2>&1 || true
  echo "Log salvo em: $LOG_FILE"
}

trap show_diagnostics ERR

if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

command -v docker >/dev/null 2>&1 || fail "Docker não está instalado."
command -v curl >/dev/null 2>&1 || fail "curl não está instalado."
command -v ss >/dev/null 2>&1 || fail "Comando ss não está disponível."
command -v timeout >/dev/null 2>&1 || fail "Comando timeout não está disponível."

[[ -f "$STACK_COMPOSE" ]] ||
  fail "Arquivo Compose não encontrado: $STACK_COMPOSE"

# Ignora variáveis de ambiente antigas, por exemplo COMPOSE_FILE apontando
# incorretamente para compose.payload.yaml.
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

log "1/10 — Validando a configuração SEMED"
cd "$COMPOSE_DIR"
compose config --quiet
echo "Compose validado: $STACK_COMPOSE"

log "2/10 — Restaurando acesso SSH"
systemctl unmask ssh 2>/dev/null || true
systemctl enable ssh
systemctl restart ssh

log "3/10 — Ajustando firewall"
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw reload || true
fi

log "4/10 — Eliminando conflito do Nginx do host"
# Nginx instalado no host não pode competir com o Caddy Docker em 80/443.
systemctl disable --now nginx 2>/dev/null || true
systemctl mask nginx 2>/dev/null || true

log "5/10 — Reiniciando Docker"
systemctl unmask docker 2>/dev/null || true
systemctl enable docker
systemctl restart docker
sleep 8

docker info >/dev/null ||
  fail "Docker não respondeu após a reinicialização."

log "6/10 — Inicializando containers hospedados que estejam parados"
mapfile -t STOPPED_CONTAINERS < <(
  {
    docker ps -aq --filter status=created
    docker ps -aq --filter status=exited
  } | sort -u
)

if ((${#STOPPED_CONTAINERS[@]})); then
  printf 'Iniciando containers: %s\n' "${STOPPED_CONTAINERS[*]}"
  docker start "${STOPPED_CONTAINERS[@]}" || true
else
  echo "Não há containers parados."
fi

log "7/10 — Removendo somente o proxy Caddy antigo"
# Remove apenas o container; volumes de certificados, bancos, uploads
# e documentos permanecem intactos.
docker rm -f "$CADDY_NAME" >/dev/null 2>&1 || true

log "8/10 — Recriando a pilha SEMED"
# Sem --remove-orphans e sem "-v": outros sistemas e todos os dados são mantidos.
timeout 240 compose up -d --force-recreate

log "9/10 — Aguardando Caddy assumir HTTP e HTTPS"
for attempt in {1..30}; do
  CADDY_RUNNING="$(
    docker inspect --format '{{.State.Running}}' "$CADDY_NAME" 2>/dev/null || true
  )"

  if [[ "$CADDY_RUNNING" == "true" ]] &&
     ss -ltnp | grep -qE ':(80)[[:space:]]' &&
     ss -ltnp | grep -qE ':(443)[[:space:]]'; then
    break
  fi

  echo "Aguardando proxy... tentativa $attempt/30"
  sleep 2
done

[[ "$(docker inspect --format '{{.State.Running}}' "$CADDY_NAME")" == "true" ]] ||
  fail "Caddy não iniciou."

ss -ltnp | grep -qE ':(80)[[:space:]]' ||
  fail "Nenhum serviço escuta a porta 80."

ss -ltnp | grep -qE ':(443)[[:space:]]' ||
  fail "Nenhum serviço escuta a porta 443."

log "10/10 — Testando site e API"

HTTP_CODE="$(
  curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 20 \
    -H "Host: $DOMAIN" \
    http://127.0.0.1/ || true
)"

HTTPS_CODE="$(
  curl -ksS -o /dev/null -w '%{http_code}' \
    --max-time 30 \
    --resolve "$DOMAIN:443:127.0.0.1" \
    "https://$DOMAIN/" || true
)"

API_RESPONSE="$(
  curl -ksS --max-time 30 \
    --resolve "$DOMAIN:443:127.0.0.1" \
    "https://$DOMAIN/api/health" || true
)"

echo "HTTP local:      $HTTP_CODE"
echo "HTTPS via Caddy: $HTTPS_CODE"
echo "API:             $API_RESPONSE"

case "$HTTP_CODE" in
  200|301|302|307|308) ;;
  *) fail "HTTP local retornou status inválido: $HTTP_CODE" ;;
esac

[[ "$HTTPS_CODE" == "200" ]] ||
  fail "HTTPS não retornou HTTP 200: $HTTPS_CODE"

[[ "$API_RESPONSE" == *'"status":"ok"'* ]] ||
  fail "API não retornou status OK."

log "RECUPERAÇÃO CONCLUÍDA"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo
echo "Site restaurado: https://$DOMAIN"
echo "Log completo: $LOG_FILE"
