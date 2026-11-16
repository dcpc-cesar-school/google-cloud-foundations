#!/usr/bin/env bash
# =============================================================================
#  Configure Secure RDP using a Windows Bastion Host: Challenge Lab (GSP303)
#  Google Skills - "Cloud Architecture: Design, Implement, and Manage"
#
#  Uso direto do GitHub (no Cloud Shell do lab):
#     bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp303.sh)
#
#  Cria a VPC securenetwork + sub-rede, firewall RDP para o bastion, as VMs
#  vm-securehost e vm-bastionhost (2 NICs cada), redefine as senhas do usuario
#  app_admin e instala o IIS no vm-securehost via script de inicializacao.
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
    elif grep -qiE "already exists|alreadyExists" <<<"$out"; then
      warn "ja existe -> $(head -n1 <<<"$cmd" | cut -c1-110)"; return 0
    elif grep -qiE "PERMISSION_DENIED|not ready|resourceNotReady" <<<"$out" && [[ $try -lt 4 ]]; then
      warn "ainda nao disponivel... tentativa $try/4, aguardando 20s"; sleep 20
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
echo "  GSP303 - Configure Secure RDP using a Windows Bastion Host"
echo "=============================================================="
echo -e "${NC}"

DEF_PROJECT=$(gcloud config get-value project 2>/dev/null)
DEF_ZONE=$(gcloud config get-value compute/zone 2>/dev/null)
if [[ -z "$DEF_ZONE" && -n "$DEF_PROJECT" ]]; then
  DEF_ZONE=$(gcloud compute project-info describe --project "$DEF_PROJECT" \
    --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null)
fi

info "Valores das instrucoes do lab (Regiao e Zona aparecem depois de 'Iniciar laboratorio')"
ask PROJECT  "Project ID"                          "$DEF_PROJECT" 1
ask ZONE     "Zona"                                "${DEF_ZONE:-us-central1-a}" 1
ask REGION   "Regiao"                              "${ZONE%-*}" 1
ask VPC      "Rede VPC (tarefa 1)"                 "securenetwork"
ask SUBNET   "Sub-rede"                            "securenetwork-subnet"
ask RANGE    "Faixa da sub-rede"                   "192.168.16.0/20"
ask FW       "Firewall RDP do bastion"             "securenetwork-allow-rdp"
ask SECURE   "VM segura"                           "vm-securehost"
ask BASTION  "Bastion host"                        "vm-bastionhost"
ask MACHINE  "Tipo de maquina"                     "e2-medium"
ask WINUSER  "Usuario Windows"                     "app_admin"

echo
echo "--------------------------------------------------------------"
echo " Projeto : $PROJECT | Regiao: $REGION | Zona: $ZONE"
echo " VPC     : $VPC / $SUBNET ($RANGE)"
echo " Firewall: $FW (tcp:3389 da Internet -> tag rdp-bastion)"
echo " VMs     : $SECURE (sem IP externo) e $BASTION (IP externo), Windows Server 2016"
echo "           NIC0 = $SUBNET, NIC1 = rede default (so interna)"
echo " IIS     : instalado no $SECURE por script de inicializacao"
echo "--------------------------------------------------------------"
read -r -p "Confirmar e executar? (s/N): " CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[sSyY]$ ]] || { warn "Cancelado."; exit 0; }

gcloud config set project "$PROJECT"       >/dev/null 2>&1
gcloud config set compute/zone "$ZONE"     >/dev/null 2>&1
gcloud config set compute/region "$REGION" >/dev/null 2>&1

ACCT=$(gcloud config get-value account 2>/dev/null)
info "Conta: $ACCT"
PERMS=$(curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" \
  -H "Content-Type: application/json" \
  "https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT:testIamPermissions" \
  -d '{"permissions":["compute.networks.create","compute.firewalls.create","compute.instances.create","compute.instances.setMetadata"]}')
MISSING=0
for P in compute.networks.create compute.firewalls.create compute.instances.create compute.instances.setMetadata; do
  if grep -q "\"$P\"" <<<"$PERMS"; then ok "tem $P"; else warn "NAO tem $P"; MISSING=1; fi
done
if [[ $MISSING == 1 ]]; then
  warn "Faltam permissoes. Confira com 'gcloud auth list' se a conta e o Username deste lab."
  read -r -p "Continuar mesmo assim? (s/N): " __c </dev/tty
  [[ "$__c" =~ ^[sSyY]$ ]] || exit 1
fi

# ----------------------------------------------------------------------------
# Tarefa 1 - VPC, sub-rede e firewall RDP
# ----------------------------------------------------------------------------
echo; info "TAREFA 1: rede VPC, sub-rede e firewall"
run gcloud compute networks create "$VPC" --subnet-mode=custom
run gcloud compute networks subnets create "$SUBNET" \
  --network="$VPC" --region="$REGION" --range="$RANGE"
run gcloud compute firewall-rules create "$FW" \
  --network="$VPC" --direction=INGRESS --action=ALLOW --rules=tcp:3389 \
  --source-ranges=0.0.0.0/0 --target-tags=rdp-bastion
# RDP interno: do bastion para o host seguro, dentro da securenetwork
run gcloud compute firewall-rules create "${VPC}-allow-rdp-internal" \
  --network="$VPC" --direction=INGRESS --action=ALLOW --rules=tcp:3389 \
  --source-ranges="$RANGE" --target-tags=rdp-internal

# ----------------------------------------------------------------------------
# Tarefa 2 - VMs Windows com 2 interfaces
# ----------------------------------------------------------------------------
echo; info "TAREFA 2: criando as VMs Windows (o boot leva 3-5 min)"
IIS_PS1='Import-Module ServerManager
if (-not (Get-WindowsFeature Web-Server).Installed) {
  Install-WindowsFeature -Name Web-Server -IncludeManagementTools
}
Write-Output "IIS_STATUS: $((Get-WindowsFeature Web-Server).InstallState)"'

run gcloud compute instances create "$SECURE" \
  --zone="$ZONE" \
  --machine-type="$MACHINE" \
  --image-family=windows-2016 \
  --image-project=windows-cloud \
  --boot-disk-size=50GB \
  --tags=rdp-internal \
  --network-interface="subnet=$SUBNET,no-address" \
  --network-interface="network=default,no-address" \
  --metadata=windows-startup-script-ps1="$IIS_PS1"

run gcloud compute instances create "$BASTION" \
  --zone="$ZONE" \
  --machine-type="$MACHINE" \
  --image-family=windows-2016 \
  --image-project=windows-cloud \
  --boot-disk-size=50GB \
  --tags=rdp-bastion \
  --network-interface="subnet=$SUBNET" \
  --network-interface="network=default,no-address"

echo
warn ">>> Ja pode verificar as tarefas da VPC, sub-rede, firewall e das duas VMs. <<<"

# ----------------------------------------------------------------------------
# Senhas do usuario Windows (precisa do Windows ja inicializado)
# ----------------------------------------------------------------------------
echo; info "Redefinindo as senhas do usuario $WINUSER (aguarda o Windows inicializar)"
reset_pw() {
  local vm=$1 out
  for i in $(seq 1 20); do
    if out=$(gcloud compute reset-windows-password "$vm" --user="$WINUSER" --zone="$ZONE" --quiet 2>&1); then
      echo "$out" > "$HOME/gsp303-$vm-senha.txt"
      ok "$vm:"; echo "$out" | sed 's/^/     /'
      return 0
    fi
    warn "$vm ainda inicializando ($i/20)... nova tentativa em 30s"; sleep 30
  done
  fail "Nao consegui redefinir a senha de $vm. Tente depois:"
  echo "   gcloud compute reset-windows-password $vm --user $WINUSER --zone $ZONE"
}
reset_pw "$BASTION"
reset_pw "$SECURE"
info "Senhas salvas em ~/gsp303-<vm>-senha.txt"

# ----------------------------------------------------------------------------
# Tarefa 3 - IIS no host seguro (via script de inicializacao)
# ----------------------------------------------------------------------------
echo; info "TAREFA 3: conferindo a instalacao do IIS no $SECURE (ate ~10 min)"
IIS_OK=0
for i in $(seq 1 30); do
  if gcloud compute instances get-serial-port-output "$SECURE" --zone="$ZONE" 2>/dev/null \
       | grep -q "IIS_STATUS: Installed"; then
    IIS_OK=1; break
  fi
  sleep 20
done
if [[ $IIS_OK == 1 ]]; then
  ok "IIS instalado no $SECURE"
else
  warn "Ainda nao confirmei o IIS pelo console serial. Se a verificacao da tarefa 3"
  echo "   falhar, reinicie o $SECURE para o script rodar de novo:"
  echo "   gcloud compute instances reset $SECURE --zone $ZONE"
  echo "   ou instale manualmente via RDP (bastion -> mstsc -> IP interno do $SECURE)."
fi

BASTION_IP=$(gcloud compute instances describe "$BASTION" --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)
SECURE_IP=$(gcloud compute instances describe "$SECURE" --zone="$ZONE" \
  --format='value(networkInterfaces[0].networkIP)' 2>/dev/null)
echo
echo "--------------------------------------------------------------"
echo " Bastion (RDP externo): $BASTION_IP"
echo " Host seguro (RDP a partir do bastion): $SECURE_IP"
echo " Usuario: $WINUSER  | senhas em ~/gsp303-*-senha.txt"
echo "--------------------------------------------------------------"
ok "Concluido! Clique em 'Verificar meu progresso' em cada tarefa do lab."
