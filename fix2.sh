#!/usr/bin/env bash
# recupera-semed.sh
# Execute no console da VPS:
#   sudo bash recupera-semed.sh

set -Eeuo pipefail

DOMAIN="semed.varzeadapalma.mg.gov.br"
COMPOSE_DIR="/opt/semed-site/releases/20261020-125613"
STACK_COMPOSE="$COMPOSE_DIR/compose.yaml"
CADDY_NAME="semed-caddy"

log() {
  printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

fail() {
  printf '\n\033[1;31mERRO: %s\033[0m\n' "$*" >&2
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

[[ -f "$STACK_COMPOSE" ]] ||
  fail "Arquivo Compose obrigatório não encontrado: $STACK_COMPOSE"

command -v docker >/dev/null 2>&1 || fail "Docker não está instalado."
command -v curl >/dev/null 2>&1 || fail "curl não está instalado."
command -v ss >/dev/null 2>&1 || fail "ss não está instalado."

# Sempre ignora variáveis antigas que possam apontar para compose.payload.yaml.
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

show_caddy_logs() {
  echo
  echo "----- Últimos logs do Caddy -----"
  docker logs --tail 100 "$CADDY_NAME" 2>&1 || true
  echo "---------------------------------"
}

trap show_caddy_logs ERR

log "1/8 — Validando arquivo Compose"
cd "$COMPOSE_DIR"
compose config --quiet
echo "Compose válido: $STACK_COMPOSE"

log "2/8 — Restaurando SSH e liberando firewall"
systemctl enable --now ssh
systemctl restart ssh

if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
fi

log "3/8 — Desabilitando Nginx do host"
# O Caddy Docker é quem deve publicar as portas 80 e 443.
systemctl disable --now nginx 2>/dev/null || true

log "4/8 — Reiniciando Docker"
systemctl enable docker
systemctl restart docker
sleep 5

log "5/8 — Removendo Caddy antigo ou inválido"
# Remove somente o container. Certificados e dados nos volumes Docker são mantidos.
docker rm -f "$CADDY_NAME" >/dev/null 2>&1 || true

log "6/8 — Recriando serviços da SEMED"
# Sem --remove-orphans: não interfere nos demais sistemas hospedados na VPS.
timeout 180 compose up -d --force-recreate

log "7/8 — Conferindo containers e portas"
sleep 8

docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo

ss -ltnp | grep -E ':(22|80|443)[[:space:]]' ||
  fail "SSH, HTTP e HTTPS não estão escutando como esperado."

docker inspect "$CADDY_NAME" >/dev/null 2>&1 ||
  fail "Container $CADDY_NAME não foi criado."

[[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_NAME")" == "true" ]] ||
  fail "Container $CADDY_NAME não está em execução."

log "8/8 — Testando site e API"

HTTP_CODE="$(
  curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 20 \
    -H "Host: $DOMAIN" \
    http://127.0.0.1/ || true
)"

HTTPS_CODE="$(
  curl -sS -L -o /dev/null -w '%{http_code}' \
    --max-time 30 \
    "https://$DOMAIN/" || true
)"

API_RESPONSE="$(
  curl -fsS --max-time 30 \
    "https://$DOMAIN/api/health" || true
)"

echo "HTTP local:  $HTTP_CODE"
echo "HTTPS site: $HTTPS_CODE"
echo "API:         $API_RESPONSE"

case "$HTTP_CODE" in
  200|301|302|307|308) ;;
  *) fail "HTTP local falhou com status $HTTP_CODE." ;;
esac

[[ "$HTTPS_CODE" == "200" ]] ||
  fail "HTTPS público falhou com status $HTTPS_CODE."

[[ "$API_RESPONSE" == *'"status":"ok"'* ]] ||
  fail "API não retornou status OK."

log "SITE RESTAURADO"
echo "Caddy está publicando o site em 80/443."
echo "Nginx do host está desabilitado."
