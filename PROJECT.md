# vps-hostinger-home-page

Página pessoal estática servida por Nginx dentro de um container Docker, atrás do Traefik compartilhado da VPS (HTTPS com Cloudflare Origin Certificate). O deploy é totalmente automatizado via GitHub Actions, sem acesso SSH do CI à VPS.

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
├── dockerhub-cleanup.sh     # Apaga tags antigas no Docker Hub (manual)
├── nginx.conf               # Configuração Nginx (HTTP na 8080 + headers de segurança)
├── homepage.html            # Página HTML estática
├── PROJECT.md               # Este documento
└── PROJECT_SUMMARY.md       # Resumo do projeto
```

O `compose.yaml` que roda na VPS fica no repo da infra, em `stacks/home-page/` (junto do
`home-page.deploy.conf`, que o deploy automático lê).

---

## Container Docker

### Dockerfile

- Base: `nginx:1.30.6-alpine` (versão do nginx exata; sufixo `-alpine` sem a versão do Alpine para o Dependabot conseguir propor as próximas)
- Usuário não-root: `appuser` (UID 1001 / GID 1001)
- Porta exposta: `8080` (HTTP)
- Healthcheck via `wget http://127.0.0.1:8080/`: a cada 1s nos primeiros 30s (`--start-interval`), depois a cada 30s.
  O Traefik só roteia o container quando ele está `healthy`, então isso reduz a queda de cada deploy para ~2s.

### compose.yaml (repo da infra, `stacks/home-page/`)

- Imagem lida da variável `HOME_PAGE_IMAGE`, que o deploy grava em `/srv/apps/home-page/images.env` na VPS
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

O workflow `.github/workflows/deploy.yml` é disparado em cada push para `main`. Os deploys entram em fila:
um push novo espera o deploy em andamento terminar, nunca o cancela no meio.

### Job `build`

1. Checkout do repositório
2. Configura Docker Buildx
3. Login no Docker Hub (via secrets)
4. Build e push da imagem com uma única tag, `robsondeveloper/home-page:<git-sha>` (sem `latest`:
   o que roda na VPS é sempre um commit identificável). Cache via GitHub Actions Cache.
5. Expõe o digest da imagem publicada, que o job `deploy` compara com o que a VPS subiu.

Runner fixado em `ubuntu-24.04` e actions fixadas pelo SHA do commit, com a versão em comentário.

### Atualizações — Dependabot

`.github/dependabot.yml` abre PR semanal quando sai versão nova:

- **Actions do `deploy.yml`**: todas num PR só, já com o SHA e o comentário de versão trocados.
- **Imagem base do nginx**: só patches da linha estável (`1.30.x`). Mudar de linha (1.30 → 1.32) é manual.

Versões publicadas há menos de 7 dias esperam (cooldown) antes de virar PR. Merge do PR na `main` = deploy.

Atualização manual de uma action: pegar a tag nova no GitHub, o SHA com
`gh api repos/<dono>/<action>/commits/<tag> --jq .sha` e trocar os dois no `deploy.yml`.

### Limpeza de tags no Docker Hub — `dockerhub-cleanup.sh`

Cada push publica uma tag nova (`<git-sha>`) e nada apaga as antigas. O script, rodado à mão, apaga
as tags do repositório no Docker Hub mantendo as N mais recentes (por data de atualização):

```bash
DOCKERHUB_USERNAME=robsondeveloper DOCKERHUB_TOKEN=<token com permissão de delete> ./dockerhub-cleanup.sh -k 5
```

Mostra o que vai manter e apagar e pede confirmação (`-y` pula). Requer `curl` e `jq`.
O deploy não depende das tags antigas: a VPS guarda localmente a imagem atual e a anterior (para o
rollback), e uma VPS nova só precisa da tag do último commit da `main`.

### Job `deploy` (depende de `build`)

O CI não tem acesso à VPS. Ele pede o deploy ao `deploy-receiver` da infra e acompanha o resultado
(detalhes no README do repo `vps-antaresprime`, seção "Deploy automático"):

1. `POST https://deploy.antaresprime.com/deploy/home-page` com `{"app","sha"}`, assinado com HMAC-SHA256
   (`DEPLOY_WEBHOOK_SECRET`) e, com o Cloudflare Access ativo, com o service token (`CF_ACCESS_*`).
2. Na VPS, o worker confere que o SHA é o topo da `main`, sobe `robsondeveloper/home-page:<sha>` e espera o
   healthcheck. Se a versão nova não ficar `healthy`, volta para a anterior.
3. O job consulta `GET /status/home-page` até o resultado (até 5 min):
   - `deployed`: confere se o digest que subiu é o mesmo que o build publicou;
   - `failed`: falha com o motivo;
   - `superseded` (ou a `main` andou): termina sem erro, o deploy do commit mais novo assume.
4. Smoke test: `https://antaresprime.com/` responde 200.

---

## HTTPS e roteamento — Traefik

Este repositório não cuida de certificados. O Traefik da infra `vps-antaresprime` (repositório privado) ocupa as portas 80/443 da VPS, termina o TLS com o Cloudflare Origin Certificate (`antaresprime.com` + `*.antaresprime.com`) e encaminha para este container pelas labels do compose (`stacks/home-page/compose.yaml` na infra).

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
| `DEPLOY_WEBHOOK_SECRET` | Segredo HMAC do app `home-page`; o par fica na VPS em `/srv/deploy/secrets/home-page` |
| `CF_ACCESS_CLIENT_ID` | Service token do Cloudflare Access de `deploy.antaresprime.com` (ID) |
| `CF_ACCESS_CLIENT_SECRET` | Service token do Cloudflare Access de `deploy.antaresprime.com` (secret) |

---

## Comandos úteis no VPS

```bash
# Ver status do container
docker ps --filter name=home_page_nginx

# Ver logs em tempo real
docker logs -f home_page_nginx

# Reiniciar o container
docker restart home_page_nginx

# Refazer o deploy do último commit da main pelo mesmo caminho do CI (fila do worker)
SHA=$(git ls-remote https://github.com/robsonoliveiradacosta/vps-hostinger-home-page refs/heads/main | cut -f1)
# (grava em tmp/ e move: o worker nunca vê o arquivo pela metade)
echo "$SHA" > /srv/deploy/spool/tmp/home-page && mv /srv/deploy/spool/tmp/home-page /srv/deploy/spool/queue/
sudo journalctl -u deploy-worker -f   # acompanhar
cat /srv/deploy/status/home-page.json # resultado

# Verificar uso de recursos
docker stats home_page_nginx --no-stream

# Build e teste local da imagem (sem Traefik: publica a 8080 só para o teste)
docker build -t home-page:local .
docker run --rm -p 8080:8080 home-page:local   # http://localhost:8080
```
