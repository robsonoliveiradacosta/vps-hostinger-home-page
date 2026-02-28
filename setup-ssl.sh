#!/bin/bash
# Instala o Origin Certificate do Cloudflare no container home-page-nginx
#
# Pré-requisitos (passos manuais no Cloudflare):
#   1. DNS → Records: ativar proxy (nuvem laranja) em antaresprime.com e www
#   2. SSL/TLS → Overview: modo "Full (Strict)"
#   3. SSL/TLS → Origin Server → Create Certificate → copiar os dois arquivos
#   4. Enviar os arquivos para o VPS:
#        scp antaresprime.com.pem robson@VPS:~/
#        scp antaresprime.com.key robson@VPS:~/
#
# Uso:
#   ./setup-ssl.sh -c ~/antaresprime.com.pem -k ~/antaresprime.com.key [-p CAMINHO_PROJETO]
set -euo pipefail

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------
CERTS_DIR="/home/${USER}/home-page-certs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Funções utilitárias
# ---------------------------------------------------------------------------
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘] ERRO: $1${NC}"; exit 1; }
step() { echo -e "\n${BOLD}── $1${NC}"; }

usage() {
    echo "Uso: $0 -c CERT -k CHAVE [-p CAMINHO_PROJETO]"
    echo ""
    echo "  -c CERT            Caminho do arquivo de certificado (origin.pem)"
    echo "  -k CHAVE           Caminho do arquivo de chave privada (origin.key)"
    echo "  -p CAMINHO_PROJETO Caminho do projeto no VPS (padrão: diretório atual)"
    echo "  -h                 Exibir esta mensagem"
    exit 1
}

# ---------------------------------------------------------------------------
# Parse de argumentos
# ---------------------------------------------------------------------------
CERT_FILE=""
KEY_FILE=""
PROJECT_PATH="$(pwd)"

while getopts "c:k:p:h" opt; do
    case $opt in
        c) CERT_FILE="$OPTARG" ;;
        k) KEY_FILE="$OPTARG" ;;
        p) PROJECT_PATH="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

[[ -z "$CERT_FILE" ]] && { echo -e "${RED}Erro: -c CERT é obrigatório.${NC}"; usage; }
[[ -z "$KEY_FILE"  ]] && { echo -e "${RED}Erro: -k CHAVE é obrigatório.${NC}"; usage; }

# ---------------------------------------------------------------------------
# Verificações de pré-requisitos
# ---------------------------------------------------------------------------
step "Verificando pré-requisitos"

[[ $EUID -eq 0 ]] && err "Não execute como root. Use: ./setup-ssl.sh ..."

[[ -f "$CERT_FILE" ]] || err "Arquivo de certificado não encontrado: $CERT_FILE"
[[ -f "$KEY_FILE"  ]] || err "Arquivo de chave privada não encontrado: $KEY_FILE"

[[ -d "$PROJECT_PATH" ]]              || err "Diretório do projeto não encontrado: $PROJECT_PATH"
[[ -f "$PROJECT_PATH/docker-compose.yml" ]] || err "docker-compose.yml não encontrado em: $PROJECT_PATH"

command -v docker &>/dev/null || err "docker não está instalado."

# Valida se o arquivo é um certificado PEM válido
openssl x509 -noout -in "$CERT_FILE" &>/dev/null \
    || err "Arquivo de certificado inválido ou corrompido: $CERT_FILE"

# Valida se a chave privada é válida
openssl pkey -noout -in "$KEY_FILE" &>/dev/null \
    || err "Arquivo de chave privada inválido ou corrompido: $KEY_FILE"

# Valida se o certificado e a chave são um par
CERT_PUB=$(openssl x509 -noout -pubkey -in "$CERT_FILE" | md5sum)
KEY_PUB=$(openssl pkey -pubout -in "$KEY_FILE" | md5sum)
[[ "$CERT_PUB" == "$KEY_PUB" ]] \
    || err "Certificado e chave privada não correspondem ao mesmo par."

EXPIRY=$(openssl x509 -noout -enddate -in "$CERT_FILE" | cut -d= -f2)
log "Certificado válido até: $EXPIRY"

# ---------------------------------------------------------------------------
# Passo 1 — Criar diretório de certificados
# ---------------------------------------------------------------------------
step "Passo 1/3 — Criando diretório de certificados ($CERTS_DIR)"
sudo mkdir -p "$CERTS_DIR"
sudo chown "${USER}:${USER}" "$CERTS_DIR"
chmod 750 "$CERTS_DIR"
log "Diretório pronto"

# ---------------------------------------------------------------------------
# Passo 2 — Instalar certificados
# ---------------------------------------------------------------------------
step "Passo 2/3 — Instalando certificados"
# Remove caso existam como diretório (criados pelo Docker antes dos certs existirem)
[[ -d "$CERTS_DIR/fullchain.pem" ]] && sudo rm -rf "$CERTS_DIR/fullchain.pem"
[[ -d "$CERTS_DIR/privkey.pem"   ]] && sudo rm -rf "$CERTS_DIR/privkey.pem"

cp "$CERT_FILE" "$CERTS_DIR/fullchain.pem"
cp "$KEY_FILE"  "$CERTS_DIR/privkey.pem"
chmod 644 "$CERTS_DIR/fullchain.pem"
chmod 640 "$CERTS_DIR/privkey.pem"
log "Certificados instalados em $CERTS_DIR"
ls -la "$CERTS_DIR/"

# ---------------------------------------------------------------------------
# Passo 3 — Reiniciar container
# ---------------------------------------------------------------------------
step "Passo 3/3 — Reiniciando container"
cd "$PROJECT_PATH"

if docker ps -a --format '{{.Names}}' | grep -q "^home_page_nginx$"; then
    docker restart home_page_nginx
    log "Container reiniciado"
else
    warn "Container home_page_nginx não encontrado."
    warn "Faça o deploy pelo GitHub Actions e rode o script novamente para reiniciar com os certificados."
fi

# ---------------------------------------------------------------------------
# Verificação final
# ---------------------------------------------------------------------------
step "Verificação"

log "Status do container:"
docker ps --filter name=home_page_nginx --format "  ID: {{.ID}} | Status: {{.Status}} | Ports: {{.Ports}}"

log "Aguardando container inicializar..."
sleep 3

docker logs home_page_nginx --tail 5 2>&1 | sed 's/^/  /'

echo ""
echo -e "${BOLD}Setup concluído!${NC}"
echo ""
echo -e "${YELLOW}Confirme no Cloudflare:${NC}"
echo "  1. DNS → Records: nuvem laranja ativada em antaresprime.com e www"
echo "  2. SSL/TLS → Overview: modo Full (Strict)"
