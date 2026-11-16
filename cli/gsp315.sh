#!/usr/bin/env bash
# =============================================================================
#  Set Up an App Dev Environment on Google Cloud: Challenge Lab (GSP315)
#  Google Skills - skill badge "Set Up an App Dev Environment on Google Cloud"
#
#  Uso direto do GitHub (no Cloud Shell do lab):
#     bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp315.sh)
#
#  O script pede os parametros do lab (ENTER aceita o valor padrao entre [ ])
#  e executa as 4 tarefas. Confira sempre os nomes nas instrucoes do lab.
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
  local out cmd="$*"
  if out=$("$@" 2>&1); then
    ok "$(head -n1 <<<"$cmd" | cut -c1-110)"
  elif grep -qiE "already exists|alreadyExists|already own" <<<"$out"; then
    warn "ja existe -> $(head -n1 <<<"$cmd" | cut -c1-110)"
  else
    fail "$(head -n1 <<<"$cmd" | cut -c1-110)"
    { grep -E "ERROR|error" <<<"$out" || tail -n 8 <<<"$out"; } | head -n 6; return 1
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
echo "  GSP315 - Set Up an App Dev Environment on Google Cloud"
echo "=============================================================="
echo -e "${NC}"

DEF_PROJECT=$(gcloud config get-value project 2>/dev/null)
ME=$(gcloud config get-value account 2>/dev/null)
DEF_REGION=$(gcloud config get-value compute/region 2>/dev/null)
if [[ -z "$DEF_REGION" && -n "$DEF_PROJECT" ]]; then
  DEF_REGION=$(gcloud compute project-info describe --project "$DEF_PROJECT" \
    --format="value(commonInstanceMetadata.items[google-compute-default-region])" 2>/dev/null)
fi
# Usuario 2 = outro usuario com papel Viewer (o engenheiro anterior)
DEF_USER2=""
if [[ -n "$DEF_PROJECT" ]]; then
  DEF_USER2=$(gcloud projects get-iam-policy "$DEF_PROJECT" \
    --flatten="bindings[].members" --filter="bindings.role:roles/viewer" \
    --format="value(bindings.members)" 2>/dev/null | grep '^user:' | sed 's/^user://' \
    | grep -v -x "$ME" | head -n1)
fi

info "Valores das instrucoes do lab (texto de cada tarefa)"
ask PROJECT  "Project ID"                          "$DEF_PROJECT" 1
ask REGION   "Regiao"                              "${DEF_REGION:-us-central1}" 1
ask BUCKET   "Bucket (tarefa 1)"                   "${PROJECT}-bucket" 1
ask TOPIC    "Topico Pub/Sub (tarefa 2)"           "" 1
ask FUNCTION "Funcao / entry point (tarefa 3)"     "" 1
ask USER2    "E-mail do Username 2 (tarefa 4)"     "$DEF_USER2" 1
ask RUNTIME  "Runtime da funcao"                   "nodejs22"
ask IMG_URL  "Imagem de teste"                     "https://storage.googleapis.com/cloud-training/gsp315/map.jpg"

echo
echo "--------------------------------------------------------------"
echo " Projeto : $PROJECT   | Regiao: $REGION"
echo " Bucket  : $BUCKET"
echo " Topico  : $TOPIC"
echo " Funcao  : $FUNCTION ($RUNTIME)"
echo " Remover : $USER2 (papel Viewer)"
echo " Sua conta (NAO sera alterada): $ME"
echo "--------------------------------------------------------------"
if [[ "$USER2" == "$ME" ]]; then
  fail "O Username 2 e a sua propria conta! Confira o e-mail e rode de novo."; exit 1
fi
read -r -p "Confirmar e executar? (s/N): " CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[sSyY]$ ]] || { warn "Cancelado."; exit 0; }

gcloud config set project "$PROJECT"       >/dev/null 2>&1
preflight
gcloud config set compute/region "$REGION" >/dev/null 2>&1
gcloud config set functions/region "$REGION" >/dev/null 2>&1
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')

info "Ativando APIs (pode levar 1-2 min)..."
gcloud services enable run.googleapis.com cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com artifactregistry.googleapis.com \
  eventarc.googleapis.com pubsub.googleapis.com logging.googleapis.com \
  storage.googleapis.com >/dev/null 2>&1 \
  && ok "APIs ativas" || warn "Nao foi possivel ativar alguma API (pode ja estar ativa). Seguindo."

# ----------------------------------------------------------------------------
# Tarefa 1 - Bucket
# ----------------------------------------------------------------------------
echo; info "TAREFA 1: criando o bucket"
run gcloud storage buckets create "gs://$BUCKET" --location="$REGION"

# ----------------------------------------------------------------------------
# Tarefa 2 - Topico Pub/Sub
# ----------------------------------------------------------------------------
echo; info "TAREFA 2: criando o topico Pub/Sub"
run gcloud pubsub topics create "$TOPIC"

# ----------------------------------------------------------------------------
# Tarefa 3 - Cloud Run function (2a geracao) que gera miniaturas
# ----------------------------------------------------------------------------
echo; info "TAREFA 3: permissoes para o gatilho do Cloud Storage / Eventarc"
SA_GCS=$(gcloud storage service-agent --project="$PROJECT" 2>/dev/null)
SA_COMPUTE="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
SA_PUBSUB="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

bind() { gcloud projects add-iam-policy-binding "$PROJECT" --member="$1" --role="$2" \
           --condition=None >/dev/null 2>&1 && ok "$2 -> ${1#*:}" || warn "falhou: $2 -> ${1#*:}"; }
bind "serviceAccount:$SA_GCS"     roles/pubsub.publisher
bind "serviceAccount:$SA_COMPUTE" roles/eventarc.eventReceiver
bind "serviceAccount:$SA_COMPUTE" roles/run.invoker
bind "serviceAccount:$SA_PUBSUB"  roles/iam.serviceAccountTokenCreator

info "Gerando o codigo da funcao em ~/gsp315-function"
FUNC_DIR=~/gsp315-function
mkdir -p "$FUNC_DIR"

cat > "$FUNC_DIR/index.js" <<EOF
const functions = require('@google-cloud/functions-framework');
const { Storage } = require('@google-cloud/storage');
const { PubSub } = require('@google-cloud/pubsub');
const sharp = require('sharp');

functions.cloudEvent('${FUNCTION}', async cloudEvent => {
  const event = cloudEvent.data;

  console.log(\`Event: \${JSON.stringify(event)}\`);
  console.log(\`Hello \${event.bucket}\`);

  const fileName = event.name;
  const bucketName = event.bucket;
  const size = "64x64";
  const bucket = new Storage().bucket(bucketName);
  const topicName = "${TOPIC}";
  const pubsub = new PubSub();

  if (fileName.search("64x64_thumbnail") === -1) {
    // doesn't have a thumbnail, get the filename extension
    const filename_split = fileName.split('.');
    const filename_ext = filename_split[filename_split.length - 1].toLowerCase();
    const filename_without_ext = fileName.substring(0, fileName.length - filename_ext.length - 1);

    if (filename_ext === 'png' || filename_ext === 'jpg' || filename_ext === 'jpeg') {
      console.log(\`Processing Original: gs://\${bucketName}/\${fileName}\`);
      const gcsObject = bucket.file(fileName);
      const newFilename = \`\${filename_without_ext}_64x64_thumbnail.\${filename_ext}\`;
      const gcsNewObject = bucket.file(newFilename);

      try {
        const [buffer] = await gcsObject.download();
        const resizedBuffer = await sharp(buffer)
          .resize(64, 64, { fit: 'inside', withoutEnlargement: true })
          .toFormat(filename_ext)
          .toBuffer();

        await gcsNewObject.save(resizedBuffer, {
          metadata: { contentType: \`image/\${filename_ext}\` },
        });

        console.log(\`Success: \${fileName} → \${newFilename}\`);

        await pubsub
          .topic(topicName)
          .publishMessage({ data: Buffer.from(newFilename) });

        console.log(\`Message published to \${topicName}\`);
      } catch (err) {
        console.error(\`Error: \${err}\`);
      }
    } else {
      console.log(\`gs://\${bucketName}/\${fileName} is not an image I can handle\`);
    }
  } else {
    console.log(\`gs://\${bucketName}/\${fileName} already has a thumbnail\`);
  }
});
EOF

cat > "$FUNC_DIR/package.json" <<'EOF'
{
  "name": "thumbnails",
  "version": "1.0.0",
  "description": "Create Thumbnail of uploaded image",
  "scripts": {
    "start": "node index.js"
  },
  "dependencies": {
    "@google-cloud/functions-framework": "^3.0.0",
    "@google-cloud/pubsub": "^2.0.0",
    "@google-cloud/storage": "^6.11.0",
    "sharp": "^0.32.1"
  },
  "devDependencies": {},
  "engines": {
    "node": ">=4.3.2"
  }
}
EOF
ok "index.js e package.json criados (topico: $TOPIC, entry point: $FUNCTION)"

info "Implantando a funcao $FUNCTION (leva 2-4 min; tenta ate 5 vezes)"
DEPLOYED=0
for TRY in 1 2 3 4 5; do
  if gcloud functions deploy "$FUNCTION" \
      --gen2 \
      --runtime="$RUNTIME" \
      --region="$REGION" \
      --source="$FUNC_DIR" \
      --entry-point="$FUNCTION" \
      --trigger-location="$REGION" \
      --trigger-event-filters="type=google.cloud.storage.object.v1.finalized" \
      --trigger-event-filters="bucket=$BUCKET" \
      --quiet > /tmp/gsp315-deploy.log 2>&1; then
    DEPLOYED=1; ok "Funcao implantada"; break
  fi
  warn "Tentativa $TRY falhou (normal enquanto as permissoes propagam). Novo teste em 60s..."
  tail -n 3 /tmp/gsp315-deploy.log | cut -c1-200
  sleep 60
done
if [[ $DEPLOYED != 1 ]]; then
  fail "Nao foi possivel implantar. Log completo: /tmp/gsp315-deploy.log"
  fail "Rode o script de novo daqui a alguns minutos (o que ja existe e ignorado)."
fi

info "Testando: enviando a imagem para o bucket"
if curl -sL -o ~/map.jpg "$IMG_URL"; then
  run gcloud storage cp ~/map.jpg "gs://$BUCKET"
  info "Aguardando a miniatura (ate ~90s)..."
  for i in $(seq 1 9); do
    sleep 10
    if gcloud storage ls "gs://$BUCKET" 2>/dev/null | grep -q "64x64_thumbnail"; then
      ok "Miniatura gerada:"; gcloud storage ls "gs://$BUCKET"; break
    fi
  done
  gcloud storage ls "gs://$BUCKET" 2>/dev/null | grep -q "64x64_thumbnail" \
    || warn "Miniatura ainda nao apareceu. O 'Check my progress' da tarefa 3 nao depende dela; confira depois com: gcloud storage ls gs://$BUCKET"
else
  warn "Nao consegui baixar a imagem de teste. Envie qualquer JPG/PNG para gs://$BUCKET"
fi

# ----------------------------------------------------------------------------
# Tarefa 4 - Remover o engenheiro anterior (Viewer do Username 2)
# ----------------------------------------------------------------------------
echo; info "TAREFA 4: removendo o papel Viewer de $USER2"
if gcloud projects remove-iam-policy-binding "$PROJECT" \
     --member="user:$USER2" --role=roles/viewer --condition=None >/dev/null 2>&1; then
  ok "Viewer removido de $USER2"
else
  warn "Nao removi (talvez ja tenha sido removido). Confira em IAM & Admin > IAM."
fi

echo
ok "Concluido! Clique em 'Check my progress' em cada tarefa do lab."
