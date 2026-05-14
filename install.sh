#!/bin/bash
# =============================================================================
# install-dns-update.sh — Instalador do sistema de Update via DNS (NetSimon)
#
# Uso:
#   bash <(curl -sL https://raw.githubusercontent.com/miau4/dns-update-netsimon/main/install.sh)
#
# O que este script faz:
#   1. Instala dependências necessárias (python3, curl)
#   2. Solicita credenciais Cloudflare interativamente
#   3. Cria /etc/netsimon-update.env com as credenciais
#   4. Instala /usr/local/bin/sync-update.sh
#   5. Instala /usr/local/bin/dns-update.sh
#   6. Cria o diretório /var/www/update
#   7. Configura cron job (a cada 2 horas)
#   8. Executa o sistema pela primeira vez
# =============================================================================

set -e

# --- Cores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✘]${NC} $1"; exit 1; }
section() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# --- Verificar root ---
[ "$EUID" -ne 0 ] && error "Execute como root: sudo bash install.sh"

section "NetSimon — Instalador de Update via DNS"
echo "  Repositório: update.netsimon.fun (Cloudflare)"
echo "  Frequência:  a cada 2 horas via cron"
echo ""

# =============================================================================
# 1. DEPENDÊNCIAS
# =============================================================================
section "1. Verificando dependências"

apt-get update -qq
for pkg in python3 curl; do
    if ! command -v $pkg &>/dev/null; then
        warn "$pkg não encontrado, instalando..."
        apt-get install -y -qq $pkg
    else
        log "$pkg OK"
    fi
done

# =============================================================================
# 2. CREDENCIAIS CLOUDFLARE
# =============================================================================
section "2. Credenciais Cloudflare"

echo ""
echo "  Acesse: https://dash.cloudflare.com/profile/api-tokens"
echo "  Use a Global API Key (ou um Token com permissão DNS:Edit)"
echo ""

read -rp "  CF_EMAIL  (e-mail da conta Cloudflare): " CF_EMAIL
while [[ -z "$CF_EMAIL" ]]; do
    warn "E-mail não pode ser vazio."
    read -rp "  CF_EMAIL: " CF_EMAIL
done

read -rsp "  CF_APIKEY (Global API Key ou Token):    " CF_APIKEY
echo ""
while [[ -z "$CF_APIKEY" ]]; do
    warn "API Key não pode ser vazia."
    read -rsp "  CF_APIKEY: " CF_APIKEY
    echo ""
done

# Salva credenciais
cat > /etc/netsimon-update.env << EOF
CF_EMAIL=${CF_EMAIL}
CF_APIKEY=${CF_APIKEY}
EOF
chmod 600 /etc/netsimon-update.env
log "Credenciais salvas em /etc/netsimon-update.env (modo 600)"

# =============================================================================
# 3. DIRETÓRIO DE ATUALIZAÇÃO
# =============================================================================
section "3. Criando diretório /var/www/update"

mkdir -p /var/www/update
log "Diretório criado"

# =============================================================================
# 4. INSTALAR sync-update.sh
# =============================================================================
section "4. Instalando sync-update.sh"

cat > /usr/local/bin/sync-update.sh << 'SCRIPT'
#!/bin/bash
# sync-update.sh — Baixa arquivos de atualização do APK a partir do GitHub
BASE="https://github.com/miau4/update-netsimon-xray/raw/refs/heads/main"
DEST="/var/www/update"

curl -sL "$BASE/index"            -o "$DEST/index.html"
curl -sL "$BASE/config"           -o "$DEST/config.json"
curl -sL "$BASE/config_novo.json" -o "$DEST/config_novo.json"
curl -sL "$BASE/operators.json"   -o "$DEST/operators.json"

echo "Sync concluído: $(date)"
SCRIPT

chmod +x /usr/local/bin/sync-update.sh
log "sync-update.sh instalado"

# =============================================================================
# 5. INSTALAR dns-update.sh
# =============================================================================
section "5. Instalando dns-update.sh"

cat > /usr/local/bin/dns-update.sh << 'SCRIPT'
#!/bin/bash
# =============================================================================
# dns-update.sh — Publica arquivos de atualização do APK via registros TXT DNS
# Cloudflare (update.netsimon.fun)
# =============================================================================

source /etc/netsimon-update.env

ZONE_ID="9c6cc6236d481ece78a2bb198d2e4ac6"
DOMAIN="update.netsimon.fun"
CF_API="https://api.cloudflare.com/client/v4"
UPDATE_DIR="/var/www/update"

echo "[dns-update] Iniciando — $(date)"

/usr/local/bin/sync-update.sh

publish_file() {
    local file="$1" prefix="$2"
    [ ! -f "$file" ] && echo "[dns-update] AVISO: $file não encontrado" && return 1

    python3 << PYEOF
import gzip, base64, json, urllib.request, urllib.error

file_path  = "$file"
prefix     = "$prefix"
domain     = "$DOMAIN"
zone_id    = "$ZONE_ID"
email      = "$CF_EMAIL"
apikey     = "$CF_APIKEY"
api_base   = "$CF_API"
chunk_size = 1000

with open(file_path, 'rb') as f:
    compressed = gzip.compress(f.read())
encoded = base64.b64encode(compressed).decode('utf-8')
chunks  = [encoded[i:i+chunk_size] for i in range(0, len(encoded), chunk_size)]
print(f"[dns-update] {prefix}: {len(encoded)} chars → {len(chunks)} chunks")

headers = {
    'X-Auth-Email': email,
    'X-Auth-Key':   apikey,
    'Content-Type': 'application/json'
}

def cf_request(method, url, data=None):
    body = json.dumps(data).encode() if data else None
    req  = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())

def get_record_id(name):
    url = f"{api_base}/zones/{zone_id}/dns_records?type=TXT&name={name}"
    res = cf_request('GET', url)
    return res['result'][0]['id'] if res.get('result') else None

def upsert(name, value):
    payload = {'type': 'TXT', 'name': name, 'content': value, 'ttl': 60}
    rid = get_record_id(name)
    if rid:
        cf_request('PUT', f"{api_base}/zones/{zone_id}/dns_records/{rid}", payload)
        print(f"[dns-update] ↻ {name}")
    else:
        cf_request('POST', f"{api_base}/zones/{zone_id}/dns_records", payload)
        print(f"[dns-update] + {name}")

for i, chunk in enumerate(chunks):
    upsert(f"{prefix}.{i}.{domain}", chunk)

print(len(chunks))
PYEOF
}

echo "[dns-update] --- operators.json ---"
op=$(publish_file "$UPDATE_DIR/operators.json" "operators" | tee /dev/stderr | tail -1)

echo "[dns-update] --- config.json ---"
cfg=$(publish_file "$UPDATE_DIR/config.json" "config" | tee /dev/stderr | tail -1)

echo "[dns-update] --- config_novo.json ---"
cfgnovo=$(publish_file "$UPDATE_DIR/config_novo.json" "confignovo" | tee /dev/stderr | tail -1)

echo "[dns-update] --- index.html ---"
web=$(publish_file "$UPDATE_DIR/index.html" "webview" | tee /dev/stderr | tail -1)

VERSION=$(date +%s)
META="{\"v\":$VERSION,\"operators\":$op,\"config\":$cfg,\"confignovo\":$cfgnovo,\"webview\":$web}"

python3 << PYEOF
import json, urllib.request

zone_id  = "$ZONE_ID"
email    = "$CF_EMAIL"
apikey   = "$CF_APIKEY"
api_base = "$CF_API"
domain   = "$DOMAIN"
meta     = '$META'

headers = {
    'X-Auth-Email': email,
    'X-Auth-Key':   apikey,
    'Content-Type': 'application/json'
}

def cf_request(method, url, data=None):
    body = json.dumps(data).encode() if data else None
    req  = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())

name    = f"meta.{domain}"
url     = f"{api_base}/zones/{zone_id}/dns_records?type=TXT&name={name}"
res     = cf_request('GET', url)
rid     = res['result'][0]['id'] if res.get('result') else None
payload = {'type': 'TXT', 'name': name, 'content': meta, 'ttl': 60}

if rid:
    cf_request('PUT', f"{api_base}/zones/{zone_id}/dns_records/{rid}", payload)
    print(f"[dns-update] ↻ {name}")
else:
    cf_request('POST', f"{api_base}/zones/{zone_id}/dns_records", payload)
    print(f"[dns-update] + {name}")
PYEOF

echo "[dns-update] Concluído: $(date) — versão $VERSION"
SCRIPT

chmod +x /usr/local/bin/dns-update.sh
log "dns-update.sh instalado"

# =============================================================================
# 6. CRON JOB (a cada 2 horas)
# =============================================================================
section "6. Configurando cron job"

CRON_LINE="0 */2 * * * /usr/local/bin/dns-update.sh >> /var/log/dns-update.log 2>&1"
CRON_MARKER="dns-update.sh"

# Remove entrada antiga se existir, adiciona nova
( crontab -l 2>/dev/null | grep -v "$CRON_MARKER" ; echo "$CRON_LINE" ) | crontab -
log "Cron configurado: a cada 2 horas → log em /var/log/dns-update.log"

# =============================================================================
# 7. PRIMEIRA EXECUÇÃO
# =============================================================================
section "7. Executando pela primeira vez"
echo ""

/usr/local/bin/dns-update.sh

# =============================================================================
# RESUMO FINAL
# =============================================================================
section "Instalação concluída"

echo ""
echo -e "  ${GREEN}Arquivos instalados:${NC}"
echo "    /usr/local/bin/dns-update.sh"
echo "    /usr/local/bin/sync-update.sh"
echo "    /etc/netsimon-update.env"
echo "    /var/www/update/"
echo ""
echo -e "  ${GREEN}Agendamento:${NC}"
echo "    Cron: a cada 2 horas"
echo "    Log:  /var/log/dns-update.log"
echo ""
echo -e "  ${GREEN}Execução manual:${NC}"
echo "    /usr/local/bin/dns-update.sh"
echo ""
echo -e "  ${GREEN}Ver logs:${NC}"
echo "    tail -f /var/log/dns-update.log"
echo ""
