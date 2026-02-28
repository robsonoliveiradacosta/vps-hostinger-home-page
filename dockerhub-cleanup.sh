#!/bin/bash
# Deleta todas as tags do repositório no Docker Hub, mantendo as N mais recentes.
# A tag 'latest' é sempre preservada independentemente do valor de -k.
#
# Uso:
#   ./dockerhub-cleanup.sh [opções]
#
# Opções:
#   -u USUARIO    Usuário do Docker Hub (ou DOCKERHUB_USERNAME)
#   -p TOKEN      Access token do Docker Hub (ou DOCKERHUB_TOKEN)
#   -r REPO       Repositório no formato usuario/repo (padrão: robsondeveloper/home-page)
#   -k N          Número de tags recentes a manter (padrão: 5)
#   -y            Pular confirmação
#   -h            Exibir esta mensagem
#
# Pré-requisitos: curl, jq
set -euo pipefail

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------
API="https://hub.docker.com/v2"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘] ERRO: $1${NC}"; exit 1; }
step() { echo -e "\n${BOLD}── $1${NC}"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
REPO="robsondeveloper/home-page"
KEEP=5
SKIP_CONFIRM=false
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"

# ---------------------------------------------------------------------------
# Parse de argumentos
# ---------------------------------------------------------------------------
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
    exit 1
}

while getopts "u:p:r:k:yh" opt; do
    case $opt in
        u) DOCKERHUB_USERNAME="$OPTARG" ;;
        p) DOCKERHUB_TOKEN="$OPTARG" ;;
        r) REPO="$OPTARG" ;;
        k) KEEP="$OPTARG" ;;
        y) SKIP_CONFIRM=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Validações
# ---------------------------------------------------------------------------
command -v curl &>/dev/null || err "curl não está instalado."
command -v jq   &>/dev/null || err "jq não está instalado."

[[ -z "$DOCKERHUB_USERNAME" ]] && err "Usuário não informado. Use -u ou exporte DOCKERHUB_USERNAME."
[[ -z "$DOCKERHUB_TOKEN"    ]] && err "Token não informado. Use -p ou exporte DOCKERHUB_TOKEN."
[[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -gt 0 ]] || err "-k deve ser um número inteiro positivo."

# ---------------------------------------------------------------------------
# Autenticação
# ---------------------------------------------------------------------------
step "Autenticando no Docker Hub"

TOKEN=$(curl -sf -X POST "$API/users/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$DOCKERHUB_USERNAME\",\"password\":\"$DOCKERHUB_TOKEN\"}" \
    | jq -r '.token') || err "Falha ao autenticar. Verifique usuário e token."

[[ -z "$TOKEN" || "$TOKEN" == "null" ]] && err "Token JWT vazio. Credenciais inválidas?"
log "Autenticado como $DOCKERHUB_USERNAME"

# ---------------------------------------------------------------------------
# Listar todas as tags (excluindo 'latest'), ordenadas da mais recente para a mais antiga
# ---------------------------------------------------------------------------
step "Buscando tags do repositório $REPO"

TAGS_JSON=$(curl -sf \
    -H "Authorization: Bearer $TOKEN" \
    "$API/repositories/$REPO/tags/?page_size=100&ordering=-last_updated") \
    || err "Falha ao buscar tags. Verifique se o repositório '$REPO' existe."

TOTAL=$(echo "$TAGS_JSON" | jq '.count')
log "Total de tags encontradas: $TOTAL"

# Todas as tags exceto 'latest', ordenadas da mais recente para a mais antiga
ALL_TAGS=$(echo "$TAGS_JSON" | jq -r \
    '[.results[] | select(.name != "latest")]
     | sort_by(.last_updated) | reverse[]
     | "\(.name)\t\(.last_updated)"')

if [[ -z "$ALL_TAGS" ]]; then
    warn "Nenhuma tag elegível encontrada (apenas 'latest' ou repositório vazio)."
    exit 0
fi

ELIGIBLE_COUNT=$(echo "$ALL_TAGS" | wc -l)

# As N mais recentes ficam (topo da lista), o resto vai para deleção
KEEP_TAGS=$(echo "$ALL_TAGS" | head -n "$KEEP")
TO_DELETE=$(echo "$ALL_TAGS" | tail -n +"$(( KEEP + 1 ))")

# ---------------------------------------------------------------------------
# Exibir resumo
# ---------------------------------------------------------------------------
step "Resumo"

echo ""
echo -e "  Tags elegíveis (excluindo 'latest'): ${BOLD}$ELIGIBLE_COUNT${NC}"
echo -e "  Tags a manter (as $KEEP mais recentes + 'latest'):  ${GREEN}$(( $(echo "$KEEP_TAGS" | wc -l) + 1 ))${NC}"

if [[ -z "$TO_DELETE" ]]; then
    warn "Nenhuma tag para deletar — o repositório tem $ELIGIBLE_COUNT tag(s) elegível(is), limite de manutenção é $KEEP."
    exit 0
fi

DELETE_COUNT=$(echo "$TO_DELETE" | wc -l)
echo -e "  Tags a deletar:                       ${RED}$DELETE_COUNT${NC}"

# ---------------------------------------------------------------------------
# Exibir tags que serão mantidas
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}${BOLD}  Mantendo:${NC}"
printf "  ${GREEN}%-52s %s${NC}\n" "latest" "(sempre preservada)"
while IFS=$'\t' read -r tag date; do
    printf "  ${GREEN}%-52s %s${NC}\n" "$tag" "$date"
done <<< "$KEEP_TAGS"

# ---------------------------------------------------------------------------
# Exibir tags que serão deletadas
# ---------------------------------------------------------------------------
echo ""
echo -e "${RED}${BOLD}  Deletando:${NC}"
printf "  %-52s %s\n" "TAG" "ÚLTIMA ATUALIZAÇÃO"
printf "  %-52s %s\n" "$(printf '%.0s-' {1..52})" "$(printf '%.0s-' {1..25})"
while IFS=$'\t' read -r tag date; do
    printf "  %-52s %s\n" "$tag" "$date"
done <<< "$TO_DELETE"
echo ""

# ---------------------------------------------------------------------------
# Confirmação
# ---------------------------------------------------------------------------
if [[ "$SKIP_CONFIRM" == false ]]; then
    echo -e "${YELLOW}Atenção: esta operação é irreversível.${NC}"
    read -rp "Deletar $DELETE_COUNT tag(s)? [s/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Operação cancelada."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Deletar
# ---------------------------------------------------------------------------
step "Deletando tags"

SUCCESS=0
FAIL=0

while IFS=$'\t' read -r tag _date; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: Bearer $TOKEN" \
        "$API/repositories/$REPO/tags/$tag/")

    if [[ "$HTTP_STATUS" == "204" ]]; then
        log "Deletada: $tag"
        (( SUCCESS++ )) || true
    else
        warn "Falha ao deletar '$tag' (HTTP $HTTP_STATUS)"
        (( FAIL++ )) || true
    fi
done <<< "$TO_DELETE"

# ---------------------------------------------------------------------------
# Resultado
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Concluído.${NC} Deletadas: ${GREEN}$SUCCESS${NC} | Falhas: ${RED}$FAIL${NC}"
