# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this repo is

A single-file installer that gives `claude` (Claude Code CLI) a free backend via
Amazon Kiro / CodeWhisperer. There is no application code, build system, test
suite, or CI. Everything users run comes from `install.sh`.

```
README.md            Russian-language user docs: one-line install, usage, requirements
install.sh           The installer (bash, ~470 lines). The only shipped artifact.
alibi-game/          Unrelated: a journal for a live detective quiz game ("The Alibi"),
                     kept in Russian. Do not treat as project code.
```

## install.sh structure

The script is linear and numbered with `# ─── N. ... ───` section banners. Keep
that layout when editing; add new steps as new numbered sections.

1. Dependencies: `python3`, `curl` via `install_pkg` (apt / yum / dnf).
2. `kiro-cli` install.
3. Claude Code install.
4. Kiro auth: `check_token`, `do_login` (logs out first to avoid "Already logged in").
5. Writes `~/kiro_proxy.py` via heredoc — a Python proxy on `PROXY_PORT`
   (default 3456) that auto-refreshes the token. This replaced the earlier
   `claude-code-router` approach; README's "Что делает скрипт" still describes
   CCR and is out of date.
6. Writes `~/kiro-reauth.sh` (re-auth helper, exposed as `claude-kiro-auth`).
7. Appends `ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` exports to `~/.bashrc`.
8. Installs a cron watchdog for the proxy.
9. Starts the proxy (kills stale instances first).
10. Final smoke test, then a summary.

Key paths are variables at the top: `PROXY_PATH`, `TOKEN_FILE`, `KIRO_CACHE`,
`LOG_FILE`, `REAUTH_SCRIPT`. Helpers: `info`, `warn`, `step`, `fatal`.
The script runs under `set -euo pipefail`; every external command that may
legitimately fail must be guarded (`|| true`, `2>/dev/null`, or an `if`).

## Conventions

- Language: user-facing strings, comments, and README are in Russian. Keep it that way.
- The installer must stay a single self-contained file: users run it with
  `curl ... | bash`, so no sourcing of sibling files and no interactive prompts
  other than the Kiro login flow.
- Embedded files (`kiro_proxy.py`, `kiro-reauth.sh`) live inside quoted heredocs
  in `install.sh`. Edit them there; do not split them out.
- Target platforms: Linux with apt, yum, or dnf. No macOS support is claimed.
- Commit messages are short imperative English summaries (see `git log`).

## Verifying changes

There are no tests. Before committing an `install.sh` change:

```bash
bash -n install.sh                 # syntax check
shellcheck install.sh              # if available
python3 - <<'EOF'                  # syntax-check the embedded proxy
import re,ast,sys
src=open('install.sh').read()
m=re.search(r"cat > \"\$PROXY_PATH\" << 'PROXY_EOF'\n(.*?)\nPROXY_EOF", src, re.S)
ast.parse(m.group(1)) if m else sys.exit("proxy heredoc not found")
EOF
```

A full end-to-end run needs network access to AWS endpoints and an Amazon
account, so it cannot be exercised in a sandbox.

## When editing README.md

Keep the one-line install command pointing at
`https://raw.githubusercontent.com/ankor1403/free-claude-public/main/install.sh`.
If the installer's behaviour changes, update the "Что делает скрипт" list to match.
