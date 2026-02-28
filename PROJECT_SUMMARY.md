# Resumo — vps-hostinger-home-page

Página pessoal estática (HTML) servida por Nginx em Docker com HTTPS via Cloudflare Origin Certificate. Deploy automatizado via GitHub Actions.

---

## Stack

| | |
|---|---|
| Conteúdo | `homepage.html` estático |
| Servidor | Nginx 1.27 Alpine (não-root, read-only) |
| SSL | Cloudflare Origin Certificate |
| CI/CD | GitHub Actions → Docker Hub → VPS via SSH |
| VPS | Hostinger |

---

## Fluxo

```
push main → GitHub Actions → build imagem → push Docker Hub → deploy VPS via SSH
```

```
Internet → Cloudflare → VPS:443 → Container:8443
                         VPS:80  → redirect 301 HTTPS
```

---

## Arquivos principais

| Arquivo | Função |
|---|---|
| `Dockerfile` | Nginx Alpine com usuário não-root (UID 1001) |
| `nginx.conf` | HTTP→HTTPS redirect + TLS + headers de segurança |
| `docker-compose.yml` | Serviço nginx com volumes de certificado |
| `.github/workflows/deploy.yml` | Pipeline de build e deploy |
| `setup-ssl.sh` | Script para instalar certificados no VPS |

---

## Habilitar certificado SSL no VPS

### 1. Cloudflare — configurar proxy e modo SSL

- **DNS → Records**: ativar nuvem laranja (proxy) em `antaresprime.com` e `www`
- **SSL/TLS → Overview**: selecionar modo **Full (Strict)**

### 2. Cloudflare — gerar Origin Certificate

- **SSL/TLS → Origin Server → Create Certificate**
- Salvar os arquivos gerados:
  - `antaresprime.com.pem` (certificado)
  - `antaresprime.com.key` (chave privada — exibida apenas uma vez)

### 3. Enviar arquivos para o VPS

```bash
scp antaresprime.com.pem robson@<IP_VPS>:~/
scp antaresprime.com.key robson@<IP_VPS>:~/
```

### 4. Instalar no VPS

```bash
cd ~/home-page
./setup-ssl.sh -c ~/antaresprime.com.pem -k ~/antaresprime.com.key
```

O script valida o par cert/chave, copia para `/home/robson/home-page-certs/` e reinicia o container.

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
