#!/usr/bin/env bash
# =============================================================================
#  Deploy a Compute Instance with a Remote Startup Script: Challenge Lab (GSP301)
#  Google Skills - "Cloud Architecture: Design, Implement, and Manage"
#
#  Uso direto do GitHub (no Cloud Shell do lab):
#     bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp301.sh)
#
#  O script pede os parametros do lab (ENTER aceita o valor padrao entre [ ])
#  e executa as 4 tarefas. NAO altera a instancia de monitoramento do lab.
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

# Executa um comando; se o recurso ja existir, apenas avisa e segue.
run() {
  local out cmd="$*" try
  for try in 1 2 3 4; do
    if out=$("$@" 2>&1); then
      ok "$(head -n1 <<<"$cmd" | cut -c1-110)"; return 0
    elif grep -qiE "already exists|alreadyExists|already own" <<<"$out"; then
      warn "ja existe -> $(head -n1 <<<"$cmd" | cut -c1-110)"; return 0
    elif grep -qiE "PERMISSION_DENIED|permission" <<<"$out" && [[ $try -lt 4 ]]; then
      warn "sem permissao ainda (propagando)... tentativa $try/4, aguardando 20s"; sleep 20
    else
      break
    fi
  done
  fail "$(head -n1 <<<"$cmd" | cut -c1-110)"; echo "$out" | tail -n 8; return 1
}

# ----------------------------------------------------------------------------
# 0. Parametros
# ----------------------------------------------------------------------------
echo -e "${BLUE}"
echo "=============================================================="
echo "  GSP301 - Compute Instance with a Remote Startup Script"
echo "=============================================================="
echo -e "${NC}"

DEF_PROJECT=$(gcloud config get-value project 2>/dev/null)
DEF_ZONE=$(gcloud config get-value compute/zone 2>/dev/null)
if [[ -z "$DEF_ZONE" && -n "$DEF_PROJECT" ]]; then
  DEF_ZONE=$(gcloud compute project-info describe --project "$DEF_PROJECT" \
    --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null)
fi
# a instancia de monitoramento do lab costuma estar na zona do lab
if [[ -z "$DEF_ZONE" && -n "$DEF_PROJECT" ]]; then
  DEF_ZONE=$(gcloud compute instances list --project "$DEF_PROJECT" \
    --format="value(zone.basename())" 2>/dev/null | head -n1)
fi

info "Valores das instrucoes do lab (a zona aparece depois de 'Iniciar laboratorio')"
ask PROJECT  "Project ID"                    "$DEF_PROJECT" 1
ask ZONE     "Zona"                          "${DEF_ZONE:-us-central1-a}" 1
ask REGION   "Regiao"                        "${ZONE%-*}" 1
ask BUCKET   "Bucket (tarefa 1)"             "$PROJECT" 1
ask VM       "Nome da VM (tarefa 2)"         "lab-vm" 1
ask MACHINE  "Tipo de maquina"               "e2-medium"
ask FW       "Regra de firewall (tarefa 3)"  "allow-http"
ask SRC      "Script de inicializacao"       "gs://spls/gsp301/install-web.sh"

SCRIPT_NAME=$(basename "$SRC")
echo
echo "--------------------------------------------------------------"
echo " Projeto : $PROJECT | Regiao: $REGION | Zona: $ZONE"
echo " Bucket  : gs://$BUCKET  (recebe $SCRIPT_NAME)"
echo " VM      : $VM ($MACHINE) com startup-script-url=gs://$BUCKET/$SCRIPT_NAME"
echo " Firewall: $FW (tcp:80 -> tag http-server)"
echo "--------------------------------------------------------------"
read -r -p "Confirmar e executar? (s/N): " CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[sSyY]$ ]] || { warn "Cancelado."; exit 0; }

gcloud config set project "$PROJECT"       >/dev/null 2>&1
gcloud config set compute/zone "$ZONE"     >/dev/null 2>&1
gcloud config set compute/region "$REGION" >/dev/null 2>&1

# ----------------------------------------------------------------------------
# Permissoes reais da conta (testIamPermissions)
# ----------------------------------------------------------------------------
ACCT=$(gcloud config get-value account 2>/dev/null)
info "Conta: $ACCT"
PERMS=$(curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" \
  -H "Content-Type: application/json" \
  "https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT:testIamPermissions" \
  -d '{"permissions":["storage.buckets.create","compute.instances.create","compute.firewalls.create","iam.serviceAccounts.actAs"]}')
MISSING=0
for P in storage.buckets.create compute.instances.create compute.firewalls.create iam.serviceAccounts.actAs; do
  if grep -q "\"$P\"" <<<"$PERMS"; then ok "tem $P"; else warn "NAO tem $P"; MISSING=1; fi
done
if [[ $MISSING == 1 ]]; then
  warn "Faltam permissoes. Confira com 'gcloud auth list' se a conta e o Username deste lab."
  read -r -p "Continuar mesmo assim? (s/N): " __c </dev/tty
  [[ "$__c" =~ ^[sSyY]$ ]] || exit 1
fi

# ----------------------------------------------------------------------------
# Tarefa 1 - Bucket com o script de inicializacao
# ----------------------------------------------------------------------------
echo; info "TAREFA 1: criando o bucket e copiando o $SCRIPT_NAME"
run gcloud storage buckets create "gs://$BUCKET" --location="$REGION" --uniform-bucket-level-access
run gcloud storage cp "$SRC" "gs://$BUCKET/$SCRIPT_NAME"

# ----------------------------------------------------------------------------
# Tarefa 2 - VM com script de inicializacao remoto
# (escopo padrao da conta de servico ja inclui leitura do Cloud Storage)
# ----------------------------------------------------------------------------
echo; info "TAREFA 2: criando a VM $VM com startup-script-url"
run gcloud compute instances create "$VM" \
  --zone="$ZONE" \
  --machine-type="$MACHINE" \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --tags=http-server \
  --scopes=storage-ro,logging-write,monitoring-write \
  --metadata=startup-script-url="gs://$BUCKET/$SCRIPT_NAME"

# ----------------------------------------------------------------------------
# Tarefa 3 - Firewall HTTP
# ----------------------------------------------------------------------------
echo; info "TAREFA 3: criando a regra de firewall $FW (tcp:80)"
run gcloud compute firewall-rules create "$FW" \
  --network=default \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:80 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=http-server

# ----------------------------------------------------------------------------
# Tarefa 4 - Verificar o Apache
# ----------------------------------------------------------------------------
echo; info "TAREFA 4: aguardando o Apache responder (ate ~4 min)"
IP=$(gcloud compute instances describe "$VM" --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)
echo "   IP externo: $IP"
UP=0
for i in $(seq 1 24); do
  CODE=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "http://$IP" || true)
  if [[ "$CODE" == "200" ]]; then UP=1; break; fi
  sleep 10
done
if [[ $UP == 1 ]]; then
  ok "Apache respondendo em http://$IP"
  curl -s -m 5 "http://$IP" | grep -o '<title>[^<]*' | sed 's/<title>/   Pagina: /' || true
else
  warn "Ainda sem resposta em http://$IP. Veja o console serial:"
  echo "   gcloud compute instances get-serial-port-output $VM --zone=$ZONE | grep -i startup-script"
fi

echo
ok "Concluido! Clique em 'Verificar meu progresso' em cada tarefa do lab."
