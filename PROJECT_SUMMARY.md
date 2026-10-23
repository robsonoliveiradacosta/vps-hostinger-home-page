# Resumo — vps-hostinger-home-page

Página pessoal estática (HTML) servida por Nginx em Docker, atrás do Traefik compartilhado da VPS. Deploy automatizado via GitHub Actions.

---

## Stack

| | |
|---|---|
| Conteúdo | `homepage.html` estático |
| Servidor | Nginx 1.30.6 Alpine 3.24 (não-root, read-only) |
| HTTPS | Traefik (infra `vps-antaresprime`) + Cloudflare Origin Certificate |
| CI/CD | GitHub Actions → Docker Hub → VPS via SSH |
| VPS | Hostinger |

---

## Fluxo

```
push main → GitHub Actions → build imagem → push Docker Hub → deploy VPS via SSH
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
| `docker-compose.yml` | Serviço nginx na rede `proxy`, com labels do Traefik |
| `.github/workflows/deploy.yml` | Pipeline de build e deploy |

---

## HTTPS

Certificados e portas 80/443 são responsabilidade do Traefik da infra `vps-antaresprime` (repositório privado).
Este container só precisa da rede Docker externa `proxy` na VPS; sem ela, o deploy falha.

---

## Secrets do GitHub necessários

`DOCKERHUB_USERNAME` · `DOCKERHUB_TOKEN` · `VPS_HOST` · `VPS_USER` · `VPS_SSH_KEY`

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
