#!/usr/bin/env bash
# =============================================================================
#  Implement Load Balancing on Compute Engine: Challenge Lab (GSP313)
#  Google Skills - skill badge "Implementing Cloud Load Balancing for Compute Engine"
#
#  Uso direto do GitHub (no Cloud Shell do lab):
#     bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp313.sh)
#
#  Ou baixando:
#     curl -sLO https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp313.sh
#     bash gsp313.sh
#
#  O script pede os parametros do lab (ENTER aceita o valor padrao entre [ ])
#  e executa as 3 tarefas. Confira sempre os nomes no painel do seu lab.
# =============================================================================
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[1;34m'; NC='\033[0m'
info() { echo -e "${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $*"; }
fail() { echo -e "${RED}[ERRO]${NC} $*"; }

ask() {   # ask VAR "Pergunta" "padrao"
  local __var=$1 __prompt=$2 __def=${3:-} __val
  read -r -p "$(echo -e "${YELLOW}?${NC} ${__prompt} [${__def}]: ")" __val </dev/tty
  printf -v "$__var" '%s' "${__val:-$__def}"
}

# Executa um comando; se o recurso ja existir, apenas avisa e segue.
run() {
  local out
  if out=$("$@" 2>&1); then
    local cmd="$*"; ok "$(head -n1 <<<"$cmd" | cut -c1-110)"
  elif grep -qiE "already exists|alreadyExists" <<<"$out"; then
    warn "ja existe -> $(head -n1 <<<"$*" | cut -c1-110)"
  else
    fail "$(head -n1 <<<"$*" | cut -c1-110)"; echo "$out" | head -n 5; return 1
  fi
}

# ----------------------------------------------------------------------------
# Verificacao: a conta ativa do Cloud Shell tem acesso a este projeto?
# ----------------------------------------------------------------------------
preflight() {
  local acct roles
  acct=$(gcloud config get-value account 2>/dev/null)
  roles=$(gcloud projects get-iam-policy "$PROJECT" --flatten="bindings[].members" \
    --filter="bindings.members:user:$acct" --format="value(bindings.role)" 2>/dev/null)
  if grep -qE "roles/(owner|editor)" <<<"$roles"; then
    ok "Conta ativa: $acct ($(grep -oE 'roles/(owner|editor)' <<<"$roles" | head -n1))"
    return 0
  fi
  fail "A conta ativa do Cloud Shell ($acct) NAO e Owner/Editor do projeto $PROJECT."
  echo "   Provavel causa: Cloud Shell de outro lab/conta aberto na mesma janela."
  echo "   Solucao: feche as janelas anonimas, abra o console pelo link do lab,"
  echo "   entre com o Username/Password DESTE lab e rode o script de novo."
  echo "   (confira com: gcloud auth list)"
  read -r -p "Continuar mesmo assim? (s/N): " __c </dev/tty
  [[ "$__c" =~ ^[sSyY]$ ]] || exit 1
}

# ----------------------------------------------------------------------------
# 0. Parametros
# ----------------------------------------------------------------------------
echo -e "${BLUE}"
echo "=============================================================="
echo "  GSP313 - Implement Load Balancing on Compute Engine"
echo "=============================================================="
echo -e "${NC}"

DEF_PROJECT=$(gcloud config get-value project 2>/dev/null)
DEF_ZONE=$(gcloud config get-value compute/zone 2>/dev/null)
DEF_REGION=$(gcloud config get-value compute/region 2>/dev/null)
if [[ -z "$DEF_ZONE" && -n "$DEF_PROJECT" ]]; then
  DEF_ZONE=$(gcloud compute project-info describe --project "$DEF_PROJECT" \
    --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null)
fi
if [[ -z "$DEF_REGION" && -n "$DEF_PROJECT" ]]; then
  DEF_REGION=$(gcloud compute project-info describe --project "$DEF_PROJECT" \
    --format="value(commonInstanceMetadata.items[google-compute-default-region])" 2>/dev/null)
fi

info "Parametros gerais (veja o painel 'Lab Details' / enunciado do lab)"
ask PROJECT "Project ID"  "$DEF_PROJECT"
ask ZONE    "Zona"        "${DEF_ZONE:-us-central1-a}"
ask REGION  "Regiao"      "${DEF_REGION:-${ZONE%-*}}"

echo
info "Tarefa 1 - VMs web e firewall"
ask WEB_VMS      "Nomes das VMs (separados por espaco)" "web1 web2 web3"
ask WEB_MACHINE  "Tipo de maquina das VMs"              "e2-small"
ask WEB_TAG      "Network tag das VMs"                  "network-lb-tag"
ask FW_NLB       "Regra de firewall (porta 80)"         "www-firewall-network-lb"
ask IMG_FAMILY   "Familia da imagem"                    "debian-12"
ask IMG_PROJECT  "Projeto da imagem"                    "debian-cloud"

echo
info "Tarefa 2 - Network Load Balancer"
ask NLB_IP       "IP estatico regional"                 "network-lb-ip-1"
ask NLB_HC       "Legacy HTTP health check"             "basic-check"
ask NLB_POOL     "Target pool"                          "www-pool"
ask NLB_RULE     "Forwarding rule"                      "www-rule"

echo
info "Tarefa 3 - HTTP(S) Load Balancer"
ask TEMPLATE     "Instance template"                    "lb-backend-template"
ask TPL_MACHINE  "Tipo de maquina do template"          "e2-medium"
ask MIG          "Managed instance group"               "lb-backend-group"
ask MIG_SIZE     "Tamanho do MIG"                       "2"
ask HC_TAG       "Tag de health check"                  "allow-health-check"
ask FW_HC        "Firewall de health check"             "fw-allow-health-check"
ask LB_IP        "IP global do LB"                      "lb-ipv4-1"
ask HTTP_HC      "Health check do LB"                   "http-basic-check"
ask BACKEND      "Backend service"                      "web-backend-service"
ask URL_MAP      "URL map"                              "web-map-http"
ask PROXY        "Target HTTP proxy"                    "http-lb-proxy"
ask FWD_RULE     "Forwarding rule global"               "http-content-rule"

echo
echo "--------------------------------------------------------------"
echo " Projeto: $PROJECT | Regiao: $REGION | Zona: $ZONE"
echo " VMs: $WEB_VMS ($WEB_MACHINE, tag $WEB_TAG)"
echo " NLB: $NLB_IP / $NLB_HC / $NLB_POOL / $NLB_RULE"
echo " HTTP LB: $TEMPLATE / $MIG($MIG_SIZE) / $BACKEND / $URL_MAP / $PROXY / $FWD_RULE"
echo "--------------------------------------------------------------"
read -r -p "Confirmar e executar? (s/N): " CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[sSyY]$ ]] || { warn "Cancelado."; exit 0; }

gcloud config set project "$PROJECT"        >/dev/null 2>&1
preflight
gcloud config set compute/zone "$ZONE"      >/dev/null 2>&1
gcloud config set compute/region "$REGION"  >/dev/null 2>&1
# A Compute Engine API ja vem ativa no lab (a conta de aluno nao pode ativar APIs).
if ! gcloud services list --enabled --filter="name:compute.googleapis.com" --format="value(name)" 2>/dev/null | grep -q compute; then
  warn "Compute Engine API parece inativa; tentando ativar..."
  gcloud services enable compute.googleapis.com >/dev/null 2>&1 || warn "Sem permissao para ativar APIs (normal no lab). Seguindo."
fi

# ----------------------------------------------------------------------------
# Tarefa 1 - Multiplas VMs web + firewall
# ----------------------------------------------------------------------------
echo; info "TAREFA 1: criando VMs web e regra de firewall"
for VM in $WEB_VMS; do
  run gcloud compute instances create "$VM" \
    --zone="$ZONE" \
    --machine-type="$WEB_MACHINE" \
    --tags="$WEB_TAG" \
    --image-family="$IMG_FAMILY" \
    --image-project="$IMG_PROJECT" \
    --metadata=startup-script="#!/bin/bash
# espera o apt ficar livre (evita 'Could not get lock')
for i in \$(seq 1 30); do apt-get update && apt-get install apache2 -y && break; sleep 10; done
service apache2 restart
echo \"<h3>Web Server: $VM</h3>\" | tee /var/www/html/index.html"
done

run gcloud compute firewall-rules create "$FW_NLB" \
  --network=default \
  --target-tags="$WEB_TAG" \
  --allow=tcp:80

# ----------------------------------------------------------------------------
# Tarefa 2 - Network Load Balancer (target pool)
# ----------------------------------------------------------------------------
echo; info "TAREFA 2: configurando o Network Load Balancer"
run gcloud compute addresses create "$NLB_IP" --region="$REGION"
run gcloud compute http-health-checks create "$NLB_HC"
run gcloud compute target-pools create "$NLB_POOL" \
  --region="$REGION" --http-health-check="$NLB_HC"

VM_LIST=$(echo "$WEB_VMS" | tr ' ' ',')
run gcloud compute target-pools add-instances "$NLB_POOL" \
  --instances="$VM_LIST" --instances-zone="$ZONE"

run gcloud compute forwarding-rules create "$NLB_RULE" \
  --region="$REGION" \
  --ports=80 \
  --address="$NLB_IP" \
  --target-pool="$NLB_POOL"

# ----------------------------------------------------------------------------
# Tarefa 3 - HTTP Load Balancer (MIG + backend service)
# ----------------------------------------------------------------------------
echo; info "TAREFA 3: criando o HTTP Load Balancer"
run gcloud compute instance-templates create "$TEMPLATE" \
  --region="$REGION" \
  --network=default \
  --subnet=default \
  --tags="$HC_TAG" \
  --machine-type="$TPL_MACHINE" \
  --image-family="$IMG_FAMILY" \
  --image-project="$IMG_PROJECT" \
  --metadata=startup-script='#!/bin/bash
for i in $(seq 1 30); do apt-get update && apt-get install apache2 -y && break; sleep 10; done
a2ensite default-ssl
a2enmod ssl
vm_hostname="$(curl -H "Metadata-Flavor:Google" \
http://169.254.169.254/computeMetadata/v1/instance/name)"
echo "Page served from: $vm_hostname" | \
tee /var/www/html/index.html
systemctl restart apache2'

run gcloud compute instance-groups managed create "$MIG" \
  --template="$TEMPLATE" --size="$MIG_SIZE" --zone="$ZONE"

run gcloud compute firewall-rules create "$FW_HC" \
  --network=default \
  --action=allow \
  --direction=ingress \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags="$HC_TAG" \
  --rules=tcp:80

run gcloud compute addresses create "$LB_IP" --ip-version=IPV4 --global

run gcloud compute health-checks create http "$HTTP_HC" --port 80

run gcloud compute instance-groups managed set-named-ports "$MIG" \
  --named-ports=http:80 --zone="$ZONE"

run gcloud compute backend-services create "$BACKEND" \
  --protocol=HTTP \
  --port-name=http \
  --health-checks="$HTTP_HC" \
  --global

run gcloud compute backend-services add-backend "$BACKEND" \
  --instance-group="$MIG" \
  --instance-group-zone="$ZONE" \
  --global

run gcloud compute url-maps create "$URL_MAP" --default-service="$BACKEND"
run gcloud compute target-http-proxies create "$PROXY" --url-map="$URL_MAP"
run gcloud compute forwarding-rules create "$FWD_RULE" \
  --address="$LB_IP" \
  --global \
  --target-http-proxy="$PROXY" \
  --ports=80

# ----------------------------------------------------------------------------
# Resumo / verificacao
# ----------------------------------------------------------------------------
echo; info "Resumo"
NLB_ADDR=$(gcloud compute addresses describe "$NLB_IP" --region="$REGION" --format='value(address)' 2>/dev/null)
HTTP_ADDR=$(gcloud compute addresses describe "$LB_IP" --global --format='value(address)' 2>/dev/null)
echo " Network LB : http://$NLB_ADDR"
echo " HTTP LB    : http://$HTTP_ADDR"
echo
info "Testando o Network LB (pode levar 1-2 min ate as VMs responderem)..."
for i in 1 2 3 4 5 6; do curl -s -m 5 "http://$NLB_ADDR" && break; sleep 15; done
echo
warn "O HTTP LB global pode levar de 3 a 7 minutos para ficar ativo."
warn "Teste depois com: curl http://$HTTP_ADDR"
echo
ok "Concluido! Clique em 'Check my progress' em cada tarefa do lab."
