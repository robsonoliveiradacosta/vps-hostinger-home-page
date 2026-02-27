# Instalação de Certificado SSL/TLS com Let's Encrypt

Este guia descreve como habilitar HTTPS no VPS usando Let's Encrypt (Certbot),
considerando a stack atual: nginx rodando dentro de um container Docker como
usuário não-root (`appuser`, UID 1001) com sistema de arquivos somente-leitura.

---

## Pré-requisitos

- Domínio apontando para o IP do VPS (registro A no DNS configurado e propagado)
- Portas **80** e **443** abertas no firewall do VPS
- `docker` e `docker compose` instalados no VPS
- Acesso SSH ao VPS com usuário que tenha permissão `sudo`

Verificar se o domínio resolve para o IP correto antes de continuar:

```bash
dig +short seudominio.com
```

---

## Visão geral da estratégia

O Certbot será instalado **diretamente no host** do VPS (não em container).
A obtenção do certificado usa o modo **standalone**: o Certbot sobe um servidor
HTTP temporário na porta 80 para o desafio ACME, por isso o container precisa
ser parado brevemente.

Após obter o certificado, os arquivos são copiados para um diretório com
permissões adequadas para o container. Um **deploy hook** garante que isso
acontece automaticamente a cada renovação.

Fluxo final:
```
Internet → Host:443 → Container:8443 (HTTPS, nginx termina TLS)
Internet → Host:80  → Container:8080 (nginx redireciona para HTTPS)
```

---

## Passo 1 — Instalar o Certbot no host

```bash
sudo apt update
sudo apt install -y certbot
```

---

## Passo 2 — Criar diretório de certificados para o container

O container roda como UID 1001. Os certificados do Let's Encrypt são root:root
por padrão, então cria-se um diretório separado com as permissões corretas:

```bash
sudo mkdir -p /etc/home-page-certs
sudo chown root:root /etc/home-page-certs
sudo chmod 750 /etc/home-page-certs
```

---

## Passo 3 — Criar o deploy hook

O deploy hook copia os certificados para o diretório do container e reinicia
o serviço automaticamente após cada renovação.

```bash
sudo nano /etc/letsencrypt/renewal-hooks/deploy/home-page.sh
```

Conteúdo do arquivo:

```bash
#!/bin/bash
set -e

DOMAIN="seudominio.com"
DEST="/etc/home-page-certs"

cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem  $DEST/fullchain.pem
cp /etc/letsencrypt/live/$DOMAIN/privkey.pem    $DEST/privkey.pem

chmod 644 $DEST/fullchain.pem
chmod 640 $DEST/privkey.pem
chown root:root $DEST/fullchain.pem $DEST/privkey.pem

# Reinicia o container para carregar os novos certificados
cd /home/SEU_USUARIO/home-page
HOME_PAGE_IMAGE=$(docker inspect --format='{{.Config.Image}}' home_page_nginx) \
  docker compose up -d
```

> Substitua `seudominio.com` e `SEU_USUARIO` pelos valores reais.

Tornar o script executável:

```bash
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/home-page.sh
```

---

## Passo 4 — Obter o certificado

Parar o container para liberar a porta 80:

```bash
cd ~/home-page
docker compose down
```

Solicitar o certificado:

```bash
sudo certbot certonly \
  --standalone \
  --preferred-challenges http \
  -d seudominio.com \
  -d www.seudominio.com \
  --email seuemail@exemplo.com \
  --agree-tos \
  --no-eff-email
```

Executar o deploy hook manualmente para copiar os certificados já obtidos:

```bash
sudo /etc/letsencrypt/renewal-hooks/deploy/home-page.sh
```

Verificar se os arquivos foram copiados:

```bash
ls -la /etc/home-page-certs/
```

Saída esperada:
```
-rw-r--r-- root root fullchain.pem
-rw-r----- root root privkey.pem
```

---

## Passo 5 — Atualizar o Dockerfile

Expor a porta HTTPS no container:

```dockerfile
EXPOSE 8080
EXPOSE 8443
```

---

## Passo 6 — Atualizar o nginx.conf

Substituir o conteúdo completo do `nginx.conf`:

```nginx
worker_processes auto;
pid /var/run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 512;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    types_hash_max_size 2048;
    client_max_body_size 1k;

    server_tokens off;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/html text/css text/javascript application/javascript application/json image/svg+xml;

    # Redireciona HTTP → HTTPS
    server {
        listen 8080;
        server_name seudominio.com www.seudominio.com;

        return 301 https://$host$request_uri;
    }

    # HTTPS
    server {
        listen 8443 ssl;
        server_name seudominio.com www.seudominio.com;

        ssl_certificate     /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;

        root /usr/share/nginx/html;
        index homepage.html;

        expires 1h;

        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none';" always;
        add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

        location / {
            try_files $uri $uri/ =404;
        }

        location ~ /\. {
            deny all;
            access_log off;
            log_not_found off;
        }
    }
}
```

> Substitua `seudominio.com` pelo domínio real.

---

## Passo 7 — Atualizar o docker-compose.yml

Adicionar a porta 443 e o volume com os certificados:

```yaml
services:
  nginx:
    image: ${HOME_PAGE_IMAGE}
    container_name: home_page_nginx
    ports:
      - "80:8080"
      - "443:8443"
    volumes:
      - /etc/home-page-certs/fullchain.pem:/etc/nginx/certs/fullchain.pem:ro
      - /etc/home-page-certs/privkey.pem:/etc/nginx/certs/privkey.pem:ro
    restart: unless-stopped
    mem_limit: 128m
    memswap_limit: 128m
    cpus: 0.25
    read_only: true
    tmpfs:
      - /tmp
      - /var/cache/nginx:uid=1001,gid=1001
      - /var/run:uid=1001,gid=1001
      - /var/log/nginx:uid=1001,gid=1001
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

---

## Passo 8 — Fazer build e subir o container

Após salvar e commitar as alterações de `Dockerfile`, `nginx.conf` e
`docker-compose.yml`, o GitHub Actions irá gerar a nova imagem e fazer o deploy
automaticamente.

Para subir manualmente enquanto testa:

```bash
cd ~/home-page

# Construir localmente para teste
docker build -t home-page:local .

HOME_PAGE_IMAGE=home-page:local docker compose up -d
```

Verificar se o container subiu corretamente:

```bash
docker ps
docker logs home_page_nginx
```

---

## Passo 9 — Testar

```bash
# Testa HTTP → HTTPS redirect
curl -I http://seudominio.com

# Testa HTTPS
curl -I https://seudominio.com

# Verifica a validade e detalhes do certificado
echo | openssl s_client -connect seudominio.com:443 2>/dev/null | openssl x509 -noout -dates -subject
```

Testar a nota de segurança SSL: https://www.ssllabs.com/ssltest/

---

## Renovação automática

O Certbot instala automaticamente um timer systemd para renovação. Verificar:

```bash
systemctl status certbot.timer
```

Simular uma renovação para garantir que o deploy hook funciona:

```bash
sudo certbot renew --dry-run
```

O certificado é válido por **90 dias** e é renovado automaticamente quando
faltam menos de 30 dias para vencer. O deploy hook reinicia o container
após cada renovação bem-sucedida.

---

## Resolução de problemas

**Container não consegue ler os certificados:**
```bash
# Verificar permissões
ls -la /etc/home-page-certs/

# O arquivo privkey.pem precisa ser legível pelo processo nginx (UID 1001)
# Se necessário, ajustar as permissões no deploy hook
chmod 644 /etc/home-page-certs/privkey.pem
```

**Porta 80 ocupada ao rodar certbot:**
```bash
docker compose down
sudo certbot certonly --standalone -d seudominio.com
sudo /etc/letsencrypt/renewal-hooks/deploy/home-page.sh
```

**Verificar logs do nginx:**
```bash
docker logs home_page_nginx
```

**Verificar data de expiração do certificado:**
```bash
sudo certbot certificates
```
