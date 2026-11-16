#!/usr/bin/env bash
# =============================================================================
#  Manage Kubernetes in Google Cloud: Challenge Lab (GSP510)
#
#  Uso direto do GitHub (no Cloud Shell do lab):
#     bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp510.sh)
#
#  T1 cluster GKE (canal regular, autoscaling 2-6, 3 nos)
#  T2 Prometheus gerenciado + namespace + prometheus-test + PodMonitoring
#  T3 helloweb com imagem invalida (<todo>)
#  T4 metrica de log pod-image-errors + politica "Pod Error Alert"
#  T5 corrige a imagem do helloweb e reimplanta
#  T6 hello-app v2 no Artifact Registry + servico LoadBalancer na porta 8080
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
  elif grep -qiE "already exists|AlreadyExists|alreadyExists" <<<"$out"; then
    warn "ja existe -> $(head -n1 <<<"$cmd" | cut -c1-110)"
  else
    fail "$(head -n1 <<<"$cmd" | cut -c1-110)"
    { grep -E "ERROR|error" <<<"$out" || tail -n 8 <<<"$out"; } | head -n 6; return 1
  fi
}

# ----------------------------------------------------------------------------
# 0. Parametros (copie do bloco "Set up environment variables" do lab)
# ----------------------------------------------------------------------------
echo -e "${BLUE}"
echo "=============================================================="
echo "  GSP510 - Manage Kubernetes in Google Cloud"
echo "=============================================================="
echo -e "${NC}"

DEF_PROJECT=$(gcloud config get-value project 2>/dev/null)
DEF_ZONE=$(gcloud config get-value compute/zone 2>/dev/null)
DEF_REGION=$(gcloud config get-value compute/region 2>/dev/null)
if [[ -n "$DEF_PROJECT" ]]; then
  [[ -z "$DEF_ZONE" ]] && DEF_ZONE=$(gcloud compute project-info describe --project "$DEF_PROJECT" \
    --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null)
  [[ -z "$DEF_REGION" ]] && DEF_REGION=$(gcloud compute project-info describe --project "$DEF_PROJECT" \
    --format="value(commonInstanceMetadata.items[google-compute-default-region])" 2>/dev/null)
fi
DEF_REPO=$(gcloud artifacts repositories list --format="value(name.basename())" 2>/dev/null | head -n1)

info "Valores do lab (bloco 'Set up environment variables' e texto das tarefas)"
ask PROJECT   "PROJECT_ID"                         "$DEF_PROJECT" 1
ask CLUSTER   "CLUSTER_NAME"                       "" 1
ask ZONE      "ZONE"                               "${DEF_ZONE:-us-central1-a}" 1
ask REGION    "REGION"                             "${DEF_REGION:-${ZONE%-*}}" 1
ask NAMESPACE "NAMESPACE_NAME"                     "" 1
ask REPO      "REPO_NAME (Artifact Registry)"      "$DEF_REPO" 1
ask SERVICE   "SERVICE_NAME"                       "" 1
ask INTERVAL  "endpoints.interval (tarefa 2, ex: 30s)" "" 1

IMG_V2="$REGION-docker.pkg.dev/$PROJECT/$REPO/hello-app:v2"
echo
echo "--------------------------------------------------------------"
echo " Projeto : $PROJECT | Regiao: $REGION | Zona: $ZONE"
echo " Cluster : $CLUSTER (regular, 3 nos, autoscaling 2-6)"
echo " NS      : $NAMESPACE | Servico: $SERVICE | intervalo: $INTERVAL"
echo " Imagem  : $IMG_V2"
echo "--------------------------------------------------------------"
read -r -p "Confirmar e executar? (s/N): " CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[sSyY]$ ]] || { warn "Cancelado."; exit 0; }

gcloud config set project "$PROJECT"       >/dev/null 2>&1
gcloud config set compute/zone "$ZONE"     >/dev/null 2>&1
gcloud config set compute/region "$REGION" >/dev/null 2>&1
WORK=~/gsp510; mkdir -p "$WORK"; cd "$WORK" || exit 1

# ----------------------------------------------------------------------------
# Tarefa 1 - Cluster GKE
# ----------------------------------------------------------------------------
echo; info "TAREFA 1: criando o cluster $CLUSTER (5-10 min)"
if gcloud container clusters describe "$CLUSTER" --zone="$ZONE" >/dev/null 2>&1; then
  warn "cluster $CLUSTER ja existe"
else
  run gcloud container clusters create "$CLUSTER" \
    --zone="$ZONE" \
    --release-channel=regular \
    --num-nodes=3 \
    --enable-autoscaling --min-nodes=2 --max-nodes=6 || exit 1
fi
gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE" >/dev/null 2>&1 \
  && ok "credenciais do cluster obtidas" || { fail "falha no get-credentials"; exit 1; }
warn ">>> Ja pode verificar a tarefa 1. <<<"

# ----------------------------------------------------------------------------
# Tarefa 2 - Prometheus gerenciado
# ----------------------------------------------------------------------------
echo; info "TAREFA 2: Prometheus gerenciado, namespace e app de exemplo"
run gcloud container clusters update "$CLUSTER" --zone="$ZONE" --enable-managed-prometheus
run kubectl create namespace "$NAMESPACE"

run gcloud storage cp gs://spls/gsp510/prometheus-app.yaml .
run gcloud storage cp gs://spls/gsp510/pod-monitoring.yaml .

# preenche os <todo> pelo contexto de cada linha
awk '
  /ports:/ {inports=1}
  /<todo>/ {
    if ($0 ~ /image:/)              sub(/<todo>/, "nilebox/prometheus-example-app:latest")
    else if (inports && $0 ~ /name:/) sub(/<todo>/, "metrics")
    else if ($0 ~ /name:/)          sub(/<todo>/, "prometheus-test")
  }
  {print}' prometheus-app.yaml > prometheus-app.yaml.new && mv prometheus-app.yaml.new prometheus-app.yaml

awk -v iv="$INTERVAL" '
  /<todo>/ {
    if ($0 ~ /interval:/)                      sub(/<todo>/, iv)
    else if ($0 ~ /app.kubernetes.io\/name:/)  sub(/<todo>/, "prometheus-test")
    else if ($0 ~ /app:/)                      sub(/<todo>/, "prometheus-test")
    else if ($0 ~ /name:/)                     sub(/<todo>/, "prometheus-test")
  }
  {print}' pod-monitoring.yaml > pod-monitoring.yaml.new && mv pod-monitoring.yaml.new pod-monitoring.yaml

if grep -q "<todo>" prometheus-app.yaml pod-monitoring.yaml; then
  fail "Ainda ha <todo> nos manifestos:"; grep -n "<todo>" prometheus-app.yaml pod-monitoring.yaml
  exit 1
fi
ok "manifestos do Prometheus preenchidos"
grep -nE "image:|name:|interval:|app:" prometheus-app.yaml pod-monitoring.yaml | sed 's/^/   /'

run kubectl apply -f prometheus-app.yaml -n "$NAMESPACE"
run kubectl apply -f pod-monitoring.yaml -n "$NAMESPACE"
warn ">>> Ja pode verificar a tarefa 2. <<<"

# ----------------------------------------------------------------------------
# Tarefa 3 - Deploy do helloweb (com o erro de imagem)
# ----------------------------------------------------------------------------
echo; info "TAREFA 3: implantando o helloweb com o manifesto original"
rm -rf hello-app
run gcloud storage cp -r gs://spls/gsp510/hello-app/ .
MANIFEST=hello-app/manifests/helloweb-deployment.yaml
run kubectl apply -f "$MANIFEST" -n "$NAMESPACE"
sleep 15
kubectl get pods -n "$NAMESPACE" -l app=hello 2>/dev/null; kubectl get pods -n "$NAMESPACE" | grep -i helloweb
warn ">>> Ja pode verificar a tarefa 3 (o erro InvalidImageName e esperado). <<<"

# ----------------------------------------------------------------------------
# Tarefa 4 - Metrica de log + politica de alerta
# ----------------------------------------------------------------------------
echo; info "TAREFA 4: metrica pod-image-errors e politica 'Pod Error Alert'"
run gcloud logging metrics create pod-image-errors \
  --description="Erros de imagem nos pods" \
  --log-filter='resource.type="k8s_pod"
severity=WARNING'

cat > pod-error-alert.json <<'EOF'
{
  "displayName": "Pod Error Alert",
  "combiner": "OR",
  "enabled": true,
  "conditions": [
    {
      "displayName": "Kubernetes Pod - logging/user/pod-image-errors",
      "conditionThreshold": {
        "filter": "resource.type = \"k8s_pod\" AND metric.type = \"logging.googleapis.com/user/pod-image-errors\"",
        "aggregations": [
          {
            "alignmentPeriod": "600s",
            "perSeriesAligner": "ALIGN_COUNT",
            "crossSeriesReducer": "REDUCE_SUM"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0,
        "duration": "0s",
        "trigger": { "count": 1 }
      }
    }
  ],
  "alertStrategy": { "autoClose": "604800s" }
}
EOF
if gcloud monitoring policies list --filter='displayName="Pod Error Alert"' --format='value(name)' 2>/dev/null | grep -q .; then
  warn "politica 'Pod Error Alert' ja existe"
elif gcloud monitoring policies create --policy-from-file=pod-error-alert.json >/dev/null 2>&1 \
  || gcloud beta monitoring policies create --policy-from-file=pod-error-alert.json >/dev/null 2>&1 \
  || gcloud alpha monitoring policies create --policy-from-file=pod-error-alert.json >/dev/null 2>&1; then
  ok "politica 'Pod Error Alert' criada"
else
  fail "nao consegui criar a politica pelo gcloud. Crie no console (Monitoring > Alerting) com:"
  echo "   metrica pod-image-errors, janela 10 min, Count, Sum, Threshold > 0, sem notificacao."
fi
warn ">>> Ja pode verificar a tarefa 4. <<<"

# ----------------------------------------------------------------------------
# Tarefa 5 - Corrigir a imagem e reimplantar
# ----------------------------------------------------------------------------
echo; info "TAREFA 5: corrigindo a imagem do helloweb e reimplantando"
sed -i 's#<todo>#us-docker.pkg.dev/google-samples/containers/gke/hello-app:1.0#' "$MANIFEST"
grep -n "image:" "$MANIFEST" | sed 's/^/   /'
run kubectl delete deployment helloweb -n "$NAMESPACE" --ignore-not-found
run kubectl apply -f "$MANIFEST" -n "$NAMESPACE"
kubectl rollout status deployment/helloweb -n "$NAMESPACE" --timeout=180s || true
warn ">>> Ja pode verificar a tarefa 5. <<<"

# ----------------------------------------------------------------------------
# Tarefa 6 - hello-app v2 no Artifact Registry + servico
# ----------------------------------------------------------------------------
echo; info "TAREFA 6: montando e enviando $IMG_V2"
sed -i -E 's/(Version: )[0-9]+\.[0-9]+\.[0-9]+/\12.0.0/' hello-app/main.go
grep -n "Version:" hello-app/main.go | sed 's/^/   /'
TARGET_PORT=$(grep -iE "^EXPOSE" hello-app/Dockerfile | awk '{print $2}' | head -n1)
TARGET_PORT=${TARGET_PORT:-8080}
ok "porta do container (Dockerfile): $TARGET_PORT"

gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet >/dev/null 2>&1
docker build -t "$IMG_V2" hello-app && ok "imagem montada" || { fail "docker build falhou"; exit 1; }
PUSHED=0
for TRY in 1 2 3; do
  docker push "$IMG_V2" && { PUSHED=1; break; }
  warn "push falhou (tentativa $TRY/3); nova tentativa em 20s"; sleep 20
done
[[ $PUSHED == 1 ]] && ok "imagem enviada" || { fail "nao foi possivel enviar a imagem"; exit 1; }

CONTAINER=$(kubectl get deployment helloweb -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].name}')
run kubectl set image deployment/helloweb "$CONTAINER=$IMG_V2" -n "$NAMESPACE"
kubectl rollout status deployment/helloweb -n "$NAMESPACE" --timeout=180s || true

if kubectl get svc "$SERVICE" -n "$NAMESPACE" >/dev/null 2>&1; then
  warn "servico $SERVICE ja existe"
else
  run kubectl expose deployment helloweb -n "$NAMESPACE" --name="$SERVICE" \
    --type=LoadBalancer --port=8080 --target-port="$TARGET_PORT"
fi

info "Aguardando o IP externo do $SERVICE (ate ~3 min)..."
IP=""
for i in $(seq 1 36); do
  IP=$(kubectl get svc "$SERVICE" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [[ -n "$IP" ]] && break; sleep 5
done
if [[ -n "$IP" ]]; then
  BODY=""
  for i in $(seq 1 18); do
    BODY=$(curl -s -m 5 "http://$IP:8080" || true)
    grep -q "2.0.0" <<<"$BODY" && break; sleep 10
  done
  echo "$BODY" | sed 's/^/   /'
  grep -q "2.0.0" <<<"$BODY" && ok "Servico respondendo com a Version 2.0.0 em http://$IP:8080" \
    || warn "Ainda sem 'Version: 2.0.0'; aguarde 1-2 min e rode: curl http://$IP:8080"
else
  warn "IP externo ainda pendente; aguarde 1-2 min."
fi

echo
ok "Concluido! Clique em 'Verificar meu progresso' na tarefa 6."
