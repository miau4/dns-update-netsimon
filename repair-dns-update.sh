#!/bin/bash
# =============================================================================
#COMANDO PARA RODAR O SCRIPT:
#
#bash <(curl -sL https://raw.githubusercontent.com/miau4/dns-update-netsimon/main/repair-dns-update.sh)
#
# repair-dns-update.sh — Diagnóstico e reparo da publicação DNS (NetSimon)
#
# Execute no servidor VPS como root:
#   bash repair-dns-update.sh
# =============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
err()     { echo -e "${RED}[✘]${NC} $1"; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

[ "$EUID" -ne 0 ] && { err "Execute como root: sudo bash repair-dns-update.sh"; exit 1; }

ZONE_ID="9c6cc6236d481ece78a2bb198d2e4ac6"
CF_API="https://api.cloudflare.com/client/v4"
ENV_FILE="/etc/netsimon-update.env"

# =============================================================================
# 1. VERIFICAR CREDENCIAIS
# =============================================================================
section "1. Verificando credenciais Cloudflare"

NEED_CREDS=0

if [ ! -f "$ENV_FILE" ]; then
    warn "$ENV_FILE não encontrado — será criado agora"
    NEED_CREDS=1
else
    source "$ENV_FILE"
    if [ -z "$CF_EMAIL" ] || [ -z "$CF_APIKEY" ]; then
        warn "$ENV_FILE existe mas está incompleto (CF_EMAIL ou CF_APIKEY vazio)"
        NEED_CREDS=1
    else
        echo "  CF_EMAIL : $CF_EMAIL"
        echo "  CF_APIKEY: ${CF_APIKEY:0:8}... (primeiros 8 chars)"
    fi
fi

if [ "$NEED_CREDS" -eq 1 ]; then
    echo ""
    echo "  Acesse: https://dash.cloudflare.com/profile/api-tokens"
    echo "  Use a Global API Key (My Profile → API Keys → Global API Key)"
    echo ""
    read -rp "  CF_EMAIL (e-mail da conta Cloudflare): " CF_EMAIL
    while [ -z "$CF_EMAIL" ]; do
        warn "E-mail não pode ser vazio."
        read -rp "  CF_EMAIL: " CF_EMAIL
    done
    read -rsp "  CF_APIKEY (Global API Key):            " CF_APIKEY
    echo ""
    while [ -z "$CF_APIKEY" ]; do
        warn "API Key não pode ser vazia."
        read -rsp "  CF_APIKEY: " CF_APIKEY
        echo ""
    done
    cat > "$ENV_FILE" << EOF
CF_EMAIL=${CF_EMAIL}
CF_APIKEY=${CF_APIKEY}
EOF
    chmod 600 "$ENV_FILE"
    log "Credenciais salvas em $ENV_FILE"
fi

# =============================================================================
# 2. TESTAR AUTENTICAÇÃO
# =============================================================================
section "2. Testando autenticação na API Cloudflare"

AUTH_RESP=$(curl -s "https://api.cloudflare.com/client/v4/user" \
    -H "X-Auth-Email: $CF_EMAIL" \
    -H "X-Auth-Key: $CF_APIKEY" \
    -H "Content-Type: application/json")

AUTH_OK=$(echo "$AUTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success',False))" 2>/dev/null)
AUTH_ERR=$(echo "$AUTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); errs=d.get('errors',[]); print(errs[0].get('message','') if errs else '')" 2>/dev/null)

if [ "$AUTH_OK" != "True" ]; then
    err "Autenticação FALHOU: $AUTH_ERR"
    echo ""
    echo "  Verifique:"
    echo "  • O e-mail está correto?"
    echo "  • Está usando a Global API Key (não um token de API)?"
    echo "  • Acesse: https://dash.cloudflare.com/profile/api-tokens"
    echo ""
    read -rp "  Deseja re-inserir as credenciais? (s/n): " RETRY
    if [[ "$RETRY" =~ ^[Ss]$ ]]; then
        rm -f "$ENV_FILE"
        exec bash "$0"
    fi
    exit 1
fi
log "Autenticação OK — conta: $(echo "$AUTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('email','?'))" 2>/dev/null)"

# =============================================================================
# 3. VERIFICAR ZONE ID
# =============================================================================
section "3. Verificando Zone ID ($ZONE_ID)"

ZONE_RESP=$(curl -s "$CF_API/zones/$ZONE_ID" \
    -H "X-Auth-Email: $CF_EMAIL" \
    -H "X-Auth-Key: $CF_APIKEY")

ZONE_OK=$(echo "$ZONE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success',False))" 2>/dev/null)
ZONE_NAME=$(echo "$ZONE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('name','?'))" 2>/dev/null)

if [ "$ZONE_OK" != "True" ]; then
    err "Zone ID inválido ou sem permissão de acesso"
    err "Resposta: $(echo "$ZONE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('errors'))" 2>/dev/null)"
    exit 1
fi
log "Zone OK: $ZONE_NAME"

# =============================================================================
# 4. VERIFICAR REGISTROS TXT EXISTENTES
# =============================================================================
section "4. Verificando registros TXT em update.netsimon.fun"

TXT_RESP=$(curl -s "$CF_API/zones/$ZONE_ID/dns_records?type=TXT&per_page=50" \
    -H "X-Auth-Email: $CF_EMAIL" \
    -H "X-Auth-Key: $CF_APIKEY")

TXT_COUNT=$(echo "$TXT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len([r for r in d.get('result',[]) if 'update.netsimon.fun' in r.get('name','')]))" 2>/dev/null)

echo "  Registros TXT relativos a update.netsimon.fun: $TXT_COUNT"

if [ "$TXT_COUNT" -gt 0 ]; then
    echo "  Registros encontrados:"
    echo "$TXT_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('result', []):
    if 'update.netsimon.fun' in r.get('name', ''):
        print(f\"    {r['name']:50s} {r['content'][:40]}...\")
" 2>/dev/null
else
    warn "Nenhum registro TXT encontrado — dns-update.sh irá criá-los"
fi

# =============================================================================
# 5. VERIFICAR ARQUIVOS DE ATUALIZAÇÃO
# =============================================================================
section "5. Verificando /var/www/update"

if [ ! -d /var/www/update ]; then
    warn "/var/www/update não existe — criando..."
    mkdir -p /var/www/update
fi

for f in index.html config.json config_novo.json operators.json; do
    if [ -f "/var/www/update/$f" ]; then
        SIZE=$(wc -c < "/var/www/update/$f")
        log "$f — ${SIZE} bytes"
    else
        warn "$f — NÃO encontrado (sync-update.sh irá baixar)"
    fi
done

# =============================================================================
# 6. VERIFICAR SCRIPTS INSTALADOS
# =============================================================================
section "6. Verificando scripts"

for script in /usr/local/bin/dns-update.sh /usr/local/bin/sync-update.sh; do
    if [ -f "$script" ] && [ -x "$script" ]; then
        log "$script OK"
    else
        err "$script não encontrado ou sem permissão de execução"
        echo "  Execute o instalador original primeiro:"
        echo "  bash <(curl -sL https://raw.githubusercontent.com/miau4/dns-update-netsimon/main/install.sh)"
        exit 1
    fi
done

# =============================================================================
# 7. EXECUTAR DNS-UPDATE
# =============================================================================
section "7. Executando dns-update.sh"
echo ""
echo -e "  ${YELLOW}Isso pode levar 1-3 minutos dependendo do número de chunks...${NC}"
echo ""

/usr/local/bin/dns-update.sh 2>&1 | tee /tmp/dns-update-repair.log

EXIT_CODE=${PIPESTATUS[0]}

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    log "dns-update.sh concluído com sucesso"
else
    err "dns-update.sh terminou com código $EXIT_CODE"
fi

# =============================================================================
# 8. CONFIRMAR REGISTROS CRIADOS
# =============================================================================
section "8. Confirmando registros TXT publicados"

sleep 2   # Cloudflare propaga instantaneamente, mas aguarda commit da API

TXT_RESP2=$(curl -s "$CF_API/zones/$ZONE_ID/dns_records?type=TXT&per_page=100" \
    -H "X-Auth-Email: $CF_EMAIL" \
    -H "X-Auth-Key: $CF_APIKEY")

TXT_COUNT2=$(echo "$TXT_RESP2" | python3 -c "
import sys, json
d = json.load(sys.stdin)
total = len([r for r in d.get('result',[]) if 'update.netsimon.fun' in r.get('name','')])
print(total)
" 2>/dev/null)

echo "  Registros TXT criados: $TXT_COUNT2"
echo "$TXT_RESP2" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('result', []):
    name = r.get('name','')
    if 'update.netsimon.fun' not in name:
        continue
    content = r.get('content','')
    print(f'    {name[:50]:50s}  {len(content)} chars')
" 2>/dev/null | sort

META_RESP=$(curl -s "$CF_API/zones/$ZONE_ID/dns_records?type=TXT&name=meta.update.netsimon.fun" \
    -H "X-Auth-Email: $CF_EMAIL" \
    -H "X-Auth-Key: $CF_APIKEY")
META_CONTENT=$(echo "$META_RESP" | python3 -c "
import sys,json; d=json.load(sys.stdin)
res = d.get('result',[])
print(res[0].get('content','NÃO ENCONTRADO') if res else 'NÃO ENCONTRADO')
" 2>/dev/null)

echo ""
echo "  meta.update.netsimon.fun = $META_CONTENT"

if echo "$META_CONTENT" | grep -q '"v"'; then
    echo ""
    log "Sistema de atualização DNS funcionando corretamente!"
    log "O app Android irá receber as atualizações na próxima execução."
else
    err "Registro meta ainda inválido — verifique o log acima"
fi

echo ""
echo "  Log completo em: /tmp/dns-update-repair.log"
echo "  Log de produção: /var/log/dns-update.log"
