# vps-hostinger-home-page

Página pessoal estática servida por Nginx dentro de um container Docker, atrás do Traefik compartilhado da VPS (HTTPS com Cloudflare Origin Certificate). O deploy é totalmente automatizado via GitHub Actions.

---

## Índice

1. [Visão geral](#visão-geral)
2. [Stack e arquitetura](#stack-e-arquitetura)
3. [Estrutura de arquivos](#estrutura-de-arquivos)
4. [Container Docker](#container-docker)
5. [Configuração do Nginx](#configuração-do-nginx)
6. [CI/CD — GitHub Actions](#cicd--github-actions)
7. [HTTPS e roteamento — Traefik](#https-e-roteamento--traefik)
8. [Segredos necessários no GitHub](#segredos-necessários-no-github)
9. [Comandos úteis no VPS](#comandos-úteis-no-vps)

---

## Visão geral

```
Internet → Cloudflare (proxy) → VPS:443 → Traefik (termina TLS) → Container:8080 (Nginx, HTTP)
                                 VPS:80  → Traefik → redirect 301 para HTTPS
```

- **Domínio**: antaresprime.com (e `www`)
- **Imagem Docker Hub**: `robsondeveloper/home-page`
- **TLS na origem**: Traefik da infra `vps-antaresprime` (repositório privado), compartilhado com os outros projetos da VPS

---

## Stack e arquitetura

| Componente | Tecnologia |
|---|---|
| Conteúdo | HTML estático (`homepage.html`) |
| Servidor web | Nginx 1.30.6 Alpine |
| Container runtime | Docker Compose |
| Proxy / CDN | Cloudflare |
| Reverse proxy / TLS | Traefik (infra `vps-antaresprime`) + Cloudflare Origin Certificate |
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
├── docker-compose.yml       # Serviço nginx na rede proxy, com labels do Traefik
├── nginx.conf               # Configuração Nginx (HTTP na 8080 + headers de segurança)
├── homepage.html            # Página HTML estática
├── PROJECT.md               # Este documento
└── PROJECT_SUMMARY.md       # Resumo do projeto
```

---

## Container Docker

### Dockerfile

- Base: `nginx:1.30.6-alpine` (versão do nginx exata; sufixo `-alpine` sem a versão do Alpine para o Dependabot conseguir propor as próximas)
- Usuário não-root: `appuser` (UID 1001 / GID 1001)
- Porta exposta: `8080` (HTTP)
- Healthcheck via `wget http://127.0.0.1:8080/`: a cada 1s nos primeiros 30s (`--start-interval`), depois a cada 30s.
  O Traefik só roteia o container quando ele está `healthy`, então isso reduz a queda de cada deploy para ~2s.

### docker-compose.yml

- Imagem lida da variável de ambiente `HOME_PAGE_IMAGE`
- Sem portas publicadas: o container entra na rede Docker externa `proxy`, onde o Traefik o alcança
- Labels do Traefik: router `home-page` para `antaresprime.com` e `www.antaresprime.com`, porta `8080`
- Limites de recursos: 128 MB RAM, 0.25 CPU
- Sistema de arquivos somente-leitura (`read_only: true`)
- tmpfs em `/tmp`, `/var/cache/nginx`, `/var/run`, `/var/log/nginx`
- `no-new-privileges: true` + `cap_drop: ALL`
- Reinício automático: `unless-stopped`
- Logs: json-file, máx 10 MB × 3 arquivos

---

## Configuração do Nginx

Um único servidor HTTP na porta `8080`. TLS e redirect HTTP→HTTPS ficam no Traefik; o Nginx serve o conteúdo e os headers de segurança.

| Configuração | Valor |
|---|---|
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
4. Build e push da imagem com uma única tag, `robsondeveloper/home-page:<git-sha>` (sem `latest`:
   o que roda na VPS é sempre um commit identificável). Cache via GitHub Actions Cache.

Runner fixado em `ubuntu-24.04` e actions fixadas pelo SHA do commit, com a versão em comentário.
Para atualizar uma action: pegar a tag nova no GitHub, o SHA com
`gh api repos/<dono>/<action>/commits/<tag> --jq .sha` e trocar os dois no `deploy.yml`.

### Job `deploy` (depende de `build`)

1. Checkout do repositório
2. Cria o diretório `~/home-page` no VPS via SSH
3. Copia o `docker-compose.yml` para o VPS via SCP
4. No VPS via SSH:
   - `docker compose pull` da imagem com a tag do commit
   - `docker compose up -d --remove-orphans`
   - `docker image prune -f`

---

## HTTPS e roteamento — Traefik

Este repositório não cuida de certificados. O Traefik da infra `vps-antaresprime` (repositório privado) ocupa as portas 80/443 da VPS, termina o TLS com o Cloudflare Origin Certificate (`antaresprime.com` + `*.antaresprime.com`) e encaminha para este container pelas labels do `docker-compose.yml`.

Pré-requisitos (atendidos pela infra):

- Rede Docker externa `proxy` na VPS. Sem ela, o `docker compose up` do deploy falha.
- Traefik rodando na rede `proxy`.
- Cloudflare: `antaresprime.com` e `www` com **proxy ativado** e SSL/TLS em **Full (Strict)**.

Verificar:

```bash
curl -I https://antaresprime.com
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

# Subir manualmente a imagem do último commit da main (tag = SHA do commit)
cd ~/home-page
SHA=$(git ls-remote https://github.com/robsonoliveiradacosta/vps-hostinger-home-page refs/heads/main | cut -f1)
HOME_PAGE_IMAGE=robsondeveloper/home-page:$SHA docker compose up -d

# Verificar uso de recursos
docker stats home_page_nginx --no-stream

# Build e teste local da imagem (sem Traefik: publica a 8080 só para o teste)
docker build -t home-page:local .
docker run --rm -p 8080:8080 home-page:local   # http://localhost:8080
```
