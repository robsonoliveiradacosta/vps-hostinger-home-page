# Resumo — vps-hostinger-home-page

Página pessoal estática (HTML) servida por Nginx em Docker, atrás do Traefik compartilhado da VPS. Deploy automatizado via GitHub Actions, sem acesso SSH do CI à VPS.

---

## Stack

| | |
|---|---|
| Conteúdo | `homepage.html` estático |
| Servidor | Nginx 1.30.6 Alpine (não-root, read-only) |
| HTTPS | Traefik (infra `vps-antaresprime`) + Cloudflare Origin Certificate |
| CI/CD | GitHub Actions → Docker Hub → pedido assinado ao `deploy-receiver` da VPS |
| VPS | Hostinger |

---

## Fluxo

```
push main → GitHub Actions → build imagem → push Docker Hub → POST assinado em deploy.antaresprime.com
                                                         → worker da VPS sobe a imagem → CI confere o resultado
```

```
Internet → Cloudflare → VPS:443 → Traefik (TLS) → Container:8080
                         VPS:80  → Traefik → redirect 301 HTTPS
```

---

## Arquivos principais

| Arquivo | Função |
|---|---|
| `Dockerfile` | Nginx Alpine com usuário não-root (UID 1001) |
| `nginx.conf` | HTTP na 8080 + headers de segurança (TLS fica no Traefik) |
| `.github/workflows/deploy.yml` | Pipeline de build e deploy |

O `compose.yaml` que roda na VPS fica no repo da infra (`stacks/home-page/`).

---

## HTTPS

Certificados e portas 80/443 são responsabilidade do Traefik da infra `vps-antaresprime` (repositório privado).
O compose do container (rede `proxy`, labels do Traefik) e o deploy automático também ficam lá.

---

## Secrets do GitHub necessários

`DOCKERHUB_USERNAME` · `DOCKERHUB_TOKEN` · `DEPLOY_WEBHOOK_SECRET` · `CF_ACCESS_CLIENT_ID` · `CF_ACCESS_CLIENT_SECRET`

---

## Comandos rápidos no VPS

```bash
# Status
docker ps --filter name=home_page_nginx

# Logs
docker logs -f home_page_nginx

# Reiniciar
docker restart home_page_nginx
```

> Documentação completa: [PROJECT.md](./PROJECT.md)
