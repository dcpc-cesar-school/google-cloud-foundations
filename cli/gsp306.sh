#!/usr/bin/env bash
# =============================================================================
#  Migrate a MySQL Database to Google Cloud SQL: Challenge Lab (GSP306)
#  Google Skills - "Cloud Architecture: Design, Implement, and Manage"
#
#  Uso direto do GitHub (no Cloud Shell do lab):
#     bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp306.sh)
#
#  Cria a instancia Cloud SQL (MySQL) autorizando o IP da VM blog, cria o banco
#  wordpress e o usuario blogadmin, faz dump/import a partir da VM blog e
#  aponta o DB_HOST do wp-config.php para o Cloud SQL.
# =============================================================================
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[1;34m'; NC='\033[0m'
info() { echo -e "${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $*"; }
fail() { echo -e "${RED}[ERRO]${NC} $*"; }

ask() {   # ask VAR "Pergunta" "padrao" [obrigatorio=1]
  local __var=$1 __prompt=$2 __def=${3:-} __req=${4:-0} __val
  while true; do
    read -r -p "$(echo -e "${YELLOW}?${NC} ${__prompt} [${__def}]: ")" __val </dev/tty
    __val=${__val:-$__def}
    [[ -n "$__val" || "$__req" != 1 ]] && break
    fail "Valor obrigatorio."
  done
  printf -v "$__var" '%s' "$__val"
}

run() {
  local out cmd="$*"
  if out=$("$@" 2>&1); then
    ok "$(head -n1 <<<"$cmd" | cut -c1-110)"
  elif grep -qiE "already exists|alreadyExists" <<<"$out"; then
    warn "ja existe -> $(head -n1 <<<"$cmd" | cut -c1-110)"
  else
    fail "$(head -n1 <<<"$cmd" | cut -c1-110)"; echo "$out" | tail -n 8; return 1
  fi
}

# ----------------------------------------------------------------------------
# 0. Parametros (zona detectada pela VM blog)
# ----------------------------------------------------------------------------
echo -e "${BLUE}"
echo "=============================================================="
echo "  GSP306 - Migrate a MySQL Database to Google Cloud SQL"
echo "=============================================================="
echo -e "${NC}"

DEF_PROJECT=$(gcloud config get-value project 2>/dev/null)
DEF_ZONE=$(gcloud compute instances list --filter="name=blog" \
  --format="value(zone.basename())" 2>/dev/null | head -n1)
[[ -z "$DEF_ZONE" ]] && DEF_ZONE=$(gcloud config get-value compute/zone 2>/dev/null)

info "Valores do lab (Zona e Regiao aparecem depois de 'Iniciar laboratorio')"
ask PROJECT  "Project ID"                    "$DEF_PROJECT" 1
ask ZONE     "Zona"                          "${DEF_ZONE:-us-central1-a}" 1
ask REGION   "Regiao"                        "${ZONE%-*}" 1
ask VM       "VM do blog"                    "blog"
ask SQLINST  "Instancia Cloud SQL"           "wordpress"
ask DBVER    "Versao do MySQL"               "MYSQL_8_0"
ask TIER     "Tier"                          "db-n1-standard-1"
ask DB       "Banco"                         "wordpress"
ask DBUSER   "Usuario do banco"              "blogadmin"
ask DBPASS   "Senha do usuario"              'Password1*'
ask WPCONF   "wp-config.php"                 "/var/www/html/wordpress/wp-config.php"

echo
echo "--------------------------------------------------------------"
echo " Projeto : $PROJECT | Regiao: $REGION | Zona: $ZONE"
echo " Cloud SQL: $SQLINST ($DBVER, $TIER, edicao Enterprise)"
echo " Banco   : $DB / usuario $DBUSER"
echo " Blog    : VM $VM -> $WPCONF"
echo "--------------------------------------------------------------"
read -r -p "Confirmar e executar? (s/N): " CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[sSyY]$ ]] || { warn "Cancelado."; exit 0; }

gcloud config set project "$PROJECT"       >/dev/null 2>&1
gcloud config set compute/zone "$ZONE"     >/dev/null 2>&1
gcloud config set compute/region "$REGION" >/dev/null 2>&1
gcloud services enable sqladmin.googleapis.com >/dev/null 2>&1 || true

BLOG_IP=$(gcloud compute instances describe "$VM" --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)
[[ -z "$BLOG_IP" ]] && { fail "Nao encontrei a VM $VM em $ZONE."; exit 1; }
ok "IP externo da VM $VM: $BLOG_IP"

# ----------------------------------------------------------------------------
# Tarefa 1 - Instancia Cloud SQL (com o IP do blog autorizado)
# ----------------------------------------------------------------------------
echo; info "TAREFA 1: criando a instancia Cloud SQL $SQLINST (leva 5-10 min)"
if gcloud sql instances describe "$SQLINST" >/dev/null 2>&1; then
  warn "instancia $SQLINST ja existe"
else
  run gcloud sql instances create "$SQLINST" \
    --database-version="$DBVER" \
    --edition=enterprise \
    --tier="$TIER" \
    --region="$REGION" \
    --zone="$ZONE" \
    --root-password="$DBPASS" \
    --authorized-networks="$BLOG_IP/32" || exit 1
fi
# garante a rede autorizada mesmo se a instancia ja existia
run gcloud sql instances patch "$SQLINST" --authorized-networks="$BLOG_IP/32" --quiet
SQL_IP=$(gcloud sql instances describe "$SQLINST" --format='value(ipAddresses[0].ipAddress)')
ok "IP publico do Cloud SQL: $SQL_IP"
warn ">>> Ja pode verificar a tarefa 1. <<<"

# ----------------------------------------------------------------------------
# Tarefa 2 - Banco e usuario
# ----------------------------------------------------------------------------
echo; info "TAREFA 2: criando o banco $DB e o usuario $DBUSER"
run gcloud sql databases create "$DB" --instance="$SQLINST"
if gcloud sql users list --instance="$SQLINST" --format='value(name)' | grep -qx "$DBUSER"; then
  run gcloud sql users set-password "$DBUSER" --host=% --instance="$SQLINST" --password="$DBPASS"
else
  run gcloud sql users create "$DBUSER" --host=% --instance="$SQLINST" --password="$DBPASS"
fi
warn ">>> Ja pode verificar a tarefa 2. <<<"

# ----------------------------------------------------------------------------
# Tarefas 3 e 4 - Dump/import e wp-config.php (executados na VM blog)
# ----------------------------------------------------------------------------
echo; info "TAREFAS 3 e 4: dump, import e reconfiguracao do WordPress na VM $VM"
REMOTE_CMD=$(cat <<EOF
set -e
export MYSQL_PWD='$DBPASS'
echo "--- dump do banco local"
mysqldump -u '$DBUSER' --databases '$DB' --no-tablespaces --single-transaction > /tmp/wordpress_dump.sql
ls -lh /tmp/wordpress_dump.sql
echo "--- import no Cloud SQL ($SQL_IP)"
mysql -h '$SQL_IP' -u '$DBUSER' < /tmp/wordpress_dump.sql
mysql -h '$SQL_IP' -u '$DBUSER' -e "SELECT COUNT(*) AS tabelas FROM information_schema.tables WHERE table_schema='$DB';"
echo "--- apontando o wp-config.php para o Cloud SQL"
sudo cp '$WPCONF' '$WPCONF.bak-local'
sudo sed -i -E "s/(define\\(\\s*['\"]DB_HOST['\"]\\s*,\\s*['\"])[^'\"]*/\\1$SQL_IP/" '$WPCONF'
grep -E "DB_(HOST|NAME|USER)" '$WPCONF'
EOF
)
if gcloud compute ssh "$VM" --zone="$ZONE" --quiet --command="$REMOTE_CMD"; then
  ok "Dados migrados e wp-config.php atualizado"
else
  warn "SSH direto falhou; tentando via IAP..."
  gcloud compute ssh "$VM" --zone="$ZONE" --quiet --tunnel-through-iap --command="$REMOTE_CMD" \
    && ok "Dados migrados e wp-config.php atualizado" \
    || { fail "Nao consegui executar na VM $VM. Comandos para rodar no SSH da VM:"; echo "$REMOTE_CMD" | sed 's/^/    /'; exit 1; }
fi
warn ">>> Ja pode verificar as tarefas 3 e 4. <<<"

# ----------------------------------------------------------------------------
# Tarefa 5 - Validar o blog
# ----------------------------------------------------------------------------
echo; info "TAREFA 5: testando o blog em http://$BLOG_IP"
CODE=$(curl -s -o /tmp/gsp306-blog.html -m 10 -w "%{http_code}" "http://$BLOG_IP" || true)
if [[ "$CODE" == "200" ]] && ! grep -qi "Error establishing a database connection" /tmp/gsp306-blog.html; then
  ok "Blog respondendo (HTTP 200) usando o Cloud SQL"
  grep -o '<title>[^<]*' /tmp/gsp306-blog.html | sed 's/<title>/   Titulo: /' || true
else
  fail "Blog com problema (HTTP $CODE). Para voltar ao banco local:"
  echo "   gcloud compute ssh $VM --zone $ZONE --command \"sudo cp $WPCONF.bak-local $WPCONF\""
fi

echo
ok "Concluido! Clique em 'Verificar meu progresso' na tarefa 5."
