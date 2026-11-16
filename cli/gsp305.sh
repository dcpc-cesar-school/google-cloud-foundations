#!/usr/bin/env bash
# =============================================================================
#  Scale Out and Update a Containerized Application on a Kubernetes Cluster:
#  Challenge Lab (GSP305) - "Cloud Architecture: Design, Implement, and Manage"
#
#  Uso direto do GitHub (no Cloud Shell do lab):
#     bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp305.sh)
#
#  Usa o echo-cluster ja criado pelo lab: implanta a v1 (passo inicial do lab),
#  monta e envia gcr.io/<projeto>/echo-app:v2, atualiza o deployment echo-web
#  para a v2, escala para 2 replicas e confirma a resposta pelo IP externo.
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
  elif grep -qiE "already exists|AlreadyExists" <<<"$out"; then
    warn "ja existe -> $(head -n1 <<<"$cmd" | cut -c1-110)"
  else
    fail "$(head -n1 <<<"$cmd" | cut -c1-110)"; echo "$out" | tail -n 8; return 1
  fi
}

# ----------------------------------------------------------------------------
# 0. Parametros (zona e bucket sao detectados no projeto)
# ----------------------------------------------------------------------------
echo -e "${BLUE}"
echo "=============================================================="
echo "  GSP305 - Scale Out and Update a Containerized Application"
echo "=============================================================="
echo -e "${NC}"

DEF_PROJECT=$(gcloud config get-value project 2>/dev/null)
DEF_ZONE=$(gcloud container clusters list --filter="name=echo-cluster" \
  --format="value(location)" 2>/dev/null | head -n1)
[[ -z "$DEF_ZONE" ]] && DEF_ZONE=$(gcloud config get-value compute/zone 2>/dev/null)
DEF_SRC=$(gcloud storage ls "gs://$DEF_PROJECT/echo-web-v2.tar.gz" 2>/dev/null | head -n1)
if [[ -z "$DEF_SRC" ]]; then
  for B in $(gcloud storage ls 2>/dev/null); do
    F=$(gcloud storage ls "${B}echo-web-v2.tar.gz" 2>/dev/null | head -n1)
    [[ -n "$F" ]] && { DEF_SRC=$F; break; }
  done
fi

info "Valores do lab (detectados no projeto; confira com as instrucoes)"
ask PROJECT  "Project ID"                    "$DEF_PROJECT" 1
ask ZONE     "Zona do echo-cluster"          "${DEF_ZONE:-us-central1-a}" 1
ask CLUSTER  "Cluster"                       "echo-cluster"
ask DEPLOY   "Deployment"                    "echo-web"
ask IMAGE    "Nome da imagem"                "echo-app"
ask TAG      "Nova tag"                      "v2"
ask REPLICAS "Replicas"                      "2"
ask SRC      "Arquivo do app v2"             "${DEF_SRC:-gs://$PROJECT/echo-web-v2.tar.gz}" 1

IMG="gcr.io/$PROJECT/$IMAGE:$TAG"
echo
echo "--------------------------------------------------------------"
echo " Projeto : $PROJECT | Zona: $ZONE | Cluster: $CLUSTER"
echo " Imagem  : $IMG  (fonte: $SRC)"
echo " App     : $DEPLOY -> $TAG, $REPLICAS replicas, porta 80 -> 8000"
echo "--------------------------------------------------------------"
read -r -p "Confirmar e executar? (s/N): " CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[sSyY]$ ]] || { warn "Cancelado."; exit 0; }

gcloud config set project "$PROJECT"   >/dev/null 2>&1
gcloud config set compute/zone "$ZONE" >/dev/null 2>&1

# ----------------------------------------------------------------------------
# Passo inicial do lab: cluster pronto + implantar a v1
# ----------------------------------------------------------------------------
echo; info "Aguardando o $CLUSTER ficar RUNNING..."
for i in $(seq 1 40); do
  ST=$(gcloud container clusters describe "$CLUSTER" --zone="$ZONE" --format='value(status)' 2>/dev/null)
  [[ "$ST" == "RUNNING" ]] && break
  sleep 15
done
[[ "$ST" == "RUNNING" ]] && ok "cluster RUNNING" || { fail "cluster nao esta pronto (status: ${ST:-nao encontrado})"; exit 1; }

gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE" >/dev/null 2>&1 \
  && ok "credenciais do cluster obtidas" || { fail "falha no get-credentials"; exit 1; }

info "Passo inicial do lab: implantando a v1"
if kubectl get deployment "$DEPLOY" >/dev/null 2>&1; then
  warn "deployment $DEPLOY ja existe"
else
  run kubectl create deployment "$DEPLOY" --image=gcr.io/qwiklabs-resources/echo-app:v1
fi
if kubectl get svc "$DEPLOY" >/dev/null 2>&1; then
  warn "servico $DEPLOY ja existe"
else
  run kubectl expose deployment "$DEPLOY" --type=LoadBalancer --port 80 --target-port 8000
fi

# ----------------------------------------------------------------------------
# Tarefa 1 - Build da imagem v2
# ----------------------------------------------------------------------------
echo; info "TAREFA 1: baixando o app v2 e montando $IMG"
WORK=~/gsp305-echo-web-v2
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK" || exit 1
run gcloud storage cp "$SRC" . || exit 1
tar -xzf "$(basename "$SRC")" && ok "arquivo extraido" || { fail "falha ao extrair"; exit 1; }
DOCKERFILE=$(find "$WORK" -name Dockerfile | head -n1)
[[ -z "$DOCKERFILE" ]] && { fail "Dockerfile nao encontrado."; exit 1; }
BUILD_DIR=$(dirname "$DOCKERFILE"); ok "Dockerfile em $BUILD_DIR"
docker build -t "$IMG" "$BUILD_DIR" && ok "imagem $IMG montada" || { fail "docker build falhou"; exit 1; }

# ----------------------------------------------------------------------------
# Tarefa 2 - Push para o gcr.io
# ----------------------------------------------------------------------------
echo; info "TAREFA 2: enviando a imagem para o gcr.io"
gcloud auth configure-docker gcr.io --quiet >/dev/null 2>&1
PUSHED=0
for TRY in 1 2 3; do
  docker push "$IMG" && { PUSHED=1; break; }
  warn "push falhou (tentativa $TRY/3); nova tentativa em 20s"; sleep 20
done
[[ $PUSHED == 1 ]] && ok "imagem enviada: $IMG" || { fail "nao foi possivel enviar a imagem"; exit 1; }
warn ">>> Ja pode verificar a tarefa 2 (echo-app:v2 no gcr.io). <<<"

# ----------------------------------------------------------------------------
# Tarefa 3 - Atualizar o deployment para a v2
# ----------------------------------------------------------------------------
echo; info "TAREFA 3: atualizando $DEPLOY para $TAG"
CONTAINER=$(kubectl get deployment "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].name}')
run kubectl set image deployment/"$DEPLOY" "$CONTAINER=$IMG"
kubectl rollout status deployment/"$DEPLOY" --timeout=180s || true

# ----------------------------------------------------------------------------
# Tarefa 4 - Escalar para 2 replicas
# ----------------------------------------------------------------------------
echo; info "TAREFA 4: escalando para $REPLICAS replicas"
run kubectl scale deployment "$DEPLOY" --replicas="$REPLICAS"
kubectl rollout status deployment/"$DEPLOY" --timeout=180s || true
kubectl get deployment "$DEPLOY" -o wide

# ----------------------------------------------------------------------------
# Tarefa 5 - Confirmar a resposta do app
# ----------------------------------------------------------------------------
echo; info "TAREFA 5: testando pelo IP externo"
IP=""
for i in $(seq 1 36); do
  IP=$(kubectl get svc "$DEPLOY" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [[ -n "$IP" ]] && break; sleep 5
done
if [[ -n "$IP" ]]; then
  CODE=""
  for i in $(seq 1 12); do
    CODE=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "http://$IP" || true)
    [[ "$CODE" == "200" ]] && break; sleep 10
  done
  curl -s -m 5 "http://$IP" | head -n 10 | sed 's/^/   /'
  [[ "$CODE" == "200" ]] && ok "App respondendo em http://$IP (confira a versao acima)" \
    || warn "Ainda sem HTTP 200; aguarde 1 min e rode: curl http://$IP"
else
  warn "IP externo ainda pendente; aguarde 1-2 min."
fi

echo
ok "Concluido! Clique em 'Verificar meu progresso' nas tarefas 3, 4 e 5."
