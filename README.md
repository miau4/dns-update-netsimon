# 🌐 dns-update-netsimon

Sistema de atualização automática do APK NetSimon VPN via registros TXT do DNS (Cloudflare).

---

## Como funciona

```
GitHub (update-netsimon-xray)
        ↓  sync-update.sh baixa os arquivos
/var/www/update/
        ↓  dns-update.sh comprime, codifica e publica
Cloudflare DNS (update.netsimon.fun)
        ↓  APK consulta os registros TXT
Aplicativo NetSimon VPN atualizado
```

1. `sync-update.sh` baixa os arquivos mais recentes do repositório [update-netsimon-xray](https://github.com/miau4/update-netsimon-xray)
2. `dns-update.sh` comprime cada arquivo (gzip + base64), divide em chunks de 250 chars e publica como registros TXT no Cloudflare
3. Um registro `meta.update.netsimon.fun` é publicado com a versão atual e a contagem de chunks de cada arquivo
4. O APK consulta o `meta` primeiro, depois busca e remonta os chunks na ordem correta

---

## Instalação

```bash
bash <(curl -sL https://raw.githubusercontent.com/miau4/dns-update-netsimon/main/install.sh)
```

> Requer acesso root. Será solicitado e-mail e API Key da Cloudflare durante a instalação.

---

## Arquivos instalados no servidor

| Caminho | Descrição |
|---|---|
| `/usr/local/bin/dns-update.sh` | Script principal — publica no DNS |
| `/usr/local/bin/sync-update.sh` | Baixa arquivos do GitHub |
| `/etc/netsimon-update.env` | Credenciais Cloudflare (modo 600) |
| `/var/www/update/` | Diretório dos arquivos de atualização |
| `/var/log/dns-update.log` | Log de execuções |

---

## Arquivos publicados no DNS

| Registro TXT | Conteúdo |
|---|---|
| `meta.update.netsimon.fun` | Versão atual + contagem de chunks |
| `operators.N.update.netsimon.fun` | Chunks do `operators.json` |
| `config.N.update.netsimon.fun` | Chunks do `config.json` |
| `confignovo.N.update.netsimon.fun` | Chunks do `config_novo.json` |
| `webview.N.update.netsimon.fun` | Chunks do `index.html` |

---

## Agendamento

Cron configurado automaticamente pelo instalador:

```
0 */2 * * * /usr/local/bin/dns-update.sh >> /var/log/dns-update.log 2>&1
```

Executa a cada **2 horas**.

---

## Comandos úteis

```bash
# Executar manualmente
/usr/local/bin/dns-update.sh

# Acompanhar log em tempo real
tail -f /var/log/dns-update.log

# Ver cron configurado
crontab -l | grep dns-update

# Verificar registro meta no DNS
dig TXT meta.update.netsimon.fun @8.8.8.8 +short
```

---

## Credenciais

As credenciais ficam em `/etc/netsimon-update.env`:

```env
CF_EMAIL=seu-email@exemplo.com
CF_APIKEY=sua-api-key
```

> ⚠️ Este arquivo tem permissão `600` e **nunca deve ser commitado no GitHub**.
