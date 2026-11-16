#!/usr/bin/env bash
# =============================================================================
#  Build and Deploy a Docker Image to a Kubernetes Cluster: Challenge Lab (GSP304)
#  Google Skills - "Cloud Architecture: Design, Implement, and Manage"
#
#  Uso direto do GitHub (no Cloud Shell do lab):
#     bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp304.sh)
#
#  Cria o cluster echo-cluster (2 x e2-standard-2), monta a imagem
#  gcr.io/<projeto>/echo-app:v1 a partir de gs://<projeto>/echo-web.tar.gz,
#  envia ao gcr.io e implanta o deployment echo-web exposto na porta 80.
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
  local out cmd="$*" try
  for try in 1 2 3 4; do
    if out=$("$@" 2>&1); then
      ok "$(head -n1 <<<"$cmd" | cut -c1-110)"; return 0
    elif grep -qiE "already exists|alreadyExists|AlreadyExists" <<<"$out"; then
      warn "ja existe -> $(head -n1 <<<"$cmd" | cut -c1-110)"; return 0
    elif grep -qiE "PERMISSION_DENIED|not ready" <<<"$out" && [[ $try -lt 4 ]]; then
      warn "ainda nao disponivel... tentativa $try/4, aguardando 20s"; sleep 20
    else
      break
    fi
  done
  fail "$(head -n1 <<<"$cmd" | cut -c1-110)"
    { grep -E "ERROR|error" <<<"$out" || tail -n 8 <<<"$out"; } | head -n 6; return 1
}

# ----------------------------------------------------------------------------
# 0. Parametros
# ----------------------------------------------------------------------------
echo -e "${BLUE}"
echo "=============================================================="
echo "  GSP304 - Build and Deploy a Docker Image to Kubernetes"
echo "=============================================================="
echo -e "${NC}"

DEF_PROJECT=$(gcloud config get-value project 2>/dev/null)
DEF_ZONE=$(gcloud config get-value compute/zone 2>/dev/null)
if [[ -z "$DEF_ZONE" && -n "$DEF_PROJECT" ]]; then
  DEF_ZONE=$(gcloud compute project-info describe --project "$DEF_PROJECT" \
    --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null)
fi

info "Valores das instrucoes do lab (a zona aparece depois de 'Iniciar laboratorio')"
ask PROJECT  "Project ID"                    "$DEF_PROJECT" 1
ask ZONE     "Zona do cluster"               "${DEF_ZONE:-us-central1-a}" 1
ask CLUSTER  "Cluster"                       "echo-cluster"
ask MACHINE  "Tipo de maquina dos nos"       "e2-standard-2"
ask NODES    "Numero de nos"                 "2"
ask IMAGE    "Nome da imagem"                "echo-app"
ask TAG      "Tag da imagem"                 "v1"
ask DEPLOY   "Deployment"                    "echo-web"
ask SRC      "Arquivo do app"                "gs://$PROJECT/echo-web.tar.gz"

IMG="gcr.io/$PROJECT/$IMAGE:$TAG"
echo
echo "--------------------------------------------------------------"
echo " Projeto : $PROJECT | Zona: $ZONE"
echo " Cluster : $CLUSTER ($NODES x $MACHINE)"
echo " Imagem  : $IMG  (fonte: $SRC)"
echo " App     : deployment $DEPLOY, servico LoadBalancer 80 -> 8000"
echo "--------------------------------------------------------------"
read -r -p "Confirmar e executar? (s/N): " CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[sSyY]$ ]] || { warn "Cancelado."; exit 0; }

gcloud config set project "$PROJECT"   >/dev/null 2>&1
gcloud config set compute/zone "$ZONE" >/dev/null 2>&1

ACCT=$(gcloud config get-value account 2>/dev/null)
info "Conta: $ACCT"
info "Ativando APIs (container, artifact registry)..."
gcloud services enable container.googleapis.com artifactregistry.googleapis.com \
  containerregistry.googleapis.com >/dev/null 2>&1 \
  && ok "APIs ativas" || warn "Nao foi possivel ativar alguma API (pode ja estar ativa). Seguindo."

# ----------------------------------------------------------------------------
# Tarefa 1 - Cluster (criado em segundo plano para ganhar tempo)
# ----------------------------------------------------------------------------
echo; info "TAREFA 1: criando o cluster $CLUSTER em segundo plano (5-8 min)"
if gcloud container clusters describe "$CLUSTER" --zone="$ZONE" >/dev/null 2>&1; then
  warn "cluster $CLUSTER ja existe"
else
  run gcloud container clusters create "$CLUSTER" \
    --zone="$ZONE" \
    --num-nodes="$NODES" \
    --machine-type="$MACHINE" \
    --async
fi

# ----------------------------------------------------------------------------
# Tarefas 2 e 3 - Build da imagem e push para o gcr.io
# ----------------------------------------------------------------------------
echo; info "TAREFA 2: baixando o app e montando a imagem $IMG"
WORK=~/gsp304-echo-web
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK" || exit 1
run gcloud storage cp "$SRC" .
tar -xzf "$(basename "$SRC")" && ok "arquivo extraido" || { fail "falha ao extrair $(basename "$SRC")"; exit 1; }
DOCKERFILE=$(find "$WORK" -name Dockerfile | head -n1)
if [[ -z "$DOCKERFILE" ]]; then fail "Dockerfile nao encontrado no arquivo."; exit 1; fi
BUILD_DIR=$(dirname "$DOCKERFILE")
ok "Dockerfile em $BUILD_DIR"
grep -iE "^EXPOSE" "$DOCKERFILE" | sed 's/^/   /'

if docker build -t "$IMG" "$BUILD_DIR"; then ok "imagem $IMG montada"; else fail "docker build falhou"; exit 1; fi

echo; info "TAREFA 3: enviando a imagem para o gcr.io"
gcloud auth configure-docker gcr.io --quiet >/dev/null 2>&1
PUSHED=0
for TRY in 1 2 3; do
  if docker push "$IMG"; then PUSHED=1; break; fi
  warn "push falhou (tentativa $TRY/3); nova tentativa em 20s"; sleep 20
done
[[ $PUSHED == 1 ]] && ok "imagem enviada: $IMG" || fail "nao foi possivel enviar a imagem"
echo
warn ">>> Ja pode verificar a tarefa da imagem v1 no gcr.io. <<<"

# ----------------------------------------------------------------------------
# Tarefa 4 - Deploy no cluster
# ----------------------------------------------------------------------------
echo; info "Aguardando o cluster $CLUSTER ficar RUNNING..."
for i in $(seq 1 60); do
  ST=$(gcloud container clusters describe "$CLUSTER" --zone="$ZONE" --format='value(status)' 2>/dev/null)
  [[ "$ST" == "RUNNING" ]] && break
  sleep 15
done
[[ "$ST" == "RUNNING" ]] && ok "cluster RUNNING" || { fail "cluster nao ficou pronto (status: $ST)"; exit 1; }
warn ">>> Ja pode verificar a tarefa do cluster. <<<"

echo; info "TAREFA 4: implantando $DEPLOY"
gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE" >/dev/null 2>&1 \
  && ok "credenciais do cluster obtidas"
kubectl wait --for=condition=Ready nodes --all --timeout=300s >/dev/null 2>&1 || true
run kubectl create deployment "$DEPLOY" --image="$IMG"
run kubectl expose deployment "$DEPLOY" --type=LoadBalancer --port=80 --target-port=8000
kubectl rollout status deployment/"$DEPLOY" --timeout=180s || true

info "Aguardando o IP externo do servico (ate ~3 min)..."
IP=""
for i in $(seq 1 36); do
  IP=$(kubectl get svc "$DEPLOY" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [[ -n "$IP" ]] && break; sleep 5
done
kubectl get deploy,svc
if [[ -n "$IP" ]]; then
  for i in $(seq 1 12); do
    CODE=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "http://$IP" || true)
    [[ "$CODE" == "200" ]] && break; sleep 10
  done
  [[ "$CODE" == "200" ]] && ok "App respondendo em http://$IP" \
    || warn "IP $IP ainda sem resposta 200 (pode levar mais 1-2 min)."
else
  warn "IP externo ainda pendente; aguarde 1-2 min antes de verificar."
fi

echo
ok "Concluido! Clique em 'Verificar meu progresso' nas tarefas restantes."
