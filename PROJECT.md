# vps-hostinger-home-page

Página pessoal estática servida por Nginx dentro de um container Docker com HTTPS via Cloudflare Origin Certificate. O deploy é totalmente automatizado via GitHub Actions.

---

## Índice

1. [Visão geral](#visão-geral)
2. [Stack e arquitetura](#stack-e-arquitetura)
3. [Estrutura de arquivos](#estrutura-de-arquivos)
4. [Container Docker](#container-docker)
5. [Configuração do Nginx](#configuração-do-nginx)
6. [CI/CD — GitHub Actions](#cicd--github-actions)
7. [Certificado SSL — Cloudflare Origin Certificate](#certificado-ssl--cloudflare-origin-certificate)
8. [Segredos necessários no GitHub](#segredos-necessários-no-github)
9. [Comandos úteis no VPS](#comandos-úteis-no-vps)

---

## Visão geral

```
Internet → Cloudflare (proxy) → VPS:443 → Container:8443 (HTTPS, Nginx termina TLS)
                                 VPS:80  → Container:8080 (Nginx redireciona para HTTPS)
```

- **Domínio**: antaresprime.com
- **Imagem Docker Hub**: `robsondeveloper/home-page`
- **Certificado**: Cloudflare Origin Certificate (15 anos de validade)
- **Certs no VPS**: `/home/robson/home-page-certs/`

---

## Stack e arquitetura

| Componente | Tecnologia |
|---|---|
| Conteúdo | HTML estático (`homepage.html`) |
| Servidor web | Nginx 1.27 Alpine |
| Container runtime | Docker Compose |
| Proxy / CDN | Cloudflare |
| SSL/TLS | Cloudflare Origin Certificate |
| CI/CD | GitHub Actions |
| Registry | Docker Hub (`robsondeveloper/home-page`) |
| VPS | Hostinger |

---

## Estrutura de arquivos

```
.
├── .github/
│   └── workflows/
│       └── deploy.yml       # Pipeline CI/CD
├── Dockerfile               # Imagem Nginx Alpine com usuário não-root
├── docker-compose.yml       # Serviço nginx com volumes de certificado
├── nginx.conf               # Configuração Nginx (HTTP→HTTPS redirect + HTTPS)
├── homepage.html            # Página HTML estática
├── setup-ssl.sh             # Script para instalar os certificados no VPS
├── PROJECT.md               # Este documento
└── PROJECT_SUMMARY.md       # Resumo do projeto
```

---

## Container Docker

### Dockerfile

- Base: `nginx:1.27-alpine`
- Usuário não-root: `appuser` (UID 1001 / GID 1001)
- Portas expostas: `8080` (HTTP) e `8443` (HTTPS)
- Healthcheck via `wget --no-check-certificate https://127.0.0.1:8443/`

### docker-compose.yml

- Imagem lida da variável de ambiente `HOME_PAGE_IMAGE`
- Porta `80 → 8080` e `443 → 8443`
- Volumes somente-leitura com os certificados:
  - `/home/robson/home-page-certs/fullchain.pem → /etc/nginx/certs/fullchain.pem`
  - `/home/robson/home-page-certs/privkey.pem → /etc/nginx/certs/privkey.pem`
- Limites de recursos: 128 MB RAM, 0.25 CPU
- Sistema de arquivos somente-leitura (`read_only: true`)
- tmpfs em `/tmp`, `/var/cache/nginx`, `/var/run`, `/var/log/nginx`
- `no-new-privileges: true` + `cap_drop: ALL`
- Reinício automático: `unless-stopped`
- Logs: json-file, máx 10 MB × 3 arquivos

---

## Configuração do Nginx

### Bloco HTTP (porta 8080)

Redireciona todo tráfego HTTP para HTTPS com código 301.

### Bloco HTTPS (porta 8443)

| Configuração | Valor |
|---|---|
| Protocolos | TLSv1.2, TLSv1.3 |
| Session cache | `shared:SSL:10m` |
| Session timeout | 1 dia |
| Session tickets | desativado |
| HSTS | `max-age=63072000; includeSubDomains; preload` |
| X-Frame-Options | `SAMEORIGIN` |
| X-Content-Type-Options | `nosniff` |
| Referrer-Policy | `strict-origin-when-cross-origin` |
| CSP | `default-src 'self'` (inline style permitido) |
| Permissions-Policy | geolocation, microphone e camera bloqueados |
| Cache de conteúdo | `expires 1h` |
| Gzip | ativado para CSS, JS, JSON, SVG |
| `server_tokens` | off |
| `client_max_body_size` | 1 KB |

---

## CI/CD — GitHub Actions

O workflow `.github/workflows/deploy.yml` é disparado em cada push para `main` (com proteção de concorrência — cancela runs anteriores em andamento).

### Job `build`

1. Checkout do repositório
2. Configura Docker Buildx
3. Login no Docker Hub (via secrets)
4. Build e push da imagem com duas tags:
   - `robsondeveloper/home-page:latest`
   - `robsondeveloper/home-page:<git-sha>`
   - Cache via GitHub Actions Cache

### Job `deploy` (depende de `build`)

1. Checkout do repositório
2. Cria o diretório `~/home-page` no VPS via SSH
3. Copia o `docker-compose.yml` para o VPS via SCP
4. No VPS via SSH:
   - `docker compose pull` da imagem com a tag do commit
   - `docker compose up -d --remove-orphans`
   - `docker image prune -f`

---

## Certificado SSL — Cloudflare Origin Certificate

O certificado usado é um **Cloudflare Origin Certificate** — um certificado emitido pelo Cloudflare válido por até 15 anos, usado especificamente na conexão entre o servidor de borda do Cloudflare e o servidor de origem (VPS). O Cloudflare apresenta seu próprio certificado público aos visitantes.

### Pré-requisitos no Cloudflare

1. O domínio deve estar adicionado no Cloudflare
2. Os registros DNS devem estar com **proxy ativado** (nuvem laranja):
   - `antaresprime.com` → IP do VPS
   - `www.antaresprime.com` → IP do VPS

### Passo 1 — Configurar o modo SSL no Cloudflare

Acesse **SSL/TLS → Overview** e selecione o modo **Full (Strict)**.

> Sem isso o Cloudflare não valida o certificado de origem e a conexão pode falhar ou ficar em loop de redirecionamento.

### Passo 2 — Gerar o Origin Certificate

1. Acesse **SSL/TLS → Origin Server**
2. Clique em **Create Certificate**
3. Mantenha as opções padrão (RSA, validade de 15 anos)
4. Clique em **Create**
5. Copie o conteúdo de **Origin Certificate** e salve como `antaresprime.com.pem`
6. Copie o conteúdo de **Private Key** e salve como `antaresprime.com.key`

> A chave privada é exibida apenas uma vez. Salve imediatamente.

### Passo 3 — Enviar os arquivos para o VPS

```bash
scp antaresprime.com.pem robson@<IP_DO_VPS>:~/
scp antaresprime.com.key robson@<IP_DO_VPS>:~/
```

### Passo 4 — Executar o script de instalação no VPS

Conecte-se ao VPS via SSH e execute:

```bash
cd ~/home-page
./setup-ssl.sh -c ~/antaresprime.com.pem -k ~/antaresprime.com.key
```

O script realiza automaticamente:

| Passo | Ação |
|---|---|
| Validação | Verifica se o cert e a chave são PEM válidos e formam um par |
| Validade | Exibe a data de expiração do certificado |
| Diretório | Cria `/home/robson/home-page-certs/` com permissões corretas |
| Instalação | Copia `fullchain.pem` e `privkey.pem` para o diretório |
| Reinício | Reinicia o container `home_page_nginx` |
| Verificação | Exibe status do container e últimas linhas de log |

### Passo 5 — Verificar

```bash
# Status do container
docker ps --filter name=home_page_nginx

# Logs do Nginx
docker logs home_page_nginx

# Testar HTTPS localmente (sem validação de CA)
curl -k -I https://localhost

# Testar via domínio (Cloudflare deve apresentar certificado público válido)
curl -I https://antaresprime.com
```

### Renovação

O Cloudflare Origin Certificate tem validade de 15 anos. Não há renovação automática necessária. Caso precise renovar antes do vencimento, repita os passos 2 a 4.

### Estrutura de arquivos de certificado no VPS

```
/home/robson/home-page-certs/
├── fullchain.pem   # Cloudflare Origin Certificate (chmod 644)
└── privkey.pem     # Chave privada (chmod 644)
```

---

## Segredos necessários no GitHub

| Secret | Descrição |
|---|---|
| `DOCKERHUB_USERNAME` | Usuário do Docker Hub |
| `DOCKERHUB_TOKEN` | Access token do Docker Hub |
| `VPS_HOST` | IP ou hostname do VPS |
| `VPS_USER` | Usuário SSH no VPS (ex: `robson`) |
| `VPS_SSH_KEY` | Chave SSH privada para acesso ao VPS |

---

## Comandos úteis no VPS

```bash
# Ver status do container
docker ps --filter name=home_page_nginx

# Ver logs em tempo real
docker logs -f home_page_nginx

# Reiniciar o container
docker restart home_page_nginx

# Parar e subir manualmente (necessário ter HOME_PAGE_IMAGE definida)
cd ~/home-page
HOME_PAGE_IMAGE=robsondeveloper/home-page:latest docker compose up -d

# Verificar uso de recursos
docker stats home_page_nginx --no-stream

# Build e teste local da imagem
docker build -t home-page:local .
HOME_PAGE_IMAGE=home-page:local docker compose up -d
```
