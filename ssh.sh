#!/usr/bin/env bash
# =============================================================================
# ssh-recupera.sh — Diagnostica e recupera o acesso SSH em servidores Ubuntu
#
# Rode NO CONSOLE do servidor (teclado/monitor, KVM/IPMI, console web da VPS
# ou modo de recuperação), como root:
#
#   sudo bash ssh-recupera.sh              # diagnostica E corrige
#   sudo bash ssh-recupera.sh --dry-run    # só diagnostica, não altera nada
#
# Opções:
#   -n, --dry-run            apenas mostra o que seria feito
#   -p, --port N             força o sshd a escutar na porta N
#       --meu-ip IP          IP da sua máquina: desbanido e ignorado no fail2ban
#                            (pode repetir a opção)
#       --habilitar-senha    força PasswordAuthentication yes
#   -h, --help               esta ajuda
#
# Todo arquivo alterado é copiado antes para /root/ssh-recupera-backup-<data>/
# O relatório completo fica em /var/log/ssh-recupera-<data>.log
# =============================================================================
set -uo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

DRY=0; FORCE_PORT=""; FORCE_PW=0; MY_IPS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)       DRY=1 ;;
    -p|--port)          FORCE_PORT="${2:-}"; shift ;;
    --meu-ip)           MY_IPS+=("${2:-}"); shift ;;
    --habilitar-senha)  FORCE_PW=1 ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "Opção desconhecida: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if [[ -n $FORCE_PORT ]] && { ! [[ $FORCE_PORT =~ ^[0-9]+$ ]] || (( FORCE_PORT < 1 || FORCE_PORT > 65535 )); }; then
  echo "Porta inválida: $FORCE_PORT" >&2; exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "Execute como root: sudo bash $0" >&2; exit 1
fi

# ---------------------------------------------------------------- utilitários
TS=$(date +%Y%m%d-%H%M%S)
LOG="/var/log/ssh-recupera-$TS.log"
BK="/root/ssh-recupera-backup-$TS"
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi
mkdir -p "$BK"
exec > >(tee -a "$LOG") 2>&1

PROBLEMS=0; FIXES=0
step()  { echo; echo "${B}=== $* ===${N}"; }
info()  { echo "    $*"; }
ok()    { echo "${G}[ OK ]${N} $*"; }
warn()  { echo "${Y}[AVISO]${N} $*"; }
bad()   { echo "${R}[PROBLEMA]${N} $*"; PROBLEMS=$((PROBLEMS+1)); }
fixed() {
  if ((DRY)); then echo "${Y}[CORRIGIRIA]${N} $*"
  else echo "${G}[CORRIGIDO]${N} $*"; FIXES=$((FIXES+1)); fi
}
apply() { if ((DRY)); then echo "    [simulação] $*"; return 0; fi; "$@"; }
backup() {
  local f="$1"
  [[ -e $f ]] || return 0
  mkdir -p "$BK$(dirname "$f")"
  cp -a "$f" "$BK$f" 2>/dev/null || true
}
indent() { sed 's/^/    /'; }

echo "ssh-recupera.sh — $(date '+%F %T') — modo: $( ((DRY)) && echo SIMULAÇÃO || echo CORREÇÃO )"
echo "Log: $LOG | Backups: $BK"

# ============================================================ 1. SISTEMA
step "1. Sistema, disco e memória"
info "$(uptime)"
info "$(. /etc/os-release; echo "$PRETTY_NAME") | kernel $(uname -r)"

if touch /var/tmp/.ssh-rw-test 2>/dev/null; then
  rm -f /var/tmp/.ssh-rw-test
  ok "Sistema de arquivos gravável"
else
  bad "Sistema de arquivos em modo SOMENTE LEITURA (sshd e login falham assim)"
  dmesg 2>/dev/null | grep -iE 'I/O error|remount|ext4-fs|xfs' | tail -5 | indent
  if apply mount -o remount,rw /; then fixed "Tentei remontar / como leitura/escrita"; fi
  warn "Se voltar a ficar somente leitura, há erro de disco: rode fsck a partir de um modo de recuperação"
fi

use=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')
iuse=$(df -Pi / | awk 'NR==2{gsub("%","",$5); print $5}')
if [[ $use =~ ^[0-9]+$ ]] && (( use >= 95 )); then
  bad "Disco / com ${use}% de uso — sshd/login podem falhar sem espaço"
  du -xh /var --max-depth=2 2>/dev/null | sort -h | tail -8 | indent
  apply apt-get clean
  apply journalctl --vacuum-size=100M >/dev/null 2>&1
  fixed "Cache do apt e journal limpos (verifique o que mais ocupa espaço acima)"
else
  ok "Espaço em disco: ${use}% usado"
fi
if [[ $iuse =~ ^[0-9]+$ ]] && (( iuse >= 95 )); then
  bad "Inodes de / com ${iuse}% de uso — não dá para criar arquivos novos"
else
  ok "Inodes: ${iuse}% usado"
fi

free -m | indent
if dmesg 2>/dev/null | grep -qiE 'out of memory|killed process'; then
  warn "OOM killer já atuou neste boot (memória esgotada pode matar o sshd):"
  dmesg | grep -iE 'killed process' | tail -3 | indent
fi

if [[ -n "$(dpkg --audit 2>/dev/null)" ]]; then
  bad "Pacotes com instalação interrompida (dpkg)"
  apply dpkg --configure -a && fixed "dpkg --configure -a executado"
fi

# ============================================================ 2. PACOTE
step "2. Pacote openssh-server"
SSHD=$(command -v sshd || true); SSHD=${SSHD:-/usr/sbin/sshd}
if [[ -x $SSHD ]]; then
  ok "sshd encontrado em $SSHD ($("$SSHD" -V 2>&1 | head -1 | tr -d '\n'))"
else
  bad "openssh-server NÃO está instalado"
  apply apt-get update -qq
  if apply apt-get install -y openssh-server; then
    hash -r; SSHD=$(command -v sshd || echo /usr/sbin/sshd)
    fixed "openssh-server instalado"
  else
    warn "Falha ao instalar (sem rede?). Instale manualmente: apt-get install openssh-server"
  fi
fi
if [[ -e /etc/ssh/sshd_not_to_be_run ]]; then
  bad "/etc/ssh/sshd_not_to_be_run existe (impede o sshd de iniciar)"
  backup /etc/ssh/sshd_not_to_be_run
  apply rm -f /etc/ssh/sshd_not_to_be_run && fixed "Arquivo removido"
fi

# ============================================================ 3. CHAVES DE HOST
step "3. Chaves de host e diretórios do sshd"
if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  ok "Chaves de host presentes"
else
  bad "Sem chaves de host em /etc/ssh (o sshd não inicia)"
  apply ssh-keygen -A && fixed "Chaves de host geradas"
fi
for k in /etc/ssh/ssh_host_*_key; do
  [[ -f $k ]] || continue
  if [[ $(stat -c '%a %U' "$k") != "600 root" ]]; then
    bad "Permissão incorreta em $k ($(stat -c '%a %U' "$k"))"
    apply chown root:root "$k"; apply chmod 600 "$k"; fixed "$k → 600 root"
  fi
done
for k in /etc/ssh/ssh_host_*_key.pub; do
  [[ -f $k ]] && apply chmod 644 "$k"
done
if [[ ! -d /run/sshd ]]; then
  warn "/run/sshd não existe (diretório de separação de privilégio)"
  apply install -d -m 755 /run/sshd && fixed "/run/sshd criado"
fi

# ============================================================ 4. CONFIG
step "4. Validade da configuração do sshd"
CFG=/etc/ssh/sshd_config

write_minimal_config() {
  cat > "$CFG" <<'EOF'
# Configuração mínima gerada por ssh-recupera.sh
Include /etc/ssh/sshd_config.d/*.conf
Port 22
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
}

repair_config() {
  local f
  if ((DRY)); then
    info "[simulação] desativaria drop-ins um a um e, se preciso, restauraria a config padrão"
    return
  fi
  for f in /etc/ssh/sshd_config.d/*.conf; do
    [[ -e $f ]] || continue
    mv "$f" "$f.desativado-recupera"
    info "drop-in desativado: $f"
    if "$SSHD" -t 2>/dev/null; then
      fixed "Config válida após desativar drop-ins (*.desativado-recupera)"; return
    fi
  done
  cp -a "$CFG" "$CFG.quebrado-$TS"
  if [[ -f /usr/share/openssh/sshd_config ]]; then
    cp /usr/share/openssh/sshd_config "$CFG"
    if "$SSHD" -t 2>/dev/null; then
      fixed "sshd_config restaurado do padrão do pacote (original em $CFG.quebrado-$TS)"; return
    fi
  fi
  write_minimal_config
  if "$SSHD" -t 2>/dev/null; then
    fixed "sshd_config substituído por config mínima (original em $CFG.quebrado-$TS)"
  else
    bad "Config continua inválida: $("$SSHD" -t 2>&1 | head -3)"
  fi
}

backup "$CFG"; backup /etc/ssh/sshd_config.d
if [[ ! -s $CFG ]]; then
  bad "$CFG ausente ou vazio"
  if ((DRY)); then info "[simulação] criaria config mínima"; else write_minimal_config; fixed "Config mínima criada"; fi
fi
if err=$("$SSHD" -t 2>&1); then
  ok "sshd -t: configuração válida"
else
  bad "sshd -t falhou: $err"
  repair_config
fi

# ============================================================ 5. CONTAS
step "5. Contas, chaves e permissões (StrictModes)"
KEYS=0
USERS_OK=()
while IFS=: read -r user home; do
  [[ -n $user ]] || continue
  USERS_OK+=("$user")
  if [[ ! -d $home ]]; then warn "$user: home $home não existe"; continue; fi
  perm=$(stat -c %a "$home")
  if (( (8#$perm & 8#022) != 0 )); then
    bad "$user: $home com permissão $perm (gravável por grupo/outros → sshd recusa chaves)"
    apply chmod go-w "$home" && fixed "$home → go-w"
  fi
  n=0
  if [[ -d $home/.ssh ]]; then
    if [[ $(stat -c %U "$home/.ssh") != "$user" ]]; then
      bad "$user: $home/.ssh pertence a outro usuário"
      apply chown -R "$user" "$home/.ssh" && fixed "$home/.ssh → dono $user"
    fi
    if (( (8#$(stat -c %a "$home/.ssh") & 8#077) != 0 )); then
      bad "$user: $home/.ssh muito aberto ($(stat -c %a "$home/.ssh"))"
      apply chmod 700 "$home/.ssh" && fixed "$home/.ssh → 700"
    fi
    ak="$home/.ssh/authorized_keys"
    if [[ -s $ak ]]; then
      n=$(grep -cvE '^[[:space:]]*(#|$)' "$ak" || true)
      if (( (8#$(stat -c %a "$ak") & 8#022) != 0 )); then
        bad "$user: authorized_keys gravável por outros"
        apply chmod 600 "$ak" && fixed "$ak → 600"
      fi
      [[ $(stat -c %U "$ak") == "$user" ]] || apply chown "$user" "$ak"
    fi
  fi
  KEYS=$((KEYS+n))
  pst=$(passwd -S "$user" 2>/dev/null | awk '{print $2}')
  info "$user: $n chave(s) autorizada(s); senha: ${pst:-?} (P=definida, L=bloqueada, NP=sem senha)"
  [[ $pst == L ]] && warn "$user com senha bloqueada — para definir uma nova: passwd $user"
done < <(getent passwd | awk -F: '($3==0 || $3>=1000) && $3<65534 && $7!~/(nologin|false)$/ {print $1":"$6}')
((${#USERS_OK[@]})) || warn "Nenhum usuário com shell de login encontrado"

# ============================================================ 6. RESTRIÇÕES
step "6. Restrições de acesso e autenticação no sshd"
RESTR='ListenAddress|AllowUsers|AllowGroups|DenyUsers|DenyGroups|AddressFamily'
CONF_FILES=("$CFG")
for f in /etc/ssh/sshd_config.d/*.conf; do [[ -f $f ]] && CONF_FILES+=("$f"); done

found_restr=0
for f in "${CONF_FILES[@]}"; do
  if grep -qiE "^[[:space:]]*($RESTR)[[:space:]]" "$f"; then
    found_restr=1
    bad "$f restringe o acesso: $(grep -iE "^[[:space:]]*($RESTR)[[:space:]]" "$f" | tr -s ' ' | tr '\n' ';')"
    apply sed -i -E "s/^([[:space:]]*)($RESTR)([[:space:]])/\1#recupera# \2\3/I" "$f"
    fixed "Diretivas comentadas em $f (original em $BK)"
  fi
done
((found_restr)) || ok "Sem ListenAddress/AllowUsers/AllowGroups/DenyUsers/DenyGroups/AddressFamily restritivos"
if grep -qiE '^[[:space:]]*Match[[:space:]]' "${CONF_FILES[@]}" 2>/dev/null; then
  warn "Há blocos 'Match' na configuração — podem limitar usuários/origens específicos:"
  grep -iHE '^[[:space:]]*Match[[:space:]]' "${CONF_FILES[@]}" | indent
fi

if [[ -n $FORCE_PORT ]]; then
  for f in "${CONF_FILES[@]}"; do
    apply sed -i -E "s/^([[:space:]]*)(Port)([[:space:]])/\1#recupera# \2\3/I" "$f"
  done
fi

# Ubuntu <= 20.04 não traz "Include" no sshd_config padrão: garante que o drop-in seja lido
if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' "$CFG"; then
  info "sshd_config sem Include de sshd_config.d — adicionando no topo"
  apply sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$CFG"
fi

EFF=$("$SSHD" -T 2>/dev/null || true)
get() { awk -v k="$1" '$1==k{print $2; exit}' <<<"$EFF"; }
pw=$(get passwordauthentication); pk=$(get pubkeyauthentication); prl=$(get permitrootlogin)
info "Efetivo hoje: PasswordAuthentication=${pw:-?} PubkeyAuthentication=${pk:-?} PermitRootLogin=${prl:-?}"

WANT=()
[[ ${pk:-yes} != yes ]] && WANT+=("PubkeyAuthentication yes")
if [[ ${pw:-yes} != yes ]]; then
  if ((FORCE_PW)); then
    WANT+=("PasswordAuthentication yes")
  elif ((KEYS == 0)); then
    warn "Login por senha desligado e NENHUMA chave autorizada → habilitando senha para não ficar trancado fora"
    WANT+=("PasswordAuthentication yes")
  fi
fi
[[ -n $FORCE_PORT ]] && WANT+=("Port $FORCE_PORT")

DROP=/etc/ssh/sshd_config.d/00-recupera.conf
if ((${#WANT[@]})); then
  bad "Ajustes de autenticação/porta necessários: ${WANT[*]}"
  if ((DRY)); then
    info "[simulação] escreveria $DROP com: ${WANT[*]}"
  else
    mkdir -p /etc/ssh/sshd_config.d
    { echo "# Gerado por ssh-recupera.sh ($TS). Revise e remova quando não for mais necessário."
      printf '%s\n' "${WANT[@]}"; } > "$DROP"
    chmod 644 "$DROP"
    if "$SSHD" -t 2>/dev/null; then
      fixed "Criado $DROP"
    else
      rm -f "$DROP"; bad "Drop-in gerou config inválida e foi removido"
    fi
  fi
else
  ok "Autenticação já permite acesso (nada a ajustar)"
fi
[[ ${pw:-} == yes ]] || true
[[ $prl == no ]] && warn "PermitRootLogin=no: entre com um usuário comum e use sudo"

# ============================================================ 7. SERVIÇO
step "7. Serviço SSH (systemd)"
if systemctl cat ssh.service >/dev/null 2>&1; then SVC=ssh
elif systemctl cat sshd.service >/dev/null 2>&1; then SVC=sshd
else SVC=ssh; bad "Unit ssh.service/sshd.service não encontrada"; fi

for u in ssh.service sshd.service ssh.socket; do
  if [[ $(systemctl is-enabled "$u" 2>/dev/null) == masked ]]; then
    bad "$u está MASCARADO (impossível iniciar)"
    apply systemctl unmask "$u" && fixed "$u desmascarado"
  fi
done

if systemctl cat ssh.socket >/dev/null 2>&1 \
   && { systemctl is-active --quiet ssh.socket || [[ $(systemctl is-enabled ssh.socket 2>/dev/null) == enabled ]]; }; then
  warn "ssh.socket (socket activation) ativo: ele ignora Port/ListenAddress do sshd_config e atrasa o serviço"
  apply systemctl disable --now ssh.socket && fixed "ssh.socket desativado; o ssh.service passa a escutar direto"
fi

apply systemctl daemon-reload
apply systemctl enable "$SVC" >/dev/null 2>&1
apply systemctl restart "$SVC"
sleep 2
if systemctl is-active --quiet "$SVC"; then
  ok "$SVC ativo ($(systemctl is-enabled "$SVC" 2>/dev/null))"
else
  bad "$SVC NÃO está ativo"
  systemctl status "$SVC" --no-pager -l 2>&1 | tail -12 | indent
  journalctl -u "$SVC" -n 15 --no-pager 2>/dev/null | indent
  "$SSHD" -t 2>&1 | indent
fi

# ============================================================ 8. PORTA
step "8. Porta de escuta"
mapfile -t PORTS < <("$SSHD" -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un)
((${#PORTS[@]})) || PORTS=(22)
info "Porta(s) configurada(s): ${PORTS[*]}"
for p in "${PORTS[@]}"; do
  if ss -H -tlnp "sport = :$p" 2>/dev/null | grep -q sshd; then
    ok "sshd escutando na porta $p"
    ss -H -tln "sport = :$p" | indent
  elif ss -H -tln "sport = :$p" 2>/dev/null | grep -q .; then
    bad "Outro processo ocupa a porta $p:"
    ss -H -tlnp "sport = :$p" | indent
  else
    bad "Nada escutando na porta $p"
  fi
done

# ============================================================ 9. FIREWALL
step "9. Firewall local"
fw_ufw() {
  local p=$1 lines
  lines=$(ufw status numbered 2>/dev/null | grep -E "(^|[^0-9])$p(/tcp)?[[:space:]]" || true)
  if grep -q 'ALLOW' <<<"$lines" && ! grep -qE 'DENY|REJECT' <<<"$lines"; then
    ok "ufw: porta $p liberada"
  else
    bad "ufw: sem regra liberando $p (ou há DENY/REJECT)"
    apply ufw insert 1 allow "$p/tcp" comment 'ssh-recupera' >/dev/null && fixed "ufw: regra allow $p/tcp inserida no topo"
  fi
}
fw_ipt() {
  local bin=$1 p=$2 pol
  command -v "$bin" >/dev/null 2>&1 || return 0
  pol=$($bin -S INPUT 2>/dev/null | awk '$1=="-P"{print $3}')
  [[ -n $pol ]] || return 0
  if $bin -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
    ok "$bin: já existe ACCEPT para tcp/$p"; return
  fi
  if [[ $pol == ACCEPT ]] && ! $bin -S INPUT | grep -qE -- '-j (DROP|REJECT)'; then
    ok "$bin: INPUT sem bloqueios"; return
  fi
  bad "$bin: INPUT com política $pol e/ou regras DROP/REJECT sem exceção para tcp/$p"
  apply $bin -I INPUT 1 -p tcp --dport "$p" -j ACCEPT && fixed "$bin: ACCEPT tcp/$p inserido (temporário até o próximo reload do firewall)"
}
fw_nft() {
  local p=$1 chain
  command -v nft >/dev/null 2>&1 || return 0
  chain=$(nft list chain inet filter input 2>/dev/null) || return 0
  if grep -qE "dport $p .*accept" <<<"$chain"; then ok "nftables: tcp/$p liberado"
  elif grep -qE 'policy drop|drop$|reject' <<<"$chain"; then
    bad "nftables (inet filter input) bloqueia tcp/$p"
    apply nft insert rule inet filter input tcp dport "$p" accept && fixed "nftables: accept tcp/$p inserido"
  fi
}

UFW_ACTIVE=0
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qi 'active'; then UFW_ACTIVE=1; fi
if ((UFW_ACTIVE)); then
  info "ufw ativo: $(ufw status verbose 2>/dev/null | grep -i '^Default')"
  for p in "${PORTS[@]}"; do fw_ufw "$p"; done
else
  info "ufw inativo ou ausente"
  for p in "${PORTS[@]}"; do fw_ipt iptables "$p"; fw_ipt ip6tables "$p"; done
fi
for p in "${PORTS[@]}"; do fw_nft "$p"; done
if systemctl is-active --quiet firewalld 2>/dev/null; then
  warn "firewalld ativo"
  for p in "${PORTS[@]}"; do
    apply firewall-cmd --permanent --add-port="$p/tcp" >/dev/null && apply firewall-cmd --reload >/dev/null && fixed "firewalld: tcp/$p liberado"
  done
fi
info "Regras persistentes de iptables/nft: use 'netfilter-persistent save' se quiser manter as inseridas aqui"

# ============================================================ 10. FAIL2BAN
step "10. fail2ban (IPs banidos)"
if systemctl is-active --quiet fail2ban 2>/dev/null && command -v fail2ban-client >/dev/null; then
  ok "fail2ban ativo"
  jails=$(fail2ban-client status 2>/dev/null | awk -F'Jail list:' '/Jail list/{gsub(/[ \t]/,"",$2); gsub(",", " ", $2); print $2}')
  for j in $jails; do
    ips=$(fail2ban-client status "$j" 2>/dev/null | awk -F'IP list:' '/IP list/{print $2}')
    n=$(wc -w <<<"$ips")
    info "jail $j: $n IP(s) banido(s) ${ips:+→ $ips}"
    if [[ $j == *ssh* ]] && (( n > 0 )); then
      bad "Há IPs banidos no jail $j (pode incluir você)"
      for ip in $ips; do apply fail2ban-client set "$j" unbanip "$ip" >/dev/null; done
      fixed "IPs desbanidos no jail $j"
    fi
  done
  for ip in "${MY_IPS[@]:-}"; do
    [[ -n $ip ]] || continue
    for j in $jails; do apply fail2ban-client set "$j" unbanip "$ip" >/dev/null 2>&1; done
    info "Desbanido (se estava): $ip"
  done
  IGN="127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 ${MY_IPS[*]:-}"
  if grep -rqsE '^[[:space:]]*ignoreip' /etc/fail2ban/jail.local /etc/fail2ban/jail.d 2>/dev/null; then
    warn "ignoreip já definido em /etc/fail2ban — não alterei. Inclua sua rede local/IP nele se for preciso."
  else
    if ((DRY)); then info "[simulação] criaria /etc/fail2ban/jail.d/zz-recupera-ignoreip.conf (ignoreip = $IGN)"
    else
      printf '[DEFAULT]\nignoreip = %s\n' "$IGN" > /etc/fail2ban/jail.d/zz-recupera-ignoreip.conf
      fail2ban-client reload >/dev/null 2>&1 && fixed "ignoreip configurado (localhost + redes privadas${MY_IPS:+ + seus IPs})"
    fi
  fi
else
  if command -v fail2ban-client >/dev/null 2>&1; then
    warn "fail2ban instalado, mas parado ($(systemctl is-active fail2ban 2>/dev/null))"
    if iptables -S 2>/dev/null | grep -q 'f2b-'; then
      warn "Restam chains f2b-* no iptables que ainda podem bloquear IPs"
    fi
  else
    info "fail2ban não instalado"
  fi
fi
for svc in crowdsec denyhosts sshguard; do
  systemctl is-active --quiet "$svc" 2>/dev/null && warn "$svc ativo — também pode estar bloqueando seu IP"
done

# ============================================================ 11. LOGIN BLOQUEADO
step "11. Bloqueios de login (nologin, PAM)"
blocked=0
for f in /etc/nologin /run/nologin; do
  if [[ -e $f ]]; then
    blocked=1
    bad "$f existe (bloqueia login de usuários não-root): $(head -c 200 "$f" | tr '\n' ' ')"
    backup "$f"; apply rm -f "$f" && fixed "$f removido"
  fi
done
((blocked)) || ok "Sem /etc/nologin nem /run/nologin"
if grep -qE '^[[:space:]]*account[[:space:]]+required[[:space:]]+pam_access' /etc/pam.d/sshd /etc/pam.d/common-account 2>/dev/null; then
  warn "pam_access ativo — regras em /etc/security/access.conf podem negar logins:"
  grep -vE '^[[:space:]]*(#|$)' /etc/security/access.conf 2>/dev/null | indent
fi
if [[ -f /etc/hosts.deny ]] && grep -qvE '^[[:space:]]*(#|$)' /etc/hosts.deny; then
  warn "/etc/hosts.deny tem regras (TCP wrappers; o sshd do Ubuntu normalmente ignora):"
  grep -vE '^[[:space:]]*(#|$)' /etc/hosts.deny | indent
fi

# ============================================================ 12. REDE
step "12. Rede"
ip -br link | indent
ip -br addr | indent
if ip -br link | grep -q 'NO-CARRIER'; then
  warn "Interface com NO-CARRIER: verifique cabo, porta do switch ou a placa de rede virtual"
fi
has_ip() { [[ -n $(ip -4 -o addr show scope global 2>/dev/null) ]]; }
if has_ip; then
  ok "Há IPv4 configurado"
else
  bad "Nenhuma interface com IPv4 global"
  for i in $(ls /sys/class/net); do
    [[ $i == lo || ! -e /sys/class/net/$i/device ]] && continue
    apply ip link set "$i" up
  done
  if command -v netplan >/dev/null 2>&1; then
    ls /etc/netplan 2>/dev/null | indent
    apply netplan apply
  elif systemctl is-active --quiet NetworkManager; then apply systemctl restart NetworkManager
  else apply systemctl restart systemd-networkd 2>/dev/null; fi
  sleep 5
  if has_ip; then fixed "Rede restabelecida:"; ip -br addr | indent
  else warn "Ainda sem IPv4: revise /etc/netplan/*.yaml (netplan try), DHCP do roteador e o cabo"; fi
fi
gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
if [[ -n $gw ]]; then
  if ping -c2 -W2 "$gw" >/dev/null 2>&1; then ok "Gateway $gw responde"
  else bad "Gateway $gw não responde ao ping (cabo/VLAN/roteador? alguns roteadores bloqueiam ping)"; fi
else
  bad "Sem rota padrão (default route)"
fi
if ping -c2 -W2 1.1.1.1 >/dev/null 2>&1; then ok "Saída para a internet (1.1.1.1) OK"
else warn "Sem resposta de 1.1.1.1 — sem saída para a internet (não impede SSH local)"; fi
getent hosts archive.ubuntu.com >/dev/null 2>&1 && ok "DNS resolvendo" || warn "DNS não resolve (afeta apt, não o SSH)"

# ============================================================ 13. TESTE LOCAL
step "13. Teste real de conexão SSH (banner)"
banner() { timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2 && read -r -t 4 l <&3 && echo \"\$l\"" 2>/dev/null; }
ADDRS=(127.0.0.1)
while read -r a; do [[ -n $a ]] && ADDRS+=("$a"); done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')
for p in "${PORTS[@]}"; do
  for a in "${ADDRS[@]}"; do
    b=$(banner "$a" "$p")
    if [[ $b == SSH-* ]]; then ok "$a:$p respondeu: $b"
    else bad "$a:$p NÃO respondeu SSH"; fi
  done
done

# ============================================================ RESUMO
step "Resumo"
if ((DRY)); then
  echo "SIMULAÇÃO: nada foi alterado. Problemas detectados: $PROBLEMS"
  echo "Rode sem --dry-run para aplicar as correções."
else
  echo "Problemas detectados: $PROBLEMS | correções aplicadas: $FIXES"
fi
echo
echo "Para conectar a partir de outra máquina da rede:"
for a in "${ADDRS[@]:1}"; do
  for p in "${PORTS[@]}"; do
    echo "    ssh ${USERS_OK[0]:-USUARIO}@$a$([[ $p != 22 ]] && echo " -p $p")"
  done
done
cat <<EOF

Se ainda não funcionar pela rede local, mas o teste 13 passou em 127.0.0.1:
  - Compare com o teste no IP da LAN: se só ele falhou, é firewall local.
  - Se ambos passaram, o problema está fora do servidor: cabo/switch, VLAN, IP
    errado, ou o cliente (chave com permissão errada, known_hosts antigo:
    ssh-keygen -R IP).
Pela internet, além do acima, confira FORA do servidor:
  - Firewall/Security Group do provedor (VPS/nuvem) liberando a porta SSH.
  - Port-forward no roteador, IP público atual, CGNAT ou bloqueio da porta 22
    pelo provedor de internet (teste outra porta com --port).
Para acompanhar as tentativas em tempo real enquanto testa de outra máquina:
  journalctl -u $SVC -f      ou      tail -f /var/log/auth.log

Backups das alterações: $BK
Relatório completo:     $LOG
EOF
sleep 0.3
