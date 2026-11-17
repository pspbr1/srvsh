#!/usr/bin/env bash
# recupera-semed.sh
# Execute no console da VPS:
#   sudo bash recupera-semed.sh

set -Eeuo pipefail

DOMAIN="semed.varzeadapalma.mg.gov.br"
COMPOSE_DIR="/opt/semed-site/releases/20261020-125613"
STACK_COMPOSE="$COMPOSE_DIR/compose.yaml"
CADDY_NAME="semed-caddy"
SSH_PORT="22"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-semed-hardening.conf"
F2B_JAIL="/etc/fail2ban/jail.d/semed-sshd.local"

WARNINGS=0

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '  \033[1;33m[ATENÇÃO]\033[0m %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
fail() { printf '\n\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

[[ -f "$STACK_COMPOSE" ]] || fail "Arquivo Compose não encontrado: $STACK_COMPOSE"
for c in docker curl ss; do
  command -v "$c" >/dev/null 2>&1 || fail "$c não está instalado."
done

# Ignora variáveis antigas que possam apontar para outro compose.
compose() {
  env -u COMPOSE_FILE -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES \
    docker compose --project-directory "$COMPOSE_DIR" -f "$STACK_COMPOSE" "$@"
}

show_caddy_logs() {
  echo
  echo "----- Últimos logs do Caddy -----"
  docker logs --tail 100 "$CADDY_NAME" 2>&1 || true
  echo "---------------------------------"
}
trap show_caddy_logs ERR

###############################################################################
log "1/10 — Validando arquivo Compose"
cd "$COMPOSE_DIR"
compose config --quiet
ok "Compose válido: $STACK_COMPOSE"

###############################################################################
log "2/10 — Instalando pacotes de segurança (ufw, fail2ban, openssh-server)"
export DEBIAN_FRONTEND=noninteractive
MISSING=()
command -v ufw >/dev/null 2>&1 || MISSING+=(ufw)
command -v fail2ban-client >/dev/null 2>&1 || MISSING+=(fail2ban)
command -v sshd >/dev/null 2>&1 || MISSING+=(openssh-server)
if ((${#MISSING[@]})); then
  apt-get update -qq
  apt-get install -y -qq "${MISSING[@]}"
fi
ok "Pacotes presentes"

###############################################################################
log "3/10 — Reabrindo SSH (com configuração segura)"
# Só desativa senha se existir ao menos uma chave autorizada, para não
# trancar você para fora da VPS.
HAS_KEY=0
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  [[ -s "$f" ]] && HAS_KEY=1 && break
done

mkdir -p /etc/ssh/sshd_config.d
{
  echo "# Gerado por recupera-semed.sh"
  echo "Port $SSH_PORT"
  echo "PermitEmptyPasswords no"
  echo "MaxAuthTries 4"
  echo "LoginGraceTime 30"
  echo "X11Forwarding no"
  if ((HAS_KEY)); then
    echo "PasswordAuthentication no"
    echo "PermitRootLogin prohibit-password"
  else
    echo "PasswordAuthentication yes"
    echo "PermitRootLogin yes"
  fi
} > "$SSHD_DROPIN"

if ! sshd -t; then
  rm -f "$SSHD_DROPIN"
  fail "Configuração do sshd inválida; drop-in removido."
fi

systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd
systemctl restart ssh 2>/dev/null || systemctl restart sshd

if ((HAS_KEY)); then
  ok "SSH ativo: apenas chave pública (senha desativada)"
else
  warn "Nenhuma chave SSH autorizada encontrada: login por SENHA ficou habilitado. Instale uma chave (ssh-copy-id) e rode o script de novo para desativar a senha."
fi

###############################################################################
log "4/10 — Configurando firewall (UFW)"
ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null
# 'limit' já bloqueia IPs com muitas tentativas de conexão em 30s.
ufw limit "${SSH_PORT}/tcp" >/dev/null
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
systemctl enable ufw >/dev/null 2>&1 || true
ok "UFW ativo: entrada negada por padrão; liberadas ${SSH_PORT} (com limite), 80 e 443"

###############################################################################
log "5/10 — Configurando fail2ban para SSH"
mkdir -p /etc/fail2ban/jail.d
cat > "$F2B_JAIL" <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd
maxretry = 4
findtime = 10m
bantime  = 1h
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w
banaction = ufw
EOF

fail2ban-client -t >/dev/null || { rm -f "$F2B_JAIL"; fail "Configuração do fail2ban inválida; jail removido."; }
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 3
ok "fail2ban reiniciado com jail sshd"

###############################################################################
log "6/10 — Desabilitando Nginx do host"
systemctl disable --now nginx 2>/dev/null || true
ok "Nginx do host desabilitado (o Caddy em Docker publica 80/443)"

###############################################################################
log "7/10 — Reiniciando Docker"
# Atenção: reiniciar o Docker derruba brevemente todos os containers da VPS
# (incluindo o Siscert). Eles voltam sozinhos se tiverem restart policy.
systemctl enable docker >/dev/null 2>&1
systemctl restart docker
sleep 5

###############################################################################
log "8/10 — Recriando serviços da SEMED"
# Remove só o container do Caddy; volumes (certificados) são mantidos.
docker rm -f "$CADDY_NAME" >/dev/null 2>&1 || true
# Sem --remove-orphans: não interfere nos demais sistemas da VPS.
timeout 180 compose up -d --force-recreate
sleep 8

docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo
ss -ltnp | grep -E ":(${SSH_PORT}|80|443)[[:space:]]" \
  || fail "SSH, HTTP e HTTPS não estão escutando como esperado."

docker inspect "$CADDY_NAME" >/dev/null 2>&1 || fail "Container $CADDY_NAME não foi criado."
[[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_NAME")" == "true" ]] \
  || fail "Container $CADDY_NAME não está em execução."

# Containers que deveriam estar de pé mas pararam (ex.: Siscert na rede semed_web).
STOPPED="$(docker ps -a --filter status=exited --filter status=created --format '{{.Names}}' || true)"
if [[ -n "$STOPPED" ]]; then
  warn "Containers parados (confira se algum deveria estar rodando, ex.: Siscert):"
  echo "$STOPPED" | sed 's/^/           - /'
fi

###############################################################################
log "9/10 — Testando site e API"
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
  -H "Host: $DOMAIN" http://127.0.0.1/ || true)"
HTTPS_CODE="$(curl -sS -L -o /dev/null -w '%{http_code}' --max-time 30 \
  "https://$DOMAIN/" || true)"
API_RESPONSE="$(curl -fsS --max-time 30 "https://$DOMAIN/api/health" || true)"

echo "  HTTP local:  $HTTP_CODE"
echo "  HTTPS site:  $HTTPS_CODE"
echo "  API:         $API_RESPONSE"

case "$HTTP_CODE" in
  200|301|302|307|308) ;;
  *) fail "HTTP local falhou com status $HTTP_CODE." ;;
esac
[[ "$HTTPS_CODE" == "200" ]] || fail "HTTPS público falhou com status $HTTPS_CODE."
[[ "$API_RESPONSE" == *'"status":"ok"'* ]] || fail "API não retornou status OK."
ok "Site e API respondendo"

###############################################################################
log "10/10 — Auditoria de segurança"

# SSH
if sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'; then
  ok "SSH: autenticação por senha desativada"
else
  warn "SSH: autenticação por senha está ATIVA"
fi
if sshd -T 2>/dev/null | grep -qiE '^permitrootlogin (no|prohibit-password|without-password)'; then
  ok "SSH: root não entra com senha"
else
  warn "SSH: root pode entrar com senha"
fi

# UFW
if ufw status | grep -q '^Status: active'; then
  ok "UFW: ativo"
else
  warn "UFW: INATIVO"
fi
ufw status verbose | grep -qi 'deny (incoming)' \
  && ok "UFW: política padrão nega entrada" \
  || warn "UFW: política padrão de entrada não é 'deny'"
systemctl is-enabled --quiet ufw && ok "UFW: inicia no boot" || warn "UFW: não inicia no boot"

# fail2ban
systemctl is-active --quiet fail2ban && ok "fail2ban: ativo" || warn "fail2ban: INATIVO"
systemctl is-enabled --quiet fail2ban && ok "fail2ban: inicia no boot" || warn "fail2ban: não inicia no boot"
if fail2ban-client status sshd >/dev/null 2>&1; then
  ok "fail2ban: jail sshd em execução"
  fail2ban-client status sshd | sed 's/^/           /'
else
  warn "fail2ban: jail sshd NÃO está ativo"
fi

# Portas expostas
echo
echo "  Portas escutando em todas as interfaces:"
ss -ltnH | awk '$4 ~ /^(0\.0\.0\.0|\[::\]|\*):/ {print "           " $4}' | sort -u
EXTRA="$(ss -ltnH | awk '$4 ~ /^(0\.0\.0\.0|\[::\]|\*):/ {n=split($4,a,":"); print a[n]}' \
  | sort -un | grep -vxE "${SSH_PORT}|80|443" || true)"
if [[ -n "$EXTRA" ]]; then
  warn "Portas extras escutando (confira se estão bloqueadas pelo UFW): $(echo "$EXTRA" | tr '\n' ' ')"
  echo "           Lembrete: portas publicadas pelo Docker (-p / ports:) podem IGNORAR o UFW."
fi

echo
if ((WARNINGS == 0)); then
  log "SITE RESTAURADO E SERVIDOR PROTEGIDO"
else
  log "SITE RESTAURADO, MAS HÁ $WARNINGS ITEM(NS) DE ATENÇÃO ACIMA"
fi
echo "Caddy publica o site em 80/443. Nginx do host está desabilitado."
echo "ANTES de fechar este console: abra um NOVO terminal e teste o login por SSH."
