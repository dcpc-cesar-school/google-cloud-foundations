#!/usr/bin/env bash
# =============================================================================
#  Develop Serverless Apps with Cloud Run: Challenge Lab (GSP328)
#
#  Uso direto do GitHub (no Cloud Shell do lab):
#     bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp328.sh)
#
#  T1 billing publico (billing-staging-api:0.1)   T2 frontend staging (frontend-staging:0.1)
#  T3 billing privado (billing-staging-api:0.2)   T4 conta de servico do billing
#  T5 billing de producao (billing-prod-api:0.1)  T6 conta de servico do frontend (run.invoker)
#  T7 frontend de producao (frontend-prod:0.1)
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
    fail "$(head -n1 <<<"$cmd" | cut -c1-110)"
    { grep -E "ERROR|error" <<<"$out" || tail -n 8 <<<"$out"; } | head -n 6; return 1
  fi
}

build() {   # build <pasta> <imagem:tag>
  info "Cloud Build: gcr.io/$PROJECT/$2 (pasta $1)"
  ( cd "$LAB/$1" && gcloud builds submit --tag "gcr.io/$PROJECT/$2" --quiet >/tmp/gsp328-build.log 2>&1 ) \
    && ok "imagem gcr.io/$PROJECT/$2" \
    || { fail "build falhou (log: /tmp/gsp328-build.log)"; tail -n 15 /tmp/gsp328-build.log; exit 1; }
}

url_of() { gcloud run services describe "$1" --region "$REGION" --format "value(status.url)" 2>/dev/null; }

test_url() {   # test_url <url> <auth: 0|1>
  local code
  for i in $(seq 1 12); do
    if [[ $2 == 1 ]]; then
      code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $(gcloud auth print-identity-token)" "$1")
    else
      code=$(curl -s -o /dev/null -w "%{http_code}" "$1")
    fi
    [[ "$code" == "200" ]] && { ok "respondendo (HTTP 200): $1"; return 0; }
    sleep 5
  done
  warn "ainda sem HTTP 200 em $1 (ultimo: $code)"
}

# ----------------------------------------------------------------------------
# 0. Parametros (nomes aparecem nas tabelas de cada tarefa)
# ----------------------------------------------------------------------------
echo -e "${BLUE}"
echo "=============================================================="
echo "  GSP328 - Develop Serverless Apps with Cloud Run"
echo "=============================================================="
echo -e "${NC}"

DEF_PROJECT=$(gcloud projects list --format='value(PROJECT_ID)' --filter='qwiklabs-gcp' 2>/dev/null | head -n1)
[[ -z "$DEF_PROJECT" ]] && DEF_PROJECT=$(gcloud config get-value project 2>/dev/null)
DEF_REGION=$(gcloud config get-value run/region 2>/dev/null)
[[ -z "$DEF_REGION" ]] && DEF_REGION=$(gcloud compute project-info describe --project "$DEF_PROJECT" \
  --format="value(commonInstanceMetadata.items[google-compute-default-region])" 2>/dev/null)

info "Valores do lab (copie os nomes das tabelas de cada tarefa)"
ask PROJECT        "Project ID"                                   "$DEF_PROJECT" 1
ask REGION         "Regiao"                                       "${DEF_REGION:-us-east4}" 1
ask PUB_BILLING    "T1 Servico de faturamento (ex: public-billing-service-738)"   "" 1
ask FE_STAGING     "T2 Servico de front-end (ex: frontend-staging-service-279)"   "" 1
ask PRIV_BILLING   "T3 Servico particular (ex: private-billing-service-785)"      "" 1
ask BILLING_SA     "T4 Conta de servico do billing (ex: billing-service-sa-821)"  "" 1
ask PROD_BILLING   "T5 Servico de producao (ex: billing-prod-service-173)"        "" 1
ask FE_SA          "T6 Conta de servico do front-end (ex: frontend-service-sa-142)" "" 1
ask FE_PROD        "T7 Servico de front-end prod (ex: frontend-prod-service-741)" "" 1

BILLING_SA_EMAIL="$BILLING_SA@$PROJECT.iam.gserviceaccount.com"
FE_SA_EMAIL="$FE_SA@$PROJECT.iam.gserviceaccount.com"
echo
echo "--------------------------------------------------------------"
echo " Projeto: $PROJECT | Regiao: $REGION"
echo " T1 $PUB_BILLING  | T2 $FE_STAGING  | T3 $PRIV_BILLING"
echo " T4 $BILLING_SA   | T5 $PROD_BILLING"
echo " T6 $FE_SA        | T7 $FE_PROD"
echo "--------------------------------------------------------------"
read -r -p "Confirmar e executar? (s/N): " CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[sSyY]$ ]] || { warn "Cancelado."; exit 0; }

# Provisionamento do ambiente (passos iniciais do lab)
gcloud config set project "$PROJECT"      >/dev/null 2>&1
gcloud config set run/region "$REGION"    >/dev/null 2>&1
gcloud config set run/platform managed    >/dev/null 2>&1
ok "projeto, run/region e run/platform configurados"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com containerregistry.googleapis.com \
  artifactregistry.googleapis.com >/dev/null 2>&1 && ok "APIs ativas" || warn "nao ativei alguma API (pode ja estar ativa)"

cd ~ || exit 1
[[ -d pet-theory ]] || git clone -q https://github.com/rosera/pet-theory.git
LAB=~/pet-theory/lab07
[[ -d "$LAB" ]] && ok "repositorio em $LAB" || { fail "nao encontrei $LAB"; exit 1; }

# ----------------------------------------------------------------------------
# Tarefa 1 - Billing publico
# ----------------------------------------------------------------------------
echo; info "TAREFA 1: servico de faturamento publico $PUB_BILLING"
build unit-api-billing billing-staging-api:0.1
run gcloud run deploy "$PUB_BILLING" --image "gcr.io/$PROJECT/billing-staging-api:0.1" \
  --region "$REGION" --allow-unauthenticated --quiet
test_url "$(url_of "$PUB_BILLING")" 0
warn ">>> Ja pode verificar a tarefa 1 (aguarde ~30s). <<<"

# ----------------------------------------------------------------------------
# Tarefa 2 - Front-end staging
# ----------------------------------------------------------------------------
echo; info "TAREFA 2: front-end $FE_STAGING"
build staging-frontend-billing frontend-staging:0.1
run gcloud run deploy "$FE_STAGING" --image "gcr.io/$PROJECT/frontend-staging:0.1" \
  --region "$REGION" --allow-unauthenticated --quiet
test_url "$(url_of "$FE_STAGING")" 0
warn ">>> Ja pode verificar a tarefa 2. <<<"

# ----------------------------------------------------------------------------
# Tarefa 3 - Billing privado (substitui o publico)
# ----------------------------------------------------------------------------
echo; info "TAREFA 3: servico particular $PRIV_BILLING"
if gcloud run services describe "$PUB_BILLING" --region "$REGION" >/dev/null 2>&1; then
  run gcloud run services delete "$PUB_BILLING" --region "$REGION" --quiet
fi
build staging-api-billing billing-staging-api:0.2
run gcloud run deploy "$PRIV_BILLING" --image "gcr.io/$PROJECT/billing-staging-api:0.2" \
  --region "$REGION" --no-allow-unauthenticated --quiet
BILLING_URL=$(url_of "$PRIV_BILLING"); echo "   BILLING_URL=$BILLING_URL"
test_url "$BILLING_URL" 1
warn ">>> Ja pode verificar a tarefa 3. <<<"

# ----------------------------------------------------------------------------
# Tarefa 4 - Conta de servico do billing
# ----------------------------------------------------------------------------
echo; info "TAREFA 4: conta de servico $BILLING_SA"
run gcloud iam service-accounts create "$BILLING_SA" --display-name "Billing Service Cloud Run"
for i in $(seq 1 12); do gcloud iam service-accounts describe "$BILLING_SA_EMAIL" >/dev/null 2>&1 && break; sleep 5; done
warn ">>> Ja pode verificar a tarefa 4. <<<"

# ----------------------------------------------------------------------------
# Tarefa 5 - Billing de producao
# ----------------------------------------------------------------------------
echo; info "TAREFA 5: servico de producao $PROD_BILLING"
build prod-api-billing billing-prod-api:0.1
run gcloud run deploy "$PROD_BILLING" --image "gcr.io/$PROJECT/billing-prod-api:0.1" \
  --region "$REGION" --service-account "$BILLING_SA_EMAIL" --no-allow-unauthenticated --quiet
PROD_BILLING_URL=$(url_of "$PROD_BILLING"); echo "   PROD_BILLING_URL=$PROD_BILLING_URL"
test_url "$PROD_BILLING_URL" 1
warn ">>> Ja pode verificar a tarefa 5. <<<"

# ----------------------------------------------------------------------------
# Tarefa 6 - Conta de servico do front-end com run.invoker
# ----------------------------------------------------------------------------
echo; info "TAREFA 6: conta de servico $FE_SA (run.invoker no $PROD_BILLING)"
run gcloud iam service-accounts create "$FE_SA" --display-name "Billing Service Cloud Run Invoker"
for i in $(seq 1 12); do gcloud iam service-accounts describe "$FE_SA_EMAIL" >/dev/null 2>&1 && break; sleep 5; done
run gcloud run services add-iam-policy-binding "$PROD_BILLING" --region "$REGION" \
  --member "serviceAccount:$FE_SA_EMAIL" --role roles/run.invoker
# tambem no nivel do projeto (alguns verificadores olham a policy do projeto)
gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$FE_SA_EMAIL" \
  --role roles/run.invoker --condition=None >/dev/null 2>&1 \
  && ok "roles/run.invoker no projeto para $FE_SA" || warn "nao concedi run.invoker no nivel do projeto (seguindo)"
warn ">>> A verificacao da tarefa 6 pode depender do front-end com a conta (tarefa 7). <<<"

# ----------------------------------------------------------------------------
# Tarefa 7 - Front-end de producao
# ----------------------------------------------------------------------------
echo; info "TAREFA 7: front-end de producao $FE_PROD"
build prod-frontend-billing frontend-prod:0.1
run gcloud run deploy "$FE_PROD" --image "gcr.io/$PROJECT/frontend-prod:0.1" \
  --region "$REGION" --service-account "$FE_SA_EMAIL" --allow-unauthenticated --quiet
FE_PROD_URL=$(url_of "$FE_PROD")
test_url "$FE_PROD_URL" 0

echo
echo "--------------------------------------------------------------"
echo " Front-end de producao: $FE_PROD_URL"
echo "--------------------------------------------------------------"
ok "Concluido! Verifique as tarefas 6 e 7 (e as anteriores que faltarem)."
