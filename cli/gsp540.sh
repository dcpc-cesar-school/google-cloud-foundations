#!/usr/bin/env bash
# =============================================================================
#  Engineer AI Agents with Agent Development Kit (ADK): Challenge Lab (GSP540)
#
#  Uso direto do GitHub (no Cloud Shell do lab):
#     bash <(curl -sL https://raw.githubusercontent.com/dcpc-cesar-school/google-cloud-foundations/main/cli/gsp540.sh)
#
#  T1 instala o ADK, autentica (ADC) e baixa o adk_project
#  T2 .env + tools=[google_search] no my_google_search_agent
#  T3 adk run my_google_search_agent (pergunta sobre o cambio do Japao)
#  T4 .env + esquema CountryCapital no geo_validator e execucao programatica
#  T5 .env + reviser_agent reativado no llm_auditor
#  As conversas na interface web (adk web) das tarefas 2 e 5 sao manuais.
# =============================================================================
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[1;34m'; NC='\033[0m'
info() { echo -e "${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $*"; }
fail() { echo -e "${RED}[ERRO]${NC} $*"; }
pause() { read -r -p "$(echo -e "${YELLOW}>>${NC} $* [ENTER] ")" _ </dev/tty; }

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

# ----------------------------------------------------------------------------
# 0. Parametros
# ----------------------------------------------------------------------------
echo -e "${BLUE}"
echo "=============================================================="
echo "  GSP540 - Engineer AI Agents with ADK"
echo "=============================================================="
echo -e "${NC}"

DEF_PROJECT=$(gcloud config get-value project 2>/dev/null)
info "Valores do lab (o MODEL aparece no bloco do .env da tarefa 2)"
ask PROJECT "GOOGLE_CLOUD_PROJECT"   "$DEF_PROJECT" 1
ask MODEL   "MODEL (modelo Flash do lab)" "gemini-2.5-flash" 1
ask PROJDIR "Pasta do projeto"       "$HOME/adk_project"

echo
echo "--------------------------------------------------------------"
echo " Projeto: $PROJECT | Location: global | Modelo: $MODEL"
echo " Fonte  : gs://$PROJECT-bucket/adk_project.zip -> $PROJDIR"
echo "--------------------------------------------------------------"
read -r -p "Confirmar e executar? (s/N): " CONFIRM </dev/tty
[[ "$CONFIRM" =~ ^[sSyY]$ ]] || { warn "Cancelado."; exit 0; }
gcloud config set project "$PROJECT" >/dev/null 2>&1

# ----------------------------------------------------------------------------
# Tarefa 1 - ADK, autenticacao e codigo
# ----------------------------------------------------------------------------
echo; info "TAREFA 1: instalando o ADK"
export PATH=$PATH:"/home/${USER}/.local/bin"
grep -q '.local/bin' ~/.bashrc || echo 'export PATH=$PATH:"/home/${USER}/.local/bin"' >> ~/.bashrc
python3 -m pip install -q google-adk && ok "google-adk instalado" || { fail "falha ao instalar o google-adk"; exit 1; }

if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  ok "credenciais ADC ja configuradas"
else
  warn "Agora vem o login (ADC): responda Y, abra o link com Ctrl+clique,"
  echo "   escolha o e-mail do ESTUDANTE, clique em Permitir e cole o codigo aqui."
  gcloud auth application-default login </dev/tty || { fail "login ADC falhou"; exit 1; }
fi
gcloud auth application-default set-quota-project "$PROJECT" >/dev/null 2>&1 || true

info "Baixando o adk_project"
cd "$(dirname "$PROJDIR")" || exit 1
if [[ -d "$PROJDIR" ]]; then
  warn "$PROJDIR ja existe; mantendo (backup dos agent.py sera feito antes de editar)"
else
  gcloud storage cp "gs://$PROJECT-bucket/adk_project.zip" . && unzip -q adk_project.zip \
    && ok "adk_project extraido" || { fail "nao consegui baixar/extrair o adk_project.zip"; exit 1; }
fi
cd "$PROJDIR" || exit 1
python3 -m pip install -q -r requirements.txt && ok "requirements instalados"

write_env() {
  cat > "$1/.env" <<EOF
GOOGLE_GENAI_USE_ENTERPRISE=true
GOOGLE_CLOUD_PROJECT=$PROJECT
GOOGLE_CLOUD_LOCATION=global
MODEL=$MODEL
EOF
  ok ".env criado em $1"
}

# Editor dos agent.py (Python): faz backup, aplica, valida a sintaxe e mostra o diff
patch_agent() {   # patch_agent <arquivo> <modo>
  local f=$1 mode=$2
  [[ -f "$f" ]] || { fail "nao encontrei $f"; return 1; }
  [[ -f "$f.orig" ]] || cp "$f" "$f.orig"
  python3 - "$f" "$mode" <<'PY'
import re, sys
path, mode = sys.argv[1], sys.argv[2]
src = open(path).read()

def add_import(s, line):
    if line in s:
        return s
    lines = s.split("\n")
    last = 0
    for i, l in enumerate(lines):
        if l.startswith("import ") or l.startswith("from "):
            last = i
    lines.insert(last + 1, line)
    return "\n".join(lines)

def agent_call_span(s, name_hint=None):
    """Retorna (inicio, fim) do primeiro Agent(...)/LlmAgent(...) (opcionalmente o de name_hint)."""
    for m in re.finditer(r"\b(?:Llm)?Agent\s*\(", s):
        i = m.end(); depth = 1
        while i < len(s) and depth:
            depth += {"(": 1, ")": -1}.get(s[i], 0); i += 1
        if name_hint is None or name_hint in s[m.start():i]:
            return m.end(), i - 1
    return None

def set_kwarg(s, key, value, name_hint=None):
    span = agent_call_span(s, name_hint)
    if not span:
        raise SystemExit("Agent(...) nao encontrado")
    a, b = span
    body = s[a:b]
    pat = re.compile(r"(\n?\s*)%s\s*=\s*[^,\n]+(\([^)]*\)|\[[^\]]*\])?" % re.escape(key))
    if re.search(r"\b%s\s*=" % re.escape(key), body):
        body = re.sub(r"\b%s\s*=\s*(\[[^\]]*\]|[^,\n)]+)" % re.escape(key), "%s=%s" % (key, value), body, count=1)
    else:
        indent = re.search(r"\n(\s+)\w", body)
        ind = indent.group(1) if indent else "    "
        lines = body.rstrip().split("\n")
        for j in range(len(lines) - 1, -1, -1):
            t = lines[j].strip()
            if t and not t.startswith("#"):
                if not t.endswith(",") and not t.endswith("("):
                    lines[j] = lines[j].rstrip() + ","
                break
        tail = body[len(body.rstrip()):]
        tail = tail if "\n" in tail else "\n"
        body = "\n".join(lines) + "\n%s%s=%s," % (ind, key, value) + tail
    return s[:a] + body + s[b:]

if mode == "search":
    src = add_import(src, "from google.adk.tools import google_search")
    src = set_kwarg(src, "tools", "[google_search]")

elif mode == "geo":
    src = add_import(src, "from pydantic import BaseModel")
    if "class CountryCapital" not in src:
        # logo depois do ultimo import (o Agent pode estar dentro de uma funcao main())
        lines = src.split("\n")
        last = max(i for i, l in enumerate(lines) if l.startswith(("import ", "from ")))
        lines.insert(last + 1, "\n\nclass CountryCapital(BaseModel):\n    capital: str\n")
        src = "\n".join(lines)
    src = set_kwarg(src, "output_schema", "CountryCapital")
    src = set_kwarg(src, "disallow_transfer_to_parent", "True")
    src = set_kwarg(src, "disallow_transfer_to_peers", "True")
    if "os.getenv(\"MODEL\")" not in src and "os.getenv('MODEL')" not in src and "os.environ" not in src:
        src = add_import(src, "import os")
        src = set_kwarg(src, "model", 'os.getenv("MODEL", "%s")' % "gemini-2.5-flash")

elif mode == "auditor":
    out = []
    for l in src.split("\n"):
        if re.match(r"^\s*#\s*.*reviser", l, re.I) and re.search(r"import|reviser_agent", l):
            l = re.sub(r"^(\s*)#\s?", r"\1", l)
        out.append(l)
    src = "\n".join(out)
    m = re.search(r"sub_agents\s*=\s*\[([^\]]*)\]", src)
    if m and "reviser_agent" not in m.group(1):
        items = [x.strip() for x in m.group(1).split(",") if x.strip() and not x.strip().startswith("#")]
        items.append("reviser_agent")
        src = src[:m.start()] + "sub_agents=[%s]" % ", ".join(items) + src[m.end():]
    elif m:
        inner = re.sub(r"#\s*(reviser_agent)", r"\1", m.group(1))
        src = src[:m.start(1)] + inner + src[m.end(1):]

open(path, "w").write(src)
PY
  if python3 -m py_compile "$f" 2>/tmp/gsp540-compile.txt; then
    ok "agent.py atualizado: $f"
    diff -u "$f.orig" "$f" | grep -E '^[+-][^+-]' | sed 's/^/   /'
  else
    fail "a edicao deixou $f invalido; restaurando o original"
    cat /tmp/gsp540-compile.txt; cp "$f.orig" "$f"; return 1
  fi
}

# ----------------------------------------------------------------------------
# Tarefa 2 - Buscador de Viagens com google_search
# ----------------------------------------------------------------------------
echo; info "TAREFA 2: my_google_search_agent"
write_env my_google_search_agent
patch_agent my_google_search_agent/agent.py search

# ----------------------------------------------------------------------------
# Tarefa 4 - geo_validator com esquema JSON
# ----------------------------------------------------------------------------
echo; info "TAREFA 4 (preparo): geo_validator"
write_env geo_validator
patch_agent geo_validator/agent.py geo

# ----------------------------------------------------------------------------
# Tarefa 5 - llm_auditor com o reviser_agent
# ----------------------------------------------------------------------------
echo; info "TAREFA 5 (preparo): llm_auditor"
write_env llm_auditor
patch_agent llm_auditor/agent.py auditor

# ----------------------------------------------------------------------------
# Tarefa 2 - conversa pela interface web (manual)
# ----------------------------------------------------------------------------
echo; info "TAREFA 2: conversa no adk web (manual)"
cat <<EOF
   1) O servidor vai subir agora. Clique (Ctrl+clique) em http://127.0.0.1:8000
   (use as perguntas EM INGLES: o verificador procura palavras-chave em ingles nos logs)
   2) Selecione my_google_search_agent e pergunte:
        Tell me some of the top events happening in Tokyo in 2025.
   3) Confira que ele fez uma pesquisa e clique em 'Verificar meu progresso' (tarefa 2).
   4) Ainda no navegador, selecione llm_auditor (+ Nova sessao) e envie:
        Double check this: You can take a direct train from Hawaii to Japan.
      Confira que o critic e o reviser responderam e verifique a tarefa 5.
   5) Espere ~30s apos a ultima resposta (envio dos logs), volte aqui e pressione
      Ctrl+C para parar o servidor; o script continua.
EOF
pause "Pronto para subir o adk web?"
trap 'echo; ok "servidor parado"' INT
adk web --allow_origins "regex:https://.*\.cloudshell\.dev" || true
trap - INT

# ----------------------------------------------------------------------------
# Tarefa 3 - CLI
# ----------------------------------------------------------------------------
echo; info "TAREFA 3: conversando pela CLI (adk run)"
# a pergunta vai na hora; o "exit" so depois de 45s, para os logs chegarem ao Cloud Logging
{ printf 'What is the exchange rate of Japan?\n'; sleep 45; printf 'exit\n'; } \
  | timeout 240 adk run my_google_search_agent 2>&1 | grep -vE "UserWarning|credential_service|super\(\)" | tail -n 20 | sed 's/^/   /'
warn ">>> Verifique a tarefa 3. Se nao passar, rode 'adk run my_google_search_agent'"
echo "    e pergunte em ingles: What is the exchange rate of Japan?"

# ----------------------------------------------------------------------------
# Tarefa 4 - execucao programatica
# ----------------------------------------------------------------------------
echo; info "TAREFA 4: python3 geo_validator/agent.py"
python3 geo_validator/agent.py 2>&1 | tail -n 15 | sed 's/^/   /'
warn ">>> A saida deve ser um JSON como {\"capital\": \"Paris\"}. Verifique a tarefa 4."

echo
ok "Concluido! Backups dos originais: */agent.py.orig"
