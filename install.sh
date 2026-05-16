#!/bin/bash
# =============================================================================
#  free-claude install — бесплатный Claude Code через Amazon Kiro/CodeWhisperer
#  Работает на любом сервере включая Cloud.ru (российские IP)
#
#  Использование:
#    curl -fsSL https://raw.githubusercontent.com/ankor1403/free-claude-public/main/install.sh | bash
#    ИЛИ
#    bash install.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }
step()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }

INSTALL_DIR="${FREE_CLAUDE_DIR:-$HOME/.free-claude}"
CCR_PORT="${CCR_PORT:-3456}"
AUTH_DIR="$INSTALL_DIR/auth_files"
PID_FILE="$INSTALL_DIR/ccr.pid"
LOG_FILE="$INSTALL_DIR/ccr.log"
SERVICE_NAME="free-claude-ccr"

# ─── 1. Зависимости ──────────────────────────────────────────────────────────
step "Проверка зависимостей"

install_pkg() {
    if   command -v apt-get &>/dev/null; then apt-get install -y -q "$@" 2>/dev/null
    elif command -v yum     &>/dev/null; then yum install -y -q "$@" 2>/dev/null
    elif command -v dnf     &>/dev/null; then dnf install -y -q "$@" 2>/dev/null
    else warn "Установите вручную: $*"; fi
}

command -v python3 &>/dev/null || install_pkg python3
command -v curl    &>/dev/null || install_pkg curl

if ! command -v node &>/dev/null; then
    warn "Node.js не найден — устанавливаем..."
    if command -v apt-get &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | bash - 2>/dev/null
        apt-get install -y -q nodejs 2>/dev/null
    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        curl -fsSL https://rpm.nodesource.com/setup_20.x 2>/dev/null | bash - 2>/dev/null
        (yum install -y -q nodejs || dnf install -y -q nodejs) 2>/dev/null
    fi
fi
info "Node.js $(node --version 2>/dev/null || echo '?')"

# ─── 2. claude-code-router ────────────────────────────────────────────────────
step "Установка claude-code-router"

if ! command -v claude-code-router &>/dev/null && ! command -v ccr &>/dev/null; then
    info "Устанавливаем npm пакет..."
    npm install -g --omit=dev claude-code-router 2>&1 | tail -3
else
    info "Уже установлен: $(claude-code-router --version 2>/dev/null || echo '?')"
fi

CCR_CMD=""
for c in claude-code-router ccr; do
    command -v "$c" &>/dev/null && { CCR_CMD="$c"; break; }
done
[ -z "$CCR_CMD" ] && { err "claude-code-router не установлен"; exit 1; }

# ─── 3. Директории и конфиг ──────────────────────────────────────────────────
step "Конфигурация"

mkdir -p "$AUTH_DIR" "$HOME/.claude-code-router/auth_files"

cat > "$INSTALL_DIR/config.json" << 'CONFIG'
{
  "server": { "port": 3456, "host": "127.0.0.1" },
  "routing": {
    "defaultProvider": "kiro",
    "providers": {
      "kiro": {
        "type": "codewhisperer",
        "endpoint": "https://codewhisperer.us-east-1.amazonaws.com",
        "authentication": { "type": "bearer", "credentials": {} },
        "settings": {
          "categoryMappings": {
            "default": true, "background": true,
            "thinking": true, "longcontext": true, "search": true
          }
        }
      }
    }
  },
  "debug": { "enabled": false, "logLevel": "info" }
}
CONFIG

cp "$INSTALL_DIR/config.json" "$HOME/.claude-code-router/config.json"
info "Конфиг записан"

# ─── 4. Авторизация Kiro (Amazon Builder ID) ─────────────────────────────────
step "Авторизация Kiro"

# Получаем device code и ждём авторизации пользователя
do_kiro_auth() {
    info "Регистрируем клиента в AWS SSO..."
    local STATE
    STATE=$(python3 -c "
import urllib.request, json, urllib.error

# Шаг 1: register client
req = urllib.request.Request(
    'https://oidc.us-east-1.amazonaws.com/client/register',
    data=json.dumps({
        'clientName': 'free-claude',
        'clientType': 'public',
        'scopes': ['codewhisperer:conversations','codewhisperer:completions','codewhisperer:analysis'],
        'grantTypes': ['urn:ietf:params:oauth:grant-type:device_code']
    }).encode(),
    headers={'Content-Type': 'application/json'}, method='POST'
)
reg = json.load(urllib.request.urlopen(req, timeout=15))

# Шаг 2: device authorization
req2 = urllib.request.Request(
    'https://oidc.us-east-1.amazonaws.com/device_authorization',
    data=json.dumps({
        'clientId': reg['clientId'],
        'clientSecret': reg['clientSecret'],
        'scopes': ['codewhisperer:conversations','codewhisperer:completions','codewhisperer:analysis'],
        'startUrl': 'https://view.awsapps.com/start'
    }).encode(),
    headers={'Content-Type': 'application/json'}, method='POST'
)
dev = json.load(urllib.request.urlopen(req2, timeout=15))
print(json.dumps({'client_id': reg['clientId'], 'client_secret': reg['clientSecret'],
                  'device_code': dev['deviceCode'], 'user_code': dev['userCode'],
                  'verify_url': dev['verificationUriComplete']}))
")
    local CLIENT_ID CLIENT_SECRET DEVICE_CODE USER_CODE VERIFY_URL
    CLIENT_ID=$(echo "$STATE" | python3 -c "import json,sys; print(json.load(sys.stdin)['client_id'])")
    CLIENT_SECRET=$(echo "$STATE" | python3 -c "import json,sys; print(json.load(sys.stdin)['client_secret'])")
    DEVICE_CODE=$(echo "$STATE" | python3 -c "import json,sys; print(json.load(sys.stdin)['device_code'])")
    USER_CODE=$(echo "$STATE" | python3 -c "import json,sys; print(json.load(sys.stdin)['user_code'])")
    VERIFY_URL=$(echo "$STATE" | python3 -c "import json,sys; print(json.load(sys.stdin)['verify_url'])")

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║         Требуется авторизация в браузере             ║${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  1. Откройте ссылку в браузере:                      ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}     ${YELLOW}$VERIFY_URL${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                                                      ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  2. Код: ${BOLD}${GREEN}$USER_CODE${NC}                                    ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                                                      ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  3. Войдите с Amazon аккаунтом (amazon.com)          ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}     Нет аккаунта? Создайте бесплатно на amazon.com   ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠  ВАЖНО: После входа откройте также https://app.kiro.dev${NC}"
    echo -e "     ${YELLOW}и примите условия использования (ToS)${NC}"
    echo ""

    # Ждём авторизации — поллинг
    local TOKEN_FILE="$AUTH_DIR/kiro-token.json"
    info "Ожидаю авторизацию (до 10 минут)..."
    python3 << PYEOF
import urllib.request, json, time, datetime, sys

client_id     = "$CLIENT_ID"
client_secret = "$CLIENT_SECRET"
device_code   = "$DEVICE_CODE"
token_file    = "$TOKEN_FILE"
auth_dir_file = "$HOME/.claude-code-router/auth_files/kiro-token.json"

for i in range(120):
    try:
        req = urllib.request.Request(
            'https://oidc.us-east-1.amazonaws.com/token',
            data=json.dumps({
                'clientId': client_id,
                'clientSecret': client_secret,
                'deviceCode': device_code,
                'grantType': 'urn:ietf:params:oauth:grant-type:device_code'
            }).encode(),
            headers={'Content-Type': 'application/json'}, method='POST'
        )
        resp = urllib.request.urlopen(req, timeout=15)
        d = json.load(resp)
    except urllib.error.HTTPError as e:
        d = json.load(e)
    except Exception as ex:
        print(f"\r  Ошибка сети: {ex}", end='', flush=True)
        time.sleep(5); continue

    err = d.get('error', '')
    if err == 'authorization_pending':
        print(f"\r  Ожидание... {i+1}/120   ", end='', flush=True)
        time.sleep(5); continue
    if err == 'slow_down':
        time.sleep(10); continue
    if err == 'expired_token':
        print("\nКод истёк. Перезапустите скрипт.")
        sys.exit(1)
    if err:
        print(f"\nОшибка: {err}")
        sys.exit(1)

    # Успех
    token = {
        'accessToken':  d.get('accessToken',  d.get('access_token', '')),
        'refreshToken': d.get('refreshToken', d.get('refresh_token', '')),
        'expiresAt':    (datetime.datetime.utcnow() + datetime.timedelta(hours=8)).strftime('%Y-%m-%dT%H:%M:%SZ')
    }
    for path in [token_file, auth_dir_file]:
        with open(path, 'w') as f:
            json.dump(token, f, indent=2)
    print(f"\nТокен получен! accessToken: {token['accessToken'][:20]}...")
    sys.exit(0)

print("\nTimeout: авторизация не завершена за 10 минут.")
sys.exit(1)
PYEOF
}

# Проверяем есть ли уже свежий токен
need_auth=true
for f in "$AUTH_DIR"/*.json "$HOME/.claude-code-router/auth_files"/*.json; do
    [ -f "$f" ] || continue
    is_valid=$(python3 -c "
import json,datetime
try:
    d=json.load(open('$f'))
    exp=datetime.datetime.strptime(d.get('expiresAt','2000-01-01T00:00:00Z'),'%Y-%m-%dT%H:%M:%SZ')
    print('yes' if exp > datetime.datetime.utcnow() else 'no')
except: print('no')
" 2>/dev/null)
    if [ "$is_valid" = "yes" ]; then
        warn "Найден существующий токен в $f"
        cp "$f" "$AUTH_DIR/kiro-token.json" 2>/dev/null || true
        cp "$AUTH_DIR/kiro-token.json" "$HOME/.claude-code-router/auth_files/kiro-token.json" 2>/dev/null || true
        need_auth=false
        break
    fi
done

$need_auth && do_kiro_auth

# Тестируем токен
info "Тестируем подключение к CodeWhisperer..."
AT=$(python3 -c "import json; print(json.load(open('$AUTH_DIR/kiro-token.json'))['accessToken'])" 2>/dev/null || echo "")
if [ -n "$AT" ]; then
    TEST_RESP=$(curl -sf --connect-timeout 15 \
      -X POST "https://codewhisperer.us-east-1.amazonaws.com/generateAssistantResponse" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $AT" \
      -d '{"conversationState":{"chatTriggerType":"MANUAL","currentMessage":{"userInputMessage":{"content":"Reply: OK","userInputMessageContext":{}}},"conversationId":"test"}}' 2>/dev/null || echo "error")

    if echo "$TEST_RESP" | grep -qi "suspended"; then
        echo ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ВНИМАНИЕ: Аккаунт требует верификации на Kiro       ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════════════╣${NC}"
        echo -e "${YELLOW}║  1. Откройте https://app.kiro.dev в браузере         ║${NC}"
        echo -e "${YELLOW}║  2. Войдите тем же Amazon аккаунтом                  ║${NC}"
        echo -e "${YELLOW}║  3. Примите условия использования                    ║${NC}"
        echo -e "${YELLOW}║  4. Если всё равно suspended — нажмите Support       ║${NC}"
        echo -e "${YELLOW}║     или создайте новый Amazon аккаунт                ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        warn "Установка продолжается, но запросы будут блокированы до верификации"
    else
        info "CodeWhisperer API доступен!"
    fi
fi

# ─── 5. Запуск CCR ────────────────────────────────────────────────────────────
step "Запуск сервиса"

[ -f "$PID_FILE" ] && kill "$(cat $PID_FILE)" 2>/dev/null || true; sleep 1

nohup "$CCR_CMD" start > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
sleep 4

if curl -sf "http://127.0.0.1:$CCR_PORT/health" &>/dev/null; then
    info "CCR запущен (PID $(cat $PID_FILE), порт $CCR_PORT)"
else
    err "CCR не стартовал. Лог:"
    tail -15 "$LOG_FILE" >&2
    exit 1
fi

# Systemd автозапуск
if command -v systemctl &>/dev/null && [ -d /etc/systemd/system ] && [ "$(id -u)" = "0" ]; then
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << UNIT
[Unit]
Description=Free Claude Gateway (Kiro/CodeWhisperer)
After=network.target

[Service]
Type=simple
User=$(whoami)
ExecStart=$(which $CCR_CMD) start
Restart=always
RestartSec=10
Environment=HOME=$HOME

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" 2>/dev/null && info "Systemd автозапуск включён"
fi

# ─── 6. Переменные окружения ──────────────────────────────────────────────────
step "Настройка Claude Code"

ENV_BLOCK="
# free-claude gateway (Kiro/CodeWhisperer — бесплатно)
export ANTHROPIC_BASE_URL=\"http://127.0.0.1:$CCR_PORT\"
export ANTHROPIC_API_KEY=\"kiro-free\""

for RC in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$RC" ] || continue
    grep -q "ANTHROPIC_BASE_URL" "$RC" 2>/dev/null && continue
    echo "$ENV_BLOCK" >> "$RC"
    info "Добавлено в $RC"
done

# ─── 7. Команда для переавторизации ──────────────────────────────────────────
REAUTH_SCRIPT="/usr/local/bin/claude-kiro-auth"
cat > "$REAUTH_SCRIPT" 2>/dev/null << REAUTH || true
#!/bin/bash
# Переавторизация Kiro токена
set -e
INSTALL_DIR="$INSTALL_DIR"
AUTH_DIR="$AUTH_DIR"
$(declare -f do_kiro_auth)
do_kiro_auth
systemctl restart $SERVICE_NAME 2>/dev/null || (kill \$(cat $PID_FILE) 2>/dev/null; sleep 1; nohup $CCR_CMD start > $LOG_FILE 2>&1 & echo \$! > $PID_FILE)
echo "Готово!"
REAUTH
chmod +x "$REAUTH_SCRIPT" 2>/dev/null || true

# ─── Итог ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║     Free Claude Gateway установлен!                    ║${NC}"
echo -e "${BOLD}${GREEN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Активируйте в текущей сессии:                        ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}    ${CYAN}export ANTHROPIC_BASE_URL=http://127.0.0.1:$CCR_PORT${NC}   ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}    ${CYAN}export ANTHROPIC_API_KEY=kiro-free${NC}                ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}    ${CYAN}claude${NC}                                             ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}                                                        ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}  В новых сессиях работает автоматически (через .bashrc)${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}                                                        ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Переавторизация: ${CYAN}claude-kiro-auth${NC}                   ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Статус:          ${CYAN}curl http://127.0.0.1:$CCR_PORT/health${NC}    ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
