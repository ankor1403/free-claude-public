#!/bin/bash
# =============================================================================
#  free-claude install — бесплатный Claude Code через Amazon Kiro/CodeWhisperer
#  Работает на любом сервере включая Cloud.ru (российские IP)
#
#  Использование:
#    curl -fsSL https://install.afonin-lisa.ru/claude | bash
#    ИЛИ
#    bash install.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
step()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }
fatal() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

PROXY_PORT="${PROXY_PORT:-3456}"
PROXY_PATH="$HOME/kiro_proxy.py"
TOKEN_FILE="$HOME/.aws/sso/cache/kiro-auth-token-cli.json"
KIRO_CACHE="$HOME/.aws/sso/cache"
LOG_FILE="/tmp/kiro_proxy.log"
REAUTH_SCRIPT="$HOME/kiro-reauth.sh"

# ─── 1. Зависимости ──────────────────────────────────────────────────────────
step "Проверка зависимостей"

install_pkg() {
    if   command -v apt-get &>/dev/null; then apt-get install -y -q "$@" 2>/dev/null
    elif command -v yum     &>/dev/null; then yum install -y -q "$@" 2>/dev/null
    elif command -v dnf     &>/dev/null; then dnf install -y -q "$@" 2>/dev/null
    else warn "Установите вручную: $*"; return 1; fi
}

command -v python3 &>/dev/null || install_pkg python3 || fatal "Нужен python3"
command -v curl    &>/dev/null || install_pkg curl    || fatal "Нужен curl"
info "Python $(python3 --version 2>&1 | cut -d' ' -f2)"

# ─── 2. Установка kiro-cli ───────────────────────────────────────────────────
step "Установка kiro-cli"

export PATH="$HOME/.local/bin:/snap/bin:$PATH"

if [ -x "$HOME/.local/bin/kiro-cli" ]; then
    KIRO_VER=$("$HOME/.local/bin/kiro-cli" --version 2>/dev/null | head -1 || echo "?")
    info "kiro-cli уже установлен: $KIRO_VER"
else
    info "Скачиваю kiro-cli с cli.kiro.dev/install..."
    curl -fsSL https://cli.kiro.dev/install | bash
    info "kiro-cli установлен: $("$HOME/.local/bin/kiro-cli" --version 2>/dev/null | head -1 || echo '?')"
fi
KIRO_CMD="$HOME/.local/bin/kiro-cli"

# ─── 3. Установка Claude Code ────────────────────────────────────────────────
step "Установка Claude Code"

if [ -x "$HOME/.local/bin/claude" ]; then
    CLAUDE_VER=$("$HOME/.local/bin/claude" --version 2>/dev/null | head -1 || echo "?")
    info "Claude Code уже установлен: $CLAUDE_VER"
else
    # Нужен Node.js для npm install
    if ! command -v npm &>/dev/null; then
        warn "npm не найден — устанавливаю Node.js 20..."
        if command -v apt-get &>/dev/null; then
            curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | bash - 2>/dev/null
            apt-get install -y -q nodejs 2>/dev/null
        elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
            curl -fsSL https://rpm.nodesource.com/setup_20.x 2>/dev/null | bash - 2>/dev/null
            (yum install -y -q nodejs || dnf install -y -q nodejs) 2>/dev/null
        fi
    fi
    info "Устанавливаю Claude Code через npm..."
    npm install -g @anthropic-ai/claude-code 2>&1 | tail -2
    info "Claude Code $(~/.local/bin/claude --version 2>/dev/null | head -1 || echo '?')"
fi

# ─── 4. Авторизация Kiro ─────────────────────────────────────────────────────
step "Авторизация Kiro (free tier)"

check_token() {
    # Возвращает 0 если токен действителен > 5 минут
    [ -f "$TOKEN_FILE" ] || return 1
    python3 -c "
import json, datetime, re, sys
try:
    d = json.load(open('$TOKEN_FILE'))
    exp = re.sub(r'(\\.\\d{3})\\d+Z', r'\\1Z', d.get('expiresAt',''))
    t = datetime.datetime.strptime(exp, '%Y-%m-%dT%H:%M:%S.%fZ')
    sys.exit(0 if (t - datetime.datetime.utcnow()).total_seconds() > 300 else 1)
except: sys.exit(1)
" 2>/dev/null
}

do_login() {
    # Сначала logout чтобы сбросить любое старое состояние
    "$KIRO_CMD" logout 2>/dev/null || true

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║      Требуется авторизация в браузере                ║${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  Сейчас появится ссылка и код.                        ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  Откройте ссылку ${YELLOW}с нероссийским IP / VPN${NC}           ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  и войдите с Amazon аккаунтом (amazon.com)            ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}Нет аккаунта?${NC} Создайте бесплатно на amazon.com     ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    "$KIRO_CMD" login --license free --use-device-flow
}

if check_token; then
    info "Токен Kiro действителен"
else
    do_login
    sleep 2
    check_token || warn "Токен после авторизации не найден — проверьте вручную"
    info "Авторизация завершена"
fi

# ─── 5. Установка kiro_proxy.py ──────────────────────────────────────────────
step "Установка прокси (kiro_proxy.py)"

cat > "$PROXY_PATH" << 'PROXY_EOF'
#!/usr/bin/env python3
"""
Anthropic-compat proxy → Kiro/CodeWhisperer (free tier)
- Конвертирует Claude API формат в CodeWhisperer generateAssistantResponse
- Авторефреш токена через AWS OIDC (Amazon JSON Protocol)
- Поддерживает как streaming (SSE) так и обычные ответы
"""
import json, urllib.request, urllib.error, uuid, re, os, sys, datetime
from http.server import HTTPServer, BaseHTTPRequestHandler

TOKEN_FILE = os.path.expanduser("~/.aws/sso/cache/kiro-auth-token-cli.json")
CACHE_DIR  = os.path.expanduser("~/.aws/sso/cache/")
CW_URL     = "https://codewhisperer.us-east-1.amazonaws.com/generateAssistantResponse"
OIDC_URL   = "https://oidc.us-east-1.amazonaws.com/token"
LOG_FILE   = "/tmp/kiro_proxy.log"

def log(msg):
    ts = datetime.datetime.now().strftime("%H:%M:%S")
    line = f"[{ts}] {msg}\n"
    sys.stdout.write(line); sys.stdout.flush()
    try:
        with open(LOG_FILE, "a") as f: f.write(line)
    except: pass

def token_expiry(data):
    exp = re.sub(r'(\.\d{3})\d+Z$', r'\1Z', data.get("expiresAt", ""))
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"):
        try: return datetime.datetime.strptime(exp, fmt)
        except: pass
    return datetime.datetime.utcnow() + datetime.timedelta(hours=1)

def refresh_access_token(data):
    """Обновляет токен через AWS OIDC Amazon JSON Protocol (не стандартный OIDC!)"""
    client_hash = data.get("clientIdHash", "")
    if not client_hash:
        raise ValueError("нет clientIdHash — нужна повторная авторизация (kiro-reauth)")
    client_data = json.load(open(CACHE_DIR + client_hash + ".json"))
    body = json.dumps({
        "grantType": "refresh_token",
        "refreshToken": data["refreshToken"],
        "clientId": client_data["clientId"],
        "clientSecret": client_data["clientSecret"],
    }).encode()
    req = urllib.request.Request(OIDC_URL, data=body, headers={
        "Content-Type": "application/x-amz-json-1.1",
        "X-Amz-Target": "OIDCService.CreateToken",
    })
    result = json.loads(urllib.request.urlopen(req, timeout=15).read())
    if not result.get("accessToken"):
        raise ValueError(f"нет accessToken в ответе: {list(result.keys())}")
    exp_in = result.get("expiresIn", 3600)
    expires_at = (datetime.datetime.utcnow() + datetime.timedelta(seconds=exp_in)).strftime(
        "%Y-%m-%dT%H:%M:%S.000Z")
    new_data = {
        "accessToken": result["accessToken"],
        "refreshToken": result.get("refreshToken", data["refreshToken"]),
        "expiresAt": expires_at,
        "region": data.get("region", "us-east-1"),
        "authMethod": data.get("authMethod", "IdC"),
        "clientIdHash": client_hash,
    }
    with open(TOKEN_FILE, "w") as f: json.dump(new_data, f, indent=2)
    return new_data

def get_valid_token():
    data = json.load(open(TOKEN_FILE))
    remaining = (token_expiry(data) - datetime.datetime.utcnow()).total_seconds()
    if remaining < 300:
        pfx = f"истёк {-remaining:.0f}с назад" if remaining < 0 else f"истекает через {remaining:.0f}с"
        log(f"Токен {pfx} — обновляю автоматически...")
        try:
            data = refresh_access_token(data)
            log("Токен обновлён")
        except Exception as e:
            log(f"ОШИБКА refresh: {e}")
            if remaining < -3600:
                raise RuntimeError(f"Токен давно истёк и не обновляется. Запустите: ~/kiro-reauth.sh")
    return data["accessToken"]

def extract_text(messages):
    for msg in reversed(messages):
        if msg.get("role") == "user":
            c = msg.get("content", "")
            if isinstance(c, str): return c[:8000]
            if isinstance(c, list):
                return " ".join(p.get("text","") for p in c if p.get("type")=="text")[:8000]
    return ""

def call_cw(content):
    token = get_valid_token()
    body = json.dumps({
        "conversationState": {
            "chatTriggerType": "MANUAL",
            "conversationId": str(uuid.uuid4()),
            "currentMessage": {"userInputMessage": {
                "content": content, "origin": "AI_EDITOR",
                "userInputMessageContext": {}
            }},
            "history": []
        }
    }).encode()
    req = urllib.request.Request(CW_URL, data=body, headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}"
    })
    return urllib.request.urlopen(req, timeout=90).read()

def parse_response(raw):
    """Парсит бинарный AWS EventStream → текст"""
    parts = []
    for m in re.finditer(rb'"content"\s*:\s*"((?:[^"\\]|\\.)*)"', raw):
        try:
            c = m.group(1).decode("utf-8", errors="replace")
            c = c.replace("\\n","\n").replace("\\t","\t").replace('\\"','"').replace("\\\\","\\")
            if c.strip(): parts.append(c)
        except: pass
    if parts: return "".join(parts).strip()
    try:
        lines = [l.strip() for l in raw.decode("utf-8","replace").split("\n")
                 if len(l.strip()) > 10 and l[:1].isalpha()]
        return " ".join(lines[:5]) or "Response received"
    except: return "Response received"

class ProxyHandler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if "models" in self.path:
            self.wfile.write(json.dumps({"data": [
                {"id": "claude-opus-4-7", "object": "model"},
                {"id": "claude-sonnet-4-5", "object": "model"},
                {"id": "claude-haiku-4-5", "object": "model"},
            ]}).encode())
        else:
            self.wfile.write(b'{"status":"ok","provider":"kiro-free"}')

    def do_POST(self):
        if not (self.path.startswith("/v1/messages") or self.path.startswith("/messages")):
            self.send_response(404); self.end_headers(); return

        n = int(self.headers.get("Content-Length", 0))
        try: body = json.loads(self.rfile.read(n) if n else b"{}")
        except: body = {}
        model = body.get("model", "claude-opus-4-7")
        stream = body.get("stream", False)

        try:
            content = extract_text(body.get("messages", [])) or "Привет"
            log(f"{'SSE' if stream else 'JSON'} | {len(content)}ch")
            raw = call_cw(content)
            text = parse_response(raw)
            log(f"  OK {len(text)}ch")

            if stream:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                msg_id = f"msg_{uuid.uuid4().hex[:20]}"

                def ev(d):
                    self.wfile.write(f"data: {json.dumps(d)}\n\n".encode())
                    self.wfile.flush()

                ev({"type": "message_start", "message": {
                    "id": msg_id, "type": "message", "role": "assistant",
                    "content": [], "model": model, "stop_reason": None,
                    "usage": {"input_tokens": 1, "output_tokens": 0}
                }})
                ev({"type": "content_block_start", "index": 0,
                    "content_block": {"type": "text", "text": ""}})
                for i in range(0, len(text), 100):
                    ev({"type": "content_block_delta", "index": 0,
                        "delta": {"type": "text_delta", "text": text[i:i+100]}})
                ev({"type": "content_block_stop", "index": 0})
                ev({"type": "message_delta",
                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                    "usage": {"output_tokens": len(text.split())}})
                ev({"type": "message_stop"})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            else:
                resp = json.dumps({
                    "id": f"msg_{uuid.uuid4().hex[:20]}",
                    "type": "message", "role": "assistant",
                    "content": [{"type": "text", "text": text}],
                    "model": model, "stop_reason": "end_turn", "stop_sequence": None,
                    "usage": {"input_tokens": 1, "output_tokens": len(text.split())}
                }).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(resp)))
                self.end_headers()
                self.wfile.write(resp)

        except urllib.error.HTTPError as e:
            msg = e.read().decode("utf-8", "replace")[:200]
            log(f"  HTTP {e.code}: {msg}")
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": {"type": "api_error",
                "message": f"Kiro API {e.code}: {msg}"}}).encode())
        except Exception as e:
            log(f"  ERR: {e}")
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": {"type": "api_error",
                "message": str(e)}}).encode())

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 3456), ProxyHandler)
    log("Kiro proxy запущен на http://127.0.0.1:3456")
    try:
        tok = get_valid_token()
        log(f"Токен: {tok[:20]}...")
    except Exception as e:
        log(f"ПРЕДУПРЕЖДЕНИЕ: {e}")
    server.serve_forever()
PROXY_EOF

chmod +x "$PROXY_PATH"
info "Прокси установлен: $PROXY_PATH"

# ─── 6. Скрипт переавторизации ───────────────────────────────────────────────
step "Скрипт переавторизации"

cat > "$REAUTH_SCRIPT" << REAUTH_EOF
#!/bin/bash
# Переавторизация Kiro (запускать при истечении токена)
export PATH="\$HOME/.local/bin:/snap/bin:\$PATH"
set -e

echo "=== Kiro Re-Auth ==="
echo "Останавливаю прокси..."
python3 -c "
import subprocess, os, signal
r = subprocess.run(['pgrep','-f','kiro_proxy'], capture_output=True, text=True)
for p in r.stdout.strip().split():
    try: os.kill(int(p), signal.SIGTERM)
    except: pass
" 2>/dev/null

echo ""
echo "Сейчас появится ссылка. Откройте её с VPN/нероссийского IP."
echo ""
\$HOME/.local/bin/kiro-cli logout 2>/dev/null || true
\$HOME/.local/bin/kiro-cli login --license free --use-device-flow

echo ""
echo "=== Запускаю прокси заново ==="
sleep 2
setsid python3 ~/kiro_proxy.py > /tmp/kiro_proxy.log 2>&1 < /dev/null &
sleep 3
curl -s http://127.0.0.1:3456/ && echo " — прокси работает!"
echo "Готово!"
REAUTH_EOF

chmod +x "$REAUTH_SCRIPT"
info "Скрипт переавторизации: $REAUTH_SCRIPT"

# ─── 7. Настройка .bashrc ────────────────────────────────────────────────────
step "Настройка окружения"

for RC in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
    [ -f "$RC" ] || continue
    grep -q "ANTHROPIC_BASE_URL" "$RC" && continue
    cat >> "$RC" << ENV_EOF

# Kiro free tier → Claude Code
export ANTHROPIC_BASE_URL="http://127.0.0.1:$PROXY_PORT"
export ANTHROPIC_API_KEY="kiro-free"
export PATH="\$HOME/.local/bin:/snap/bin:\$PATH"
ENV_EOF
    info "Настроено в $RC"
done

# ─── 8. Cron watchdog ────────────────────────────────────────────────────────
step "Настройка автозапуска"

python3 - << PYEOF
import subprocess, sys

PROXY = "$PROXY_PATH"
LOG   = "$LOG_FILE"
CRON_LINE = f"* * * * * pgrep -f kiro_proxy.py > /dev/null || setsid python3 {PROXY} > {LOG} 2>&1 < /dev/null &"

result = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
current = result.stdout if result.returncode == 0 else ""
lines = [l for l in current.splitlines() if "kiro_proxy" not in l]
lines.append(CRON_LINE)
proc = subprocess.run(["crontab", "-"], input="\n".join(lines)+"\n", text=True, capture_output=True)
if proc.returncode == 0:
    print("[OK] Cron watchdog: прокси будет автоматически перезапускаться")
else:
    print(f"[WARN] Cron не настроен ({proc.stderr.strip()}) — запустите прокси вручную при перезапуске")
PYEOF

# ─── 9. Запуск прокси ────────────────────────────────────────────────────────
step "Запуск прокси"

# Убиваем старые экземпляры если есть
python3 -c "
import subprocess, os, signal, time
r = subprocess.run(['pgrep','-f','kiro_proxy'], capture_output=True, text=True)
for p in r.stdout.strip().split():
    try: os.kill(int(p), signal.SIGTERM)
    except: pass
if r.stdout.strip(): time.sleep(1)
" 2>/dev/null || true

setsid python3 "$PROXY_PATH" > "$LOG_FILE" 2>&1 < /dev/null &
sleep 4

if curl -s "http://127.0.0.1:$PROXY_PORT/" 2>/dev/null | grep -q "kiro"; then
    info "Прокси запущен на порту $PROXY_PORT"
else
    warn "Прокси не ответил. Проверьте: tail -20 $LOG_FILE"
fi

# ─── 10. Финальный тест ──────────────────────────────────────────────────────
step "Тест Claude Code"

export ANTHROPIC_BASE_URL="http://127.0.0.1:$PROXY_PORT"
export ANTHROPIC_API_KEY="kiro-free"

CLAUDE_CMD="$HOME/.local/bin/claude"
[ -x "$CLAUDE_CMD" ] || CLAUDE_CMD="claude"

if RESPONSE=$(echo "Ответь одним словом: работаешь?" | "$CLAUDE_CMD" --print 2>/dev/null); then
    info "Claude Code работает: $RESPONSE"
else
    warn "Claude Code не ответил. Попробуйте:"
    warn "  source ~/.bashrc && claude --print 'тест'"
fi

# ─── Итог ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║     Free Claude Gateway установлен успешно!           ║${NC}"
echo -e "${BOLD}${GREEN}╠═══════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Активируйте в текущей сессии:                         ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}    ${CYAN}source ~/.bashrc${NC}                                   ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}    ${CYAN}claude${NC}          # интерактивный режим              ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}    ${CYAN}claude --print 'вопрос'${NC}                           ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}                                                        ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Токен: ${YELLOW}обновляется автоматически каждый час${NC}         ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Если сломалась авторизация:                           ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}    ${CYAN}~/kiro-reauth.sh${NC}                                   ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Лог прокси:                                           ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}║${NC}    ${CYAN}tail -f $LOG_FILE${NC}                          ${BOLD}${GREEN}║${NC}"
echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
