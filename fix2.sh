#!/usr/bin/env bash
# recupera-semed.sh
# Execute: sudo bash recupera-semed.sh

set -Eeuo pipefail

DOMAIN="semed.varzeadapalma.mg.gov.br"
COMPOSE_DIR="/opt/semed-site/releases/20261020-125613"
COMPOSE_FILE="$COMPOSE_DIR/compose.yaml"
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

[[ -f "$COMPOSE_FILE" ]] ||
  fail "Arquivo obrigatório não encontrado: $COMPOSE_FILE"

command -v docker >/dev/null 2>&1 || fail "Docker não está instalado."
command -v curl >/dev/null 2>&1 || fail "curl não está instalado."

# Impede que uma variável antiga selecione outro arquivo Compose.
unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES

compose() {
  docker compose \
    --project-directory "$COMPOSE_DIR" \
    -f "$COMPOSE_FILE" \
    "$@"
}

trap 'echo; echo "Falha na recuperação. Logs do Caddy:"; docker logs --tail 80 "$CADDY_NAME" 2>&1 || true' ERR

log "1/8 — Validando configuração SEMED"
cd "$COMPOSE_DIR"
compose config --quiet

log "2/8 — Garantindo SSH e liberando firewall"
systemctl enable --now ssh
systemctl restart ssh

if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
fi

log "3/8 — Desabilitando Nginx do host"
# O Nginx do host conflita com o Caddy Docker nas portas 80/443.
systemctl disable --now nginx 2>/dev/null || true

log "4/8 — Reiniciando Docker"
systemctl enable docker
systemctl restart docker
sleep 5

log "5/8 — Removendo Caddy inválido/parado, se houver"
# Remove somente o container; volumes de certificados e dados são preservados.
docker rm -f "$CADDY_NAME" >/dev/null 2>&1 || true

log "6/8 — Recriando a pilha SEMED"
# Não use --remove-orphans: outros serviços da VPS não devem ser removidos.
timeout 180 compose up -d --force-recreate

log "7/8 — Conferindo serviços e portas"
sleep 8

docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo
ss -ltnp | grep -E ':(22|80|443)[[:space:]]' ||
  fail "Nenhum serviço está escutando em 22, 80 ou 443."

docker inspect "$CADDY_NAME" >/dev/null 2>&1 ||
  fail "O container $CADDY_NAME não foi criado."

[[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_NAME")" == "true" ]] ||
  fail "O Caddy não está em execução."

log "8/8 — Validando site e API"

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

[[ "$HTTPS_CODE" == "200" ]] ||
  fail "HTTPS ainda não respondeu HTTP 200."

[[ "$API_RESPONSE" == *'"status":"ok"'* ]] ||
  fail "A API não retornou status OK."

log "SITE RESTAURADO"
echo "Caddy está ativo; Nginx do host permanece desabilitado."
