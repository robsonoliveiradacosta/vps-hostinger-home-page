#!/bin/bash
# Setup SSL/TLS com Let's Encrypt para o container home-page-nginx
# Executar no VPS com: sudo ./setup-ssl.sh -d example.com -e admin@example.com
set -euo pipefail

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------
CERTS_DIR="/etc/home-page-certs"
HOOK_PATH="/etc/letsencrypt/renewal-hooks/deploy/home-page.sh"

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
    echo "Uso: sudo $0 -d DOMÍNIO -e EMAIL [-p CAMINHO_PROJETO] [-w]"
    echo ""
    echo "  -d DOMÍNIO         Domínio principal (ex: example.com)"
    echo "  -e EMAIL           Email para notificações do Let's Encrypt"
    echo "  -p CAMINHO_PROJETO Caminho do projeto no VPS (padrão: diretório atual)"
    echo "  -w                 Incluir www.DOMÍNIO no certificado (padrão: sim)"
    echo "  -h                 Exibir esta mensagem"
    exit 1
}

# ---------------------------------------------------------------------------
# Parse de argumentos
# ---------------------------------------------------------------------------
DOMAIN=""
EMAIL=""
PROJECT_PATH="$(pwd)"
INCLUDE_WWW=true

while getopts "d:e:p:wh" opt; do
    case $opt in
        d) DOMAIN="$OPTARG" ;;
        e) EMAIL="$OPTARG" ;;
        p) PROJECT_PATH="$OPTARG" ;;
        w) INCLUDE_WWW=false ;;
        h) usage ;;
        *) usage ;;
    esac
done

[[ -z "$DOMAIN" ]] && { echo -e "${RED}Erro: -d DOMÍNIO é obrigatório.${NC}"; usage; }
[[ -z "$EMAIL" ]] && { echo -e "${RED}Erro: -e EMAIL é obrigatório.${NC}"; usage; }

# ---------------------------------------------------------------------------
# Verificações de pré-requisitos
# ---------------------------------------------------------------------------
step "Verificando pré-requisitos"

[[ $EUID -ne 0 ]] && err "Execute este script como root: sudo $0 ..."

command -v docker &>/dev/null  || err "docker não está instalado."
command -v dig    &>/dev/null  || apt-get install -y -qq dnsutils > /dev/null

[[ -d "$PROJECT_PATH" ]] || err "Diretório do projeto não encontrado: $PROJECT_PATH"
[[ -f "$PROJECT_PATH/docker-compose.yml" ]] || err "docker-compose.yml não encontrado em: $PROJECT_PATH"

# Verifica se o domínio aponta para este VPS
VPS_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null \
         || curl -s --max-time 5 ipinfo.io/ip 2>/dev/null \
         || echo "desconhecido")
RESOLVED_IP=$(dig +short "$DOMAIN" | tail -1)

if [[ "$RESOLVED_IP" != "$VPS_IP" ]]; then
    warn "DNS: $DOMAIN → $RESOLVED_IP | IP deste VPS: $VPS_IP"
    warn "O DNS pode não ter propagado ainda. O Certbot pode falhar."
    read -rp "Continuar mesmo assim? [s/N] " yn
    [[ "${yn,,}" != "s" ]] && exit 1
else
    log "DNS ok: $DOMAIN → $RESOLVED_IP"
fi

# ---------------------------------------------------------------------------
# Passo 1 — Instalar Certbot
# ---------------------------------------------------------------------------
step "Passo 1/5 — Instalando Certbot"
apt-get update -qq
apt-get install -y certbot
log "Certbot instalado: $(certbot --version 2>&1)"

# ---------------------------------------------------------------------------
# Passo 2 — Criar diretório de certificados para o container
# ---------------------------------------------------------------------------
step "Passo 2/5 — Criando diretório de certificados ($CERTS_DIR)"
mkdir -p "$CERTS_DIR"
chown root:root "$CERTS_DIR"
chmod 750 "$CERTS_DIR"
log "Diretório criado com permissões 750"

# ---------------------------------------------------------------------------
# Passo 3 — Criar deploy hook
# ---------------------------------------------------------------------------
step "Passo 3/5 — Criando deploy hook"
mkdir -p "$(dirname "$HOOK_PATH")"

cat > "$HOOK_PATH" << HOOK
#!/bin/bash
set -e

DOMAIN="${DOMAIN}"
DEST="${CERTS_DIR}"

cp /etc/letsencrypt/live/\$DOMAIN/fullchain.pem  "\$DEST/fullchain.pem"
cp /etc/letsencrypt/live/\$DOMAIN/privkey.pem    "\$DEST/privkey.pem"

chmod 644 "\$DEST/fullchain.pem"
chmod 640 "\$DEST/privkey.pem"
chown root:root "\$DEST/fullchain.pem" "\$DEST/privkey.pem"

# Reinicia o container carregando os novos certificados
cd "${PROJECT_PATH}"
HOME_PAGE_IMAGE=\$(docker inspect --format='{{.Config.Image}}' home_page_nginx 2>/dev/null || echo "home-page:latest") \
  docker compose up -d
HOOK

chmod +x "$HOOK_PATH"
log "Deploy hook criado em $HOOK_PATH"

# ---------------------------------------------------------------------------
# Passo 4 — Parar container e obter certificado
# ---------------------------------------------------------------------------
step "Passo 4/5 — Obtendo certificado SSL"

log "Parando container para liberar porta 80..."
cd "$PROJECT_PATH"
docker compose down 2>/dev/null || true

# Monta os domínios para o certbot
CERTBOT_DOMAINS="-d $DOMAIN"
if [[ "$INCLUDE_WWW" == true ]]; then
    CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d www.$DOMAIN"
fi

certbot certonly \
    --standalone \
    --preferred-challenges http \
    $CERTBOT_DOMAINS \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email

log "Certificado obtido com sucesso"

# ---------------------------------------------------------------------------
# Passo 5 — Executar deploy hook para copiar certificados
# ---------------------------------------------------------------------------
step "Passo 5/5 — Copiando certificados e subindo container"
bash "$HOOK_PATH"

log "Certificados copiados para $CERTS_DIR"
ls -la "$CERTS_DIR/"

# ---------------------------------------------------------------------------
# Verificação final
# ---------------------------------------------------------------------------
step "Verificação"

log "Status do container:"
docker ps --filter name=home_page_nginx --format "  ID: {{.ID}} | Status: {{.Status}} | Ports: {{.Ports}}"

log "Aguardando container inicializar..."
sleep 3

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$DOMAIN" 2>/dev/null || echo "erro")
HTTPS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$DOMAIN" 2>/dev/null || echo "erro")

echo "  HTTP  → $HTTP_STATUS"
echo "  HTTPS → $HTTPS_STATUS"

CERT_EXPIRY=$(echo | openssl s_client -connect "$DOMAIN:443" 2>/dev/null \
              | openssl x509 -noout -enddate 2>/dev/null \
              | cut -d= -f2 || echo "não disponível")
echo "  Validade do certificado: $CERT_EXPIRY"

# ---------------------------------------------------------------------------
# Próximos passos
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Setup concluído!${NC}"
echo ""
echo -e "${YELLOW}Atenção — os arquivos do projeto ainda precisam ser atualizados:${NC}"
echo "  1. nginx.conf    → adicionar server HTTPS (porta 8443) + redirect HTTP→HTTPS"
echo "  2. Dockerfile    → expor porta 8443"
echo "  3. docker-compose.yml → adicionar porta 443:8443 e volumes de certificados"
echo ""
echo "  Consulte o SSL_SETUP.md (passos 5, 6 e 7) para os conteúdos exatos."
echo "  Após commitar e fazer push, o GitHub Actions irá rebuildar e reimplantar."
echo ""
echo -e "${BOLD}Renovação automática:${NC}"
echo "  systemctl status certbot.timer     # verificar timer"
echo "  sudo certbot renew --dry-run       # simular renovação"
