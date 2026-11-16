#!/usr/bin/env bash
# =============================================================================
#  Implement Cloud Security Fundamentals on Google Cloud: Challenge Lab (GSP342)
#  Google Skills - skill badge "Implement Cloud Security Fundamentals on Google Cloud"
#
#  Uso direto do GitHub (no Cloud Shell do lab):
#     bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp342.sh)
#
#  O script pede os parametros do lab (ENTER aceita o valor padrao entre [ ])
#  e executa as 5 tarefas. Confira sempre os nomes nas instrucoes do lab.
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
  for try in 1 2 3 4 5 6 7 8; do
    if out=$("$@" 2>&1); then
      ok "$(head -n1 <<<"$cmd" | cut -c1-110)"; return 0
    elif grep -qiE "already exists|alreadyExists" <<<"$out"; then
      warn "ja existe -> $(head -n1 <<<"$cmd" | cut -c1-110)"; return 0
    elif grep -qiE "PERMISSION_DENIED|does not have|permission" <<<"$out" && [[ $try -lt 8 ]]; then
      warn "sem permissao ainda (propagando IAM)... tentativa $try/8, aguardando 20s"
      sleep 20
    else
      break
    fi
  done
  fail "$(head -n1 <<<"$cmd" | cut -c1-110)"; echo "$out" | tail -n 8; return 1
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
  fail "A conta ativa ($acct) NAO aparece como Owner/Editor do projeto $PROJECT."
  if [[ -n "$roles" ]]; then echo "   Papeis encontrados: $(tr '\n' ' ' <<<"$roles")"
  else echo "   Nenhum papel encontrado (ou sem permissao para ler o IAM)."; fi
  echo "   Causas possiveis:"
  echo "   1) o lab ainda esta provisionando: aguarde alguns minutos e rode de novo;"
  echo "   2) Cloud Shell com conta de outro lab: confira com 'gcloud auth list' e"
  echo "      compare com o Username do painel do lab."
  read -r -p "Continuar mesmo assim? (s/N): " __c </dev/tty
  [[ "$__c" =~ ^[sSyY]$ ]] || exit 1
}

# ----------------------------------------------------------------------------
# 0. Parametros
# ----------------------------------------------------------------------------
echo -e "${BLUE}"
echo "=============================================================="
echo "  GSP342 - Implement Cloud Security Fundamentals"
echo "=============================================================="
echo -e "${NC}"

DEF_PROJECT=$(gcloud config get-value project 2>/dev/null)
JUMPHOST=orca-jumphost
# A zona do lab e a zona onde o orca-jumphost ja existe
DEF_ZONE=$(gcloud compute instances list --filter="name=$JUMPHOST" \
  --format="value(zone.basename())" 2>/dev/null | head -n1)
[[ -z "$DEF_ZONE" ]] && DEF_ZONE=$(gcloud config get-value compute/zone 2>/dev/null)

info "Valores das instrucoes do lab (aparecem depois de 'Iniciar laboratorio')"
ask PROJECT  "Project ID"                                   "$DEF_PROJECT" 1
ask ZONE     "Zona"                                         "${DEF_ZONE:-us-east1-b}" 1
ask REGION   "Regiao"                                       "${ZONE%-*}" 1
ask ROLE_ID  "Papel personalizado (tarefa 1, ex: orca_storage_editor_xxx)" "" 1
ask SA_NAME  "Conta de servico (tarefa 2, ex: orca-private-cluster-xxx-sa)" "" 1
ask CLUSTER  "Cluster GKE (tarefa 4, ex: orca-cluster-xxx)" "" 1
ask SUBNET   "Sub-rede do cluster"                          "orca-build-subnet"
ask JUMPHOST "Jumphost"                                     "$JUMPHOST"
ask MASTER_CIDR "Faixa /28 do control plane"                "172.16.0.0/28"

SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

echo
echo "--------------------------------------------------------------"
echo " Projeto : $PROJECT | Regiao: $REGION | Zona: $ZONE"
echo " Papel   : $ROLE_ID"
echo " SA      : $SA_EMAIL"
echo " Cluster : $CLUSTER (sub-rede $SUBNET, control plane $MASTER_CIDR)"
echo " Jumphost: $JUMPHOST"
echo "--------------------------------------------------------------"
[[ "$ROLE_ID" == *-* ]] && warn "IDs de papel nao aceitam '-'. Use exatamente o nome do lab (normalmente com '_')."
read -r -p "Confirmar e executar? (s/N): " CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[sSyY]$ ]] || { warn "Cancelado."; exit 0; }

gcloud config set project "$PROJECT"       >/dev/null 2>&1

# ----------------------------------------------------------------------------
# Permissoes: neste lab o aluno NAO e Owner. Ele tem projectIamAdmin, entao
# pode conceder a si mesmo os papeis que faltam (so dentro do projeto do lab).
# ----------------------------------------------------------------------------
ACCT=$(gcloud config get-value account 2>/dev/null)
MYROLES=$(gcloud projects get-iam-policy "$PROJECT" --flatten="bindings[].members" \
  --filter="bindings.members:user:$ACCT" --format="value(bindings.role)" 2>/dev/null)
info "Conta: $ACCT"
echo "   Papeis atuais: $(tr '\n' ' ' <<<"$MYROLES")"
if grep -qE "roles/(owner|editor)" <<<"$MYROLES"; then
  ok "Conta e Owner/Editor; nenhum papel extra necessario."
elif grep -q "roles/resourcemanager.projectIamAdmin" <<<"$MYROLES"; then
  NEEDED="roles/iam.roleAdmin roles/iam.serviceAccountAdmin roles/iam.serviceAccountUser roles/compute.instanceAdmin.v1"
  MISSING=""
  for R in $NEEDED; do grep -qx "$R" <<<"$MYROLES" || MISSING="$MISSING $R"; done
  if [[ -n "$MISSING" ]]; then
    warn "Faltam papeis para criar papel personalizado, conta de servico e usar SSH:"
    for R in $MISSING; do echo "     - $R"; done
    read -r -p "Conceder esses papeis a $ACCT neste projeto do lab? (s/N): " G </dev/tty
    if [[ "$G" =~ ^[sSyY]$ ]]; then
      GRANT_FAIL=0
      for R in $MISSING; do
        if gcloud projects add-iam-policy-binding "$PROJECT" --member="user:$ACCT" --role="$R" \
             --condition=None >/dev/null 2>&1; then ok "concedido $R"; else fail "falhou $R"; GRANT_FAIL=1; fi
      done
      if [[ $GRANT_FAIL == 1 ]]; then
        fail "O lab bloqueia alteracoes no IAM para esta conta."
        echo "   Sem isso nao da para criar o papel personalizado nem a conta de servico."
        echo "   O ambiente deste lab provavelmente veio com defeito: clique em"
        echo "   'Encerrar laboratorio', inicie de novo e rode este script outra vez."
        echo "   (Num lab normal a conta do aluno e Owner do projeto.)"
        exit 1
      fi
      info "Aguardando 60s para as permissoes propagarem..."; sleep 60
    else
      warn "Sem os papeis, as tarefas 1 e 2 vao falhar."
    fi
  else
    ok "Papeis necessarios ja presentes."
  fi
else
  fail "A conta nao e Owner e nao tem projectIamAdmin. Confira com 'gcloud auth list'"
  echo "   se esta usando o Username deste lab."
  read -r -p "Continuar mesmo assim? (s/N): " __c </dev/tty
  [[ "$__c" =~ ^[sSyY]$ ]] || exit 1
fi
gcloud config set compute/zone "$ZONE"     >/dev/null 2>&1
gcloud config set compute/region "$REGION" >/dev/null 2>&1

# ----------------------------------------------------------------------------
# Tarefa 1 - Papel personalizado
# ----------------------------------------------------------------------------
echo; info "TAREFA 1: criando o papel personalizado $ROLE_ID"
run gcloud iam roles create "$ROLE_ID" \
  --project="$PROJECT" \
  --title="$ROLE_ID" \
  --description="Permissoes de bucket e objetos do Cloud Storage para o cluster Orca" \
  --permissions="storage.buckets.get,storage.objects.get,storage.objects.list,storage.objects.update,storage.objects.create" \
  --stage=GA

# ----------------------------------------------------------------------------
# Tarefa 2 - Conta de servico
# ----------------------------------------------------------------------------
echo; info "TAREFA 2: criando a conta de servico $SA_NAME"
run gcloud iam service-accounts create "$SA_NAME" --display-name="$SA_NAME"
# espera a conta de servico ficar visivel para o IAM
for i in $(seq 1 12); do
  gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1 && break
  sleep 5
done

# ----------------------------------------------------------------------------
# Tarefa 3 - Vincular papeis a conta de servico
# ----------------------------------------------------------------------------
echo; info "TAREFA 3: vinculando os papeis a conta de servico"
for ROLE in roles/monitoring.viewer roles/monitoring.metricWriter roles/logging.logWriter \
            "projects/$PROJECT/roles/$ROLE_ID"; do
  for TRY in 1 2 3; do
    if gcloud projects add-iam-policy-binding "$PROJECT" \
         --member="serviceAccount:$SA_EMAIL" --role="$ROLE" --condition=None >/dev/null 2>&1; then
      ok "$ROLE"; break
    fi
    [[ $TRY == 3 ]] && fail "Nao consegui vincular $ROLE" || sleep 10
  done
done

# ----------------------------------------------------------------------------
# Tarefa 4 - Cluster GKE privado
# ----------------------------------------------------------------------------
echo; info "TAREFA 4: criando o cluster privado $CLUSTER (leva 5-10 min)"
JUMP_IP=$(gcloud compute instances describe "$JUMPHOST" --zone="$ZONE" \
  --format='value(networkInterfaces[0].networkIP)' 2>/dev/null)
NETWORK=$(gcloud compute networks subnets describe "$SUBNET" --region="$REGION" \
  --format='value(network.basename())' 2>/dev/null)
if [[ -z "$JUMP_IP" || -z "$NETWORK" ]]; then
  fail "Nao encontrei o $JUMPHOST (IP=$JUMP_IP) ou a rede da $SUBNET (rede=$NETWORK) em $ZONE/$REGION."
  fail "Confira a zona/regiao e rode de novo."; exit 1
fi
ok "IP interno do $JUMPHOST: $JUMP_IP | rede: $NETWORK"

run gcloud container clusters create "$CLUSTER" \
  --zone="$ZONE" \
  --network="$NETWORK" \
  --subnetwork="$SUBNET" \
  --service-account="$SA_EMAIL" \
  --enable-master-authorized-networks \
  --master-authorized-networks="$JUMP_IP/32" \
  --enable-ip-alias \
  --enable-private-nodes \
  --enable-private-endpoint \
  --master-ipv4-cidr="$MASTER_CIDR" \
  --num-nodes=1

# garante o IP do jumphost nas redes autorizadas (caso o cluster ja existisse)
run gcloud container clusters update "$CLUSTER" --zone="$ZONE" \
  --enable-master-authorized-networks --master-authorized-networks="$JUMP_IP/32"

# ----------------------------------------------------------------------------
# Tarefa 5 - Implantar o app a partir do jumphost
# ----------------------------------------------------------------------------
echo; info "TAREFA 5: implantando o hello-server pelo $JUMPHOST"
REMOTE_CMD=$(cat <<EOF
set -e
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo apt-get install -y -qq google-cloud-sdk-gke-gcloud-auth-plugin >/dev/null 2>&1 \
  || sudo apt-get install -y -qq google-cloud-cli-gke-gcloud-auth-plugin >/dev/null 2>&1 || true
command -v kubectl >/dev/null 2>&1 || sudo apt-get install -y -qq kubectl >/dev/null 2>&1 \
  || sudo apt-get install -y -qq google-cloud-cli-kubectl >/dev/null 2>&1 || true
grep -q USE_GKE_GCLOUD_AUTH_PLUGIN ~/.bashrc || echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
export USE_GKE_GCLOUD_AUTH_PLUGIN=True
gcloud container clusters get-credentials $CLUSTER --internal-ip --project=$PROJECT --zone $ZONE
kubectl create deployment hello-server --image=gcr.io/google-samples/hello-app:1.0 || true
kubectl expose deployment hello-server --name orca-hello-service --type LoadBalancer --port 80 --target-port 8080 || true
kubectl get deployments,services
EOF
)

SSH_OK=0
for MODE in iap direct iap; do
  if [[ $MODE == iap ]]; then
    gcloud compute ssh "$JUMPHOST" --zone="$ZONE" --quiet --tunnel-through-iap \
      --command="$REMOTE_CMD" && { SSH_OK=1; break; }
  else
    gcloud compute ssh "$JUMPHOST" --zone="$ZONE" --quiet \
      --command="$REMOTE_CMD" && { SSH_OK=1; break; }
  fi
  warn "SSH ($MODE) falhou; tentando de novo em 20s..."; sleep 20
done

echo
if [[ $SSH_OK == 1 ]]; then
  ok "Concluido! Clique em 'Verificar meu progresso' em cada tarefa do lab."
else
  fail "Nao consegui rodar a tarefa 5 pelo SSH. Faca manualmente:"
  echo "  Compute Engine > VM instances > $JUMPHOST > SSH, e cole:"
  echo "$REMOTE_CMD" | sed 's/^/    /'
fi
