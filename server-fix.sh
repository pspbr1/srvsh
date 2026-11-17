#!/usr/bin/env bash
# diagnostico-semed.sh
# Uso:
#   sudo ./diagnostico-semed.sh
#   sudo ./diagnostico-semed.sh --fix
#
# Variáveis opcionais:
#   DOMAIN=semed.varzeadapalma.mg.gov.br sudo ./diagnostico-semed.sh --fix
#   COMPOSE_FILE=/opt/semed-site/releases/RELEASE/compose.yaml sudo ./diagnostico-semed.sh --fix

set -Eeuo pipefail

DOMAIN="${DOMAIN:-semed.varzeadapalma.mg.gov.br}"
RELEASES_DIR="${RELEASES_DIR:-/opt/semed-site/releases}"
FIX=false

[[ "${1:-}" == "--fix" ]] && FIX=true

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf '\nERRO: %s\n' "$*" >&2
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

command -v docker >/dev/null 2>&1 || fail "Docker não está instalado."
command -v curl >/dev/null 2>&1 || fail "curl não está instalado."
command -v ss >/dev/null 2>&1 || fail "ss não está instalado."

# Permite informar COMPOSE_FILE manualmente; caso contrário, usa o compose
# mais recente nas releases. Não depende de compose.payload.yaml.
if [[ -z "${COMPOSE_FILE:-}" ]]; then
  COMPOSE_FILE="$(
    find "$RELEASES_DIR" \
      -maxdepth 2 \
      -type f \
      \( -name "compose.yaml" -o -name "compose.yml" -o -name "docker-compose.yml" -o -name "docker-compose.yaml" \) \
      -printf '%T@ %p\n' 2>/dev/null |
      sort -nr |
      head -n 1 |
      cut -d' ' -f2-
  )"
fi

[[ -n "${COMPOSE_FILE:-}" ]] ||
  fail "Nenhum arquivo Docker Compose encontrado em: $RELEASES_DIR"

[[ -f "$COMPOSE_FILE" ]] ||
  fail "Arquivo Compose não encontrado: $COMPOSE_FILE"

COMPOSE_DIR="$(dirname "$COMPOSE_FILE")"

log "Configuração detectada"
echo "Domínio:          $DOMAIN"
echo "Arquivo Compose:  $COMPOSE_FILE"
echo "Diretório:        $COMPOSE_DIR"
echo "Modo de correção: $FIX"

log "Recursos da VPS"
uptime || true
df -h / || true
free -h || true

log "Serviço Nginx do host"
printf "Status: "
systemctl is-active nginx 2>/dev/null || true
printf "Inicialização: "
systemctl is-enabled nginx 2>/dev/null || true

log "Portas públicas"
ss -ltnp | grep -E ':(80|443)[[:space:]]' || echo "Nenhum processo escutando em 80/443."

log "Containers"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

log "Validação do Compose"
(
  cd "$COMPOSE_DIR"
  docker compose -f "$COMPOSE_FILE" config --quiet
)
echo "Compose válido."

log "Testes HTTP atuais"
echo "--- HTTP local ---"
curl -sSI --max-time 15 \
  -H "Host: $DOMAIN" \
  http://127.0.0.1/ || true

echo "--- HTTPS público ---"
curl -sSI --max-time 20 \
  "https://$DOMAIN/" || true

echo "--- Healthcheck da API ---"
curl -sS --max-time 20 \
  "https://$DOMAIN/api/health" || true
echo

if ! $FIX; then
  cat <<EOF

Diagnóstico concluído. Nenhuma alteração foi feita.

Para aplicar a correção automaticamente:

  sudo $0 --fix

EOF
  exit 0
fi

log "Aplicando correção"

# O Caddy Docker é o proxy público do site. O Nginx instalado no host
# não pode ocupar as portas 80/443.
if systemctl is-active --quiet nginx; then
  log "Parando e desabilitando o Nginx do host"
  systemctl disable --now nginx
else
  echo "Nginx do host já está inativo."
fi

# Remove somente semed-caddy se estiver parado, pois um container inválido
# e parado pode bloquear sua recriação pelo Docker Compose.
if docker inspect semed-caddy >/dev/null 2>&1; then
  CADDY_RUNNING="$(docker inspect --format '{{.State.Running}}' semed-caddy)"

  if [[ "$CADDY_RUNNING" != "true" ]]; then
    log "Removendo container semed-caddy parado"
    docker rm semed-caddy
  fi
fi

log "Recriando o proxy Caddy"
(
  cd "$COMPOSE_DIR"
  docker compose -f "$COMPOSE_FILE" config --quiet
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate caddy
)

log "Aguardando inicialização"
sleep 8

log "Validação final"

docker ps --filter "name=^/semed-caddy$" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

docker inspect semed-caddy >/dev/null 2>&1 ||
  fail "O container semed-caddy não foi criado."

CADDY_RUNNING="$(docker inspect --format '{{.State.Running}}' semed-caddy)"
[[ "$CADDY_RUNNING" == "true" ]] ||
  fail "O container semed-caddy não está em execução."

ss -ltnp | grep -qE ':(80)[[:space:]]' ||
  fail "Nenhum serviço está escutando na porta 80."

ss -ltnp | grep -qE ':(443)[[:space:]]' ||
  fail "Nenhum serviço está escutando na porta 443."

HTTP_STATUS="$(
  curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 20 \
    -H "Host: $DOMAIN" \
    http://127.0.0.1/ || true
)"

case "$HTTP_STATUS" in
  200|301|302|307|308)
    echo "HTTP local: OK ($HTTP_STATUS)"
    ;;
  *)
    fail "HTTP local falhou (status: $HTTP_STATUS)."
    ;;
esac

HTTPS_STATUS="$(
  curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 25 \
    "https://$DOMAIN/" || true
)"

[[ "$HTTPS_STATUS" == "200" ]] ||
  fail "Site HTTPS falhou (status: $HTTPS_STATUS)."

API_RESPONSE="$(
  curl -fsS --max-time 25 \
    "https://$DOMAIN/api/health"
)" || fail "Healthcheck público da API falhou."

echo "Site HTTPS: OK ($HTTPS_STATUS)"
echo "API: $API_RESPONSE"

log "Correção concluída"
echo "Caddy está ativo em 80/443; Nginx do host está desabilitado."
