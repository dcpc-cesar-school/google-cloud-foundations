#!/usr/bin/env bash
# =============================================================================
#  Deploy and Troubleshoot a Website: Challenge Lab (GSP101)
#  Google Skills - "Cloud Architecture: Design, Implement, and Manage"
#
#  Uso direto do GitHub (no Cloud Shell do lab):
#     bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp101.sh)
#
#  Cria a VM Linux com o nome do lab, libera HTTP (tag + firewall), instala o
#  Apache com a pagina "Hello World!" e testa pelo IP externo.
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
  fail "$(head -n1 <<<"$cmd" | cut -c1-110)"
    { grep -E "ERROR|error" <<<"$out" || tail -n 8 <<<"$out"; } | head -n 6; return 1
}

# ----------------------------------------------------------------------------
# 0. Parametros
# ----------------------------------------------------------------------------
echo -e "${BLUE}"
echo "=============================================================="
echo "  GSP101 - Deploy and Troubleshoot a Website"
echo "=============================================================="
echo -e "${NC}"

DEF_PROJECT=$(gcloud config get-value project 2>/dev/null)
DEF_ZONE=$(gcloud config get-value compute/zone 2>/dev/null)
if [[ -z "$DEF_ZONE" && -n "$DEF_PROJECT" ]]; then
  DEF_ZONE=$(gcloud compute project-info describe --project "$DEF_PROJECT" \
    --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null)
fi

info "Valores das instrucoes do lab (nome da VM e zona aparecem na tarefa 1)"
ask PROJECT  "Project ID"                    "$DEF_PROJECT" 1
ask VM       "Nome da VM (tarefa 1)"         "" 1
ask ZONE     "Zona"                          "${DEF_ZONE:-us-central1-a}" 1
ask MACHINE  "Tipo de maquina"               "e2-medium"
ask FW       "Regra de firewall HTTP"        "allow-http"

echo
echo "--------------------------------------------------------------"
echo " Projeto : $PROJECT | Zona: $ZONE"
echo " VM      : $VM ($MACHINE, Debian 12, tag http-server)"
echo " Firewall: $FW (tcp:80 de qualquer origem -> tag http-server)"
echo " Site    : Apache2 com a pagina 'Hello World!'"
echo "--------------------------------------------------------------"
read -r -p "Confirmar e executar? (s/N): " CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[sSyY]$ ]] || { warn "Cancelado."; exit 0; }

gcloud config set project "$PROJECT"   >/dev/null 2>&1
gcloud config set compute/zone "$ZONE" >/dev/null 2>&1

# ----------------------------------------------------------------------------
# Tarefas 1 e 2 - VM Linux com acesso publico HTTP
# ----------------------------------------------------------------------------
echo; info "TAREFAS 1 e 2: criando a VM $VM e liberando HTTP"
STARTUP='#!/bin/bash
for i in $(seq 1 30); do apt-get update && apt-get install -y apache2 && break; sleep 10; done
echo "Hello World!" > /var/www/html/index.html
systemctl enable --now apache2'

run gcloud compute instances create "$VM" \
  --zone="$ZONE" \
  --machine-type="$MACHINE" \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --tags=http-server \
  --metadata=startup-script="$STARTUP"
# garante a tag mesmo se a VM ja existia
gcloud compute instances add-tags "$VM" --zone="$ZONE" --tags=http-server >/dev/null 2>&1 || true

run gcloud compute firewall-rules create "$FW" \
  --network=default \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:80 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=http-server
warn ">>> Ja pode verificar a tarefa 'instancia + regras de firewall'. <<<"

# ----------------------------------------------------------------------------
# Tarefas 3 e 4 - Apache e teste
# ----------------------------------------------------------------------------
echo; info "TAREFAS 3 e 4: aguardando o Apache servir 'Hello World!' (ate ~4 min)"
IP=$(gcloud compute instances describe "$VM" --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)
echo "   IP externo: $IP"
UP=0
for i in $(seq 1 24); do
  BODY=$(curl -s -m 5 "http://$IP" || true)
  grep -q "Hello World" <<<"$BODY" && { UP=1; break; }
  sleep 10
done
if [[ $UP == 1 ]]; then
  ok "Site respondendo em http://$IP -> $BODY"
else
  warn "Ainda sem 'Hello World!' em http://$IP. Se a VM ja existia antes do script,"
  echo "   o script de inicializacao pode nao ter rodado. Reinicie a VM com:"
  echo "   gcloud compute instances reset $VM --zone=$ZONE"
fi

echo
ok "Concluido! Clique em 'Verificar meu progresso' nas tarefas 3 e 4."
