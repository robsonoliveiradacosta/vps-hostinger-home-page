# Copiar o script para o VPS (ou já estará lá via deploy)
sudo ./setup-ssl.sh -d seudominio.com -e seuemail@exemplo.com -p /home/usuario/home-page

O que o script faz automaticamente:

┌───────┬──────────────────────────────────────────────────────────────┐                 
│ Passo │                             Ação                             │                 
├───────┼──────────────────────────────────────────────────────────────┤                 
│ 1     │ Instala o Certbot via apt                                    │                 
├───────┼──────────────────────────────────────────────────────────────┤                 
│ 2     │ Cria /etc/home-page-certs com permissões corretas            │                 
├───────┼──────────────────────────────────────────────────────────────┤
│ 3     │ Cria o deploy hook em /etc/letsencrypt/renewal-hooks/deploy/ │
├───────┼──────────────────────────────────────────────────────────────┤
│ 4     │ Para o container, obtém o certificado via modo standalone    │
├───────┼──────────────────────────────────────────────────────────────┤
│ 5     │ Copia os certs para o diretório e sobe o container           │
├───────┼──────────────────────────────────────────────────────────────┤
│ ✔     │ Verifica HTTP, HTTPS e validade do certificado               │
└───────┴──────────────────────────────────────────────────────────────┘
