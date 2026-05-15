# zsh-llm-correct

A tiny [oh-my-zsh](https://ohmyz.sh) plugin that watches for failed commands and asks a **local Ollama** model (default `qwen2.5:7b`, no-thinking mode) to suggest a one-line fix.

The suggestion **streams** token-by-token directly into your prompt:

```
$ gti status
zsh: command not found: gti
💡 git status ? [Y/n]
```

Press `<Enter>` / `y` to run it, anything else to dismiss.

## Why

`thefuck` is great but slow on cold start and fully rule-based. `zsh-llm-correct` keeps inference local, has zero Python startup cost, and learns nothing about you that doesn't stay on your machine.

## Requirements

- `zsh` + [oh-my-zsh](https://ohmyz.sh)
- [`ollama`](https://ollama.com) running locally (`ollama serve`)
- A pulled model — default is `qwen2.5:7b`:
  ```sh
  ollama pull qwen2.5:7b
  ```
- `curl` and `jq` (`brew install jq`)

## Install

```sh
git clone https://github.com/mejistus/zsh-llm-correct \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-llm-correct
```

Then add it to your `~/.zshrc`:

```sh
plugins=(... zsh-llm-correct)
```

Reload: `exec zsh`.

## Usage

Just use your shell normally. Whenever a command exits non-zero (and isn't a signal/interrupt), a single-line suggestion streams in. Accept with `y`/`Enter`, reject with anything else.

You can also invoke it manually:

```sh
llm-fix gti pus orign main
```

## Configuration

All optional, set in `~/.zshrc` **before** the `plugins=(...)` line:

| Variable                          | Default                  | Purpose                                                              |
| --------------------------------- | ------------------------ | -------------------------------------------------------------------- |
| `ZSH_LLM_CORRECT_OLLAMA_URL`      | `http://localhost:11434` | Ollama HTTP endpoint                                                 |
| `ZSH_LLM_CORRECT_MODEL`           | `qwen2.5:7b`             | Any model you've `ollama pull`-ed                                    |
| `ZSH_LLM_CORRECT_MIN_LEN`         | `2`                      | Skip very short commands                                             |
| `ZSH_LLM_CORRECT_DISABLE`         | *(unset)*                | Set to `1` to silence without unloading                              |
| `ZSH_LLM_CORRECT_HISTORY_LIMIT`   | `0`                      | **Conversational mode**: number of recent commands fed as context. `0` = off (default). See note below. |
| `ZSH_LLM_CORRECT_OUTPUT_LIMIT`    | `256`                    | Max chars of captured stderr sent as context                         |
| `ZSH_LLM_CORRECT_CONTEXT_LIMIT`   | `4096`                   | Total context byte budget (~1024 tokens at ~4 bytes/token)           |
| `ZSH_LLM_CORRECT_CAPTURE_OUTPUT`  | `0`                      | Set to `1` to enable session-wide stderr capture (see note below)    |
| `ZSH_LLM_CORRECT_DEBUG`           | `0`                      | Set to `1` to print the full prompt + model name on stderr           |

Examples:

```sh
# Use a different model
export ZSH_LLM_CORRECT_MODEL=qwen2.5-coder:7b

# Conversational mode: feed last 5 commands + capture stderr
# (Recommended only with a 14B+ model — see note)
export ZSH_LLM_CORRECT_MODEL=qwen2.5:14b
export ZSH_LLM_CORRECT_HISTORY_LIMIT=5
export ZSH_LLM_CORRECT_CAPTURE_OUTPUT=1
```

### Note on conversational mode (history + stderr capture)

Both `ZSH_LLM_CORRECT_HISTORY_LIMIT` and `ZSH_LLM_CORRECT_CAPTURE_OUTPUT` default to **off** because in testing on `qwen2.5:7b` they regressed many cases — the small model would copy tokens from prior commands into its fix (e.g., after running `split foo.tar.gz -b 40M`, typing `gss` got "fixed" to `gs split foo.tar.gz -b 40M`). Even an explicit "do not copy from this" instruction in the prompt was not reliably honored.

If you have the VRAM, **`qwen2.5:14b` and `qwen2.5:32b` handle the extra context much more sanely** — that's where these features become genuinely useful (the model can correlate "you just `cd`'d into a python project, the typo is probably `python` not `perl`").

The `CAPTURE_OUTPUT` flag installs a session-wide `exec 2> >(tee ...)` redirect on the shell. tty programs (vim, less, ssh password prompts) keep working because tee passes through, but ANSI escapes can pollute the captured log; we strip them before sending. The log is truncated before each command, so only the most recent stderr is kept.

## Keeping Ollama + qwen2.5 running 24/7

For instant suggestions, two things need to be true:

1. `ollama serve` must be running.
2. The `qwen2.5:7b` model must be **resident in memory** (Ollama unloads idle models after `OLLAMA_KEEP_ALIVE`, default **5 minutes**).

Set `OLLAMA_KEEP_ALIVE=24h` (or `-1` for "until the daemon stops") to keep the model hot.

### macOS (launchd)

If you use the official Ollama desktop app, it already auto-starts at login via the menu-bar app — you only need to set the keep-alive env var. Open it once via Spotlight, then right-click the menu bar icon and quit, OR run:

```sh
launchctl setenv OLLAMA_KEEP_ALIVE 24h
# then restart Ollama: quit from menu bar and relaunch
```

For a **headless setup** (no menu-bar app — daemon only), create a LaunchAgent:

```sh
cat > ~/Library/LaunchAgents/com.ollama.serve.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.ollama.serve</string>
  <key>ProgramArguments</key> <array>
    <string>/opt/homebrew/bin/ollama</string>
    <string>serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_KEEP_ALIVE</key> <string>24h</string>
    <key>OLLAMA_HOST</key>       <string>127.0.0.1:11434</string>
  </dict>
  <key>RunAtLoad</key>          <true/>
  <key>KeepAlive</key>          <true/>
  <key>StandardOutPath</key>    <string>/tmp/ollama.out.log</string>
  <key>StandardErrorPath</key>  <string>/tmp/ollama.err.log</string>
</dict>
</plist>
EOF

# (adjust /opt/homebrew/bin/ollama -> /usr/local/bin/ollama on Intel Macs)
launchctl unload  ~/Library/LaunchAgents/com.ollama.serve.plist 2>/dev/null
launchctl load -w ~/Library/LaunchAgents/com.ollama.serve.plist

# Pre-warm the model so the first prompt is instant
curl -s http://localhost:11434/api/generate \
  -d '{"model":"qwen2.5:7b","prompt":"hi","keep_alive":"24h"}' >/dev/null
```

Verify it's resident: `ollama ps` — `qwen2.5:7b` should be listed with a non-zero `UNTIL`.

### Linux (systemd)

Most distros' Ollama installer (`curl -fsSL https://ollama.com/install.sh | sh`) already creates `/etc/systemd/system/ollama.service`. To enable + add the keep-alive env var:

```sh
sudo systemctl edit ollama.service
```

Add:

```ini
[Service]
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_HOST=127.0.0.1:11434"
```

Save, exit, then:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now ollama.service

# Pre-warm the model
curl -s http://localhost:11434/api/generate \
  -d '{"model":"qwen2.5:7b","prompt":"hi","keep_alive":"24h"}' >/dev/null
```

If you don't have the systemd unit (manual install), create one:

```sh
sudo tee /etc/systemd/system/ollama.service >/dev/null <<'EOF'
[Unit]
Description=Ollama
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_HOST=127.0.0.1:11434"
User=ollama
Group=ollama
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

sudo useradd -r -s /bin/false -d /usr/share/ollama ollama 2>/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now ollama
```

Verify: `systemctl status ollama` and `ollama ps`.

### Auto-warming on shell start (optional)

If you don't want to deal with `keep_alive` semantics, you can re-warm the model whenever a new shell starts. Add to `~/.zshrc`:

```sh
# Fire-and-forget warm-up on shell start (1-token request).
(curl -sf -m 2 -X POST http://localhost:11434/api/generate \
  -d '{"model":"qwen2.5:7b","prompt":"","keep_alive":"24h"}' >/dev/null &) 2>/dev/null
```

This keeps qwen2.5:7b loaded for 24h after each new shell.

## How it works

- Hooks `preexec` to remember the last command line.
- Hooks `precmd` to read `$?`; on a non-zero, non-signal exit, builds a small **environment context** for the model and posts the failed command to `POST /api/generate` with `stream: true` and `think: false`.
- The context lists user-defined commands the model can't know from training:
  - **Aliases** whose name shares the typo's 2-char prefix
  - **Functions** whose name shares the typo's 2-char prefix
  - **PATH executables** containing the failed token as a substring (only for tokens ≥4 chars; avoids noise like `*hi*` matching everything)

  This is intentionally narrow — dumping every `g*` PATH command for a `gti` typo confuses the model and causes it to pick noise. Standard typos (`gti→git`, `pythn→python`, `find . png`) are left to the model's own training; the context's job is to surface things only your shell knows about (custom aliases like `gs='git status'`, project-local CLIs in PATH, autoloaded functions).

- Distinguishes three failure modes:
  - **command-exists, usage error**: the binary IS installed; fix only the arguments (`split foo.tar.gz -b 40M` → `split -b 40M foo.tar.gz`).
  - **command-not-found, looks like a typo**: rank every PATH command + alias + function by Damerau-Levenshtein distance, surface the closest matches as ranked context (`ddust` → `dust(d=1) ddgs(d=2) ...` → model picks `dust`).
  - **command-not-found, looks like natural language**: input has ≥3 words and contains common English filler (`for`, `with`, `to`, `how`, `what`, `me`, `my`, …). Switch to a translate-intent prompt (`tlp for cpu time` → `top -o cpu`, `how big is this folder` → `du -sh .`).
- Optionally (off by default) feeds the last few commands and the previous command's stderr as context — capped to `ZSH_LLM_CORRECT_CONTEXT_LIMIT` bytes total.
- Streams `response` tokens to stdout so you see typing in real time.
- If the model returns `NOFIX`, echoes the input unchanged, or suggests a command name that doesn't actually resolve on this shell (`whence` check), the suggestion is dismissed and a one-line reason is printed (`(no fix)`, `(unchanged — no fix)`, or `(unknown command: X — dismissed)`) so you can tell why no `[Y/n]` prompt appeared.
- On accept, the corrected command is `print -s`-pushed into history and `eval`-ed.

## License

MIT © [mejistus](https://github.com/mejistus)
