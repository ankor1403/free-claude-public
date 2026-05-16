# Free Claude Code Gateway

Бесплатный доступ к Claude Code через Amazon Kiro/CodeWhisperer.  
Работает на **любом сервере**, включая российские IP (Cloud.ru, Beget и т.д.)

## Установка одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/ankor1403/free-claude-public/main/install.sh | bash
```

## Что делает скрипт

1. Устанавливает `claude-code-router` (npm)
2. Выполняет авторизацию через Amazon Builder ID (бесплатно)  
3. Запускает CCR как фоновый сервис (опционально systemd)
4. Настраивает переменные окружения для Claude Code

## Использование

После установки:

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:3456"
export ANTHROPIC_API_KEY="kiro-free"
claude
```

В новых терминалах работает автоматически (добавляется в `.bashrc`).

## Переавторизация

Токен действует ~8 часов, CCR обновляет автоматически. При необходимости:

```bash
claude-kiro-auth
```

## Требования

- Linux (Ubuntu/Debian/RHEL/CentOS)
- curl, python3
- Интернет-доступ к AWS (oidc.us-east-1.amazonaws.com, codewhisperer.us-east-1.amazonaws.com)
- Amazon аккаунт (бесплатный, создать на amazon.com)

## После установки: верификация аккаунта

После первой авторизации обязательно откройте https://app.kiro.dev и примите Terms of Service тем же Amazon аккаунтом.
