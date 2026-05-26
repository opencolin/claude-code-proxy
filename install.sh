#!/usr/bin/env bash
# install.sh — TUI-style bootstrap for claude-code-proxy.
#
# Walks through each step.  If a step fails, it prints the fix and
# prompts to retry rather than exiting into a wall of stderr.

set -uo pipefail

# ─── Colors ─────────────────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_ICYAN='\033[38;5;45m'
C_PURPLE='\033[38;5;129m'
C_GREEN='\033[38;5;46m'
C_YELLOW='\033[38;5;220m'
C_RED='\033[38;5;197m'
C_GRAY='\033[38;5;244m'
C_BLUE='\033[38;5;75m'
C_DIM='\033[38;5;239m'

print_banner() {
    clear 2>/dev/null || true
    printf '\n'
    printf '    %b▐▛▜▌%b  %bClaude Code Proxy for Nebius%b\n' "$C_ICYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '    %b─────────────────────────────%b\n\n' "$C_GRAY" "$C_RESET"
    printf '    This script checks prerequisites, creates a virtual\n'
    printf '    environment, and validates your API key.\n\n'
}

step_header() {
    local n=$1 title=$2
    printf '  %b[%d/6]%b %b%s%b\n' "$C_GRAY" "$n" "$C_RESET" "$C_BOLD" "$title" "$C_RESET"
}

ok()   { printf '       %b✔%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '       %b⚠%b %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf '       %b✘%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
info() { printf '       %b▸%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
dim()  { printf '       %b%s%b\n' "$C_DIM" "$*" "$C_RESET"; }

prompt_yesno() {
    local msg=$1 default=${2:-Y}
    local d_prompt
    if [[ "$default" == "N" ]]; then
        d_prompt=$(printf '[y/%bN%b]' "$C_RED" "$C_RESET")
    else
        d_prompt=$(printf '[%bY%b/n]' "$C_GREEN" "$C_RESET")
    fi
    printf '%s %s: ' "$msg" "$d_prompt"
    local ans
    read -r ans
    ans=${ans:-$default}
    [[ "$ans" =~ ^[Yy] ]]
}

pause_and_retry() {
    printf '\n     Press %bEnter%b to re-check, or %bQ%b to quit: ' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    local key
    read -r key
    [[ "$key" != "q" && "$key" != "Q" ]]
}

# ─── Step 1: Prerequisites ────────────────────────────────────────
step_01_prerequisites() {
    step_header 1 "Checking Prerequisites"

    local py_ok=false py_ver="" curl_ok=false pip_ok=false cert_warning=""

    while true; do
        # Python
        if command -v python3 &>/dev/null; then
            py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
            if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)' 2>/dev/null; then
                py_ok=true
            fi
        fi

        # curl
        if command -v curl &>/dev/null; then
            curl_ok=true
        fi

        # pip (maybe available via ensurepip? we'll check later)
        if python3 -m pip --version &>/dev/null 2>&1; then
            pip_ok=true
        fi

        # Check certs on macOS
        if [[ "$OSTYPE" == darwin* ]] && python3 -c "import ssl" &>/dev/null; then
            python3 -c "import urllib.request; urllib.request.urlopen('https://ssl-config.mozilla.org', timeout=5)" 2>/dev/null || {
                cert_warning="macOS root certificates not configured for Python"
            }
        fi

        if $py_ok && $curl_ok; then
            ok "python3 $py_ver"
            ok "curl available"
            $pip_ok && ok "pip available"
            [[ -n "$cert_warning" ]] && warn "$cert_warning"
            break
        fi

        if ! $py_ok; then
            fail "Python >= 3.9 required"
            if [[ "$OSTYPE" == darwin* ]]; then
                info "Fix:   brew install python3"
            else
                info "Fix:   sudo apt install python3 python3-pip"
            fi
        fi
        if ! $curl_ok; then
            fail "curl not found"
        fi
        if ! $pip_ok; then
            warn "pip not found — will install with ensurepip in Step 2"
        fi
        if [[ -n "$cert_warning" ]]; then
            fail "$cert_warning"
            info "Fix:    open /Applications/Python\ 3.x/Install\ Certificates.command"
            info "   or:  python3 -m pip install --upgrade certifi"
        fi

        pause_and_retry || { echo; exit 1; }
        printf '\n'
    done
}

# ─── Step 2: Virtual Environment ────────────────────────────────
step_02_venv() {
    step_header 2 "Virtual Environment"

    if [[ -d .venv ]]; then
        ok ".venv already exists"
        return 0
    fi

    while true; do
        info "Creating .venv …"
        if python3 -m venv .venv 2>&1; then
            ok ".venv created"
            break
        else
            fail "Could not create .venv"
            info "Fix:   python3 -m ensurepip --upgrade"
            info "   or: python3 -m venv .venv --system-site-packages"
            pause_and_retry || { echo; exit 1; }
        fi
    done
}

# ─── Step 3: Dependencies ───────────────────────────────────────
step_03_dependencies() {
    step_header 3 "Installing Dependencies"

    # Upgrade pip first
    while true; do
        info "Upgrading pip …"
        if .venv/bin/python -m pip install --quiet --upgrade pip 2>&1; then
            ok "pip upgraded"
            break
        else
            fail "pip upgrade failed"
            info "Fix:   .venv/bin/python -m ensurepip --upgrade"
            pause_and_retry || { echo; exit 1; }
        fi
    done

    # Install requirements
    while true; do
        info "Installing from requirements.txt …"
        if .venv/bin/pip install -q -r requirements.txt 2>&1 >/dev/null; then
            ok "dependencies installed"
            break
        else
            fail "pip install failed"
            info "Fix:   .venv/bin/pip install -r requirements.txt --upgrade"
            pause_and_retry || { echo; exit 1; }
        fi
    done
}

# ─── Step 4: Environment File ───────────────────────────────────
step_04_env() {
    step_header 4 "API Key & Environment"

    # Re-use existing .env
    if [[ -f .env ]]; then
        ok ".env already exists"
        local existing_key
        existing_key=$(grep -E '^OPENAI_API_KEY=' .env | cut -d= -f2 | tr -d '"' | head -n1)
        if [[ "$existing_key" =~ ^(YOUR_NEBIUS|v1\.) ]]; then
            : # looks valid enough
        else
            warn "key in .env looks unusual — edit manually if needed"
        fi
        return 0
    fi

    cp .env.example .env
    chmod 600 .env
    chmod +w .env

    # Prompt for key
    local key=""
    while [[ -z "$key" ]]; do
        printf '       %bPaste your Nebius API key%b (%bhidden, Enter when done%b): ' "$C_GRAY" "$C_RESET" "$C_YELLOW" "$C_RESET"
        read -rs key
        echo
        if [[ -z "$key" ]]; then
            fail "No key provided"
            if ! prompt_yesno "Try again"; then
                rm -f .env
                echo; exit 1
            fi
        fi
    done

    # Write key into .env
    sed -i.bak "s|^OPENAI_API_KEY=.*$|OPENAI_API_KEY=$key|" .env && rm -f .env.bak
    ok ".env created"
}

# ─── Step 5: Model Validation ─────────────────────────────────────
step_05_validate_models() {
    step_header 5 "Validating Models with Nebius"

    .venv/bin/python <<'PY'
import json, pathlib, sys, urllib.request, urllib.error, ssl

# ─ helpers ─
def get_env():
    env = {}
    for line in pathlib.Path(".env").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'").split("#",1)[0].strip()
    return env

def c(text, color):
    codes = {"red":"\033[38;5;197m", "green":"\033[38;5;46m",
             "yellow":"\033[38;5;220m", "gray":"\033[38;5;244m",
             "reset":"\033[0m", "bold":"\033[1m", "blue":"\033[38;5;75m"}
    return f"{codes[color]}{text}{codes['reset']}"

def print_box(label, lines):
    off = " " * 7
    max_w = max(len(l) for l in lines) if lines else 0
    print(f"{off}{c('─', 'gray')}─" + "─" * (max_w + 2) + c("─", "gray"))
    for l in lines:
        print(f"{off}{c('│ ', 'gray')}{l:<{max_w}} {c('│', 'gray')}")
    print(f"{off}{c('─', 'gray')}─" + "─" * (max_w + 2) + c("─", "gray"))

env = get_env()
key  = env.get("OPENAI_API_KEY", "")
base = env.get("OPENAI_BASE_URL", "https://api.tokenfactory.nebius.com/v1").rstrip("/")

# Try to fetch /models with helpful error handling
try:
    ctx = ssl.create_default_context()
    req = urllib.request.Request(f"{base}/models", headers={"Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
        data = json.load(r)
except urllib.error.HTTPError as e:
    if e.code in (401, 403):
        print(c("     ✘ ", "red") + f"Authorization failed ({e.code}).  Check your API key.")
        sys.exit(1)
    print(c("     ✘ ", "red") + f"HTTP error {e.code}: {e.reason}")
    sys.exit(1)
except urllib.error.URLError as e:
    reason = getattr(e, 'reason', e)
    if 'SSL' in str(reason) or 'CERTIFICATE_VERIFY_FAILED' in str(reason):
        print(c("     ✘ ", "red") + "SSL certificate verification failed.")
        print(c("     ▸ ", "blue") + "Fix:   python3 -m pip install --upgrade certifi")
        if sys.platform == "darwin":
            print(c("     ▸ ", "blue") + "   or:  open /Applications/Python\\ 3.x/Install\\ Certificates.command")
    elif "Temporary failure in name resolution" in str(reason) or "getaddrinfo" in str(reason):
        print(c("     ✘ ", "red") + f"Unable to resolve {base} — check your network connection.")
    else:
        print(c("     ✘ ", "red") + f"Could not reach Nebius: {reason}")
    sys.exit(1)
except Exception as e:
    print(c("     ✘ ", "red") + f"Could not list models: {e}")
    sys.exit(1)

available = {m["id"] for m in data.get("data", [])}

model_keys = ["BIG_MODEL", "MIDDLE_MODEL", "SMALL_MODEL", "VISION_MODEL"]
configured = {k: env[k] for k in model_keys if env.get(k)}
missing = {k: v for k, v in configured.items() if v not in available}

if missing:
    print(c("     ⚠ ", "yellow") + "Some configured models are not available:\n")
    lines = [f"  {k}={v}" for k, v in missing.items()]
    lines.append("")
    lines.append(c("Available models on Nebius:", "bold"))
    for m in sorted(available)[:20]:
        lines.append(f"  {m}")
    if len(available) > 20:
        lines.append(f"  ... and {len(available)-20} more")
    print_box("Models", lines)

    print("\n" + c("     ▸ ", "blue") + "Your .env has been updated with available models automatically.\n")

    # Auto-update with smart defaults
    def pick(kind, candidates):
        for c in candidates:
            if c in available:
                return c
        return sorted(available)[0]

    defaults = {
        "BIG_MODEL": pick("big", ["deepseek-ai/DeepSeek-V4-Pro",
                                  "Qwen/Qwen3-235B-A22B-Instruct-2507",
                                  "meta-llama/Llama-3.3-70B-Instruct"]),
        "MIDDLE_MODEL": pick("mid", ["deepseek-ai/DeepSeek-V3.2",
                                       "Qwen/Qwen3-235B-A22B-Instruct-2507",
                                       "meta-llama/Llama-3.3-70B-Instruct"]),
        "SMALL_MODEL": pick("small", ["deepseek-ai/DeepSeek-V3.2",
                                      "Qwen/Qwen3-32B",
                                      "meta-llama/Llama-3.3-70B-Instruct"]),
        "VISION_MODEL": pick("vision", ["Qwen/Qwen2.5-VL-72B-Instruct",
                                        "Qwen/Qwen3-235B-A22B-Instruct-2507"]),
    }

    # Only update keys that were actually configured
    for k in model_keys:
        if k in configured:
            env[k] = defaults[k]

    # Rewrite .env
    new_lines = []
    for line in pathlib.Path(".env").read_text().splitlines():
        stripped = line.strip()
        matched = False
        for k in model_keys:
            if stripped.startswith(f"{k}="):
                val = env.get(k, configured.get(k, defaults[k]))
                new_lines.append(f"{k}={val}")
                matched = True
                break
        if not matched:
            new_lines.append(line)

    pathlib.Path(".env").write_text("\n".join(new_lines) + "\n")

    print(c("     ✔ ", "green") + ".env updated with valid model IDs")
else:
    print(c("     ✔ ", "green") + f"All {len(configured)} models are available on Nebius")
PY
}

# ─── Step 6: Connection Smoke Test ──────────────────────────────
step_06_smoke_test() {
    step_header 6 "Proxy Connection Test"

    local port log pid
    port=$(grep -E '^PORT=' .env 2>/dev/null | tail -n1 | cut -d= -f2 | tr -d '"')
    port=${port:-8083}
    log=$(mktemp -t claude-proxy-smoke.XXXXXX.log)

    info "Starting proxy on port $port ..."
    .venv/bin/python start_proxy.py >"$log" 2>&1 &
    pid=$!

    # Cleanup on EXIT only (not when returning success)
    to_clean() { :; }
    trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT

    local waited=0 attempts=40
    for ((i=0; i<attempts; i++)); do
        sleep 0.5
        waited=$((i+1))
        if curl -sf -m 2 "http://localhost:${port}/health" >/dev/null 2>&1; then
            ok "Proxy responded on port $port"
            break
        fi
    done

    if ! curl -sf -m 2 "http://localhost:${port}/health" >/dev/null 2>&1; then
        fail "Proxy did not start within ${waited}s"
        printf '       %bLast 15 log lines:%b\n' "$C_DIM" "$C_RESET"
        tail -15 "$log" | sed 's/^/       /'
        printf '\n       %b▸%b Check %s\n' "$C_BLUE" "$C_RESET" "$log"
        exit 1
    fi

    local result status
    result=$(curl -s -m 30 "http://localhost:${port}/test-connection" 2>/dev/null || echo '{"status":"failed"}')
    status=$(printf '%s' "$result" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null || echo "unknown")

    # Defer cleanup until after we've printed status
    trap - EXIT
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    if [[ "$status" == "success" ]]; then
        ok "Connection test passed"
    else
        fail "Connection test failed (${status})"
        printf '       %s\n' "$result" | sed 's/^/       /'
        exit 1
    fi
}

# ─── Shell Profile ──────────────────────────────────────────────
install_shell_function() {
    printf '\n'
    local pwsh_profile

    pwsh_profile_path() {
        command -v pwsh >/dev/null || return 1
        pwsh -NoLogo -NoProfile -NonInteractive -Command '\$PROFILE' 2>/dev/null \
            | tr -d '\r' | tail -n 1
    }

    detect_shell_profile() {
        local parent_comm parent_name user_shell pwsh_profile
        parent_comm="$(ps -p "${PPID:-0}" -o comm= 2>/dev/null || true)"
        parent_name="${parent_comm##*/}"

        case "$parent_name" in
            bash)
                SHELL_KIND="bash"; SHELL_RC="$HOME/.bashrc"; return
                ;;
            zsh)
                SHELL_KIND="zsh"; SHELL_RC="$HOME/.zshrc"; return
                ;;
            pwsh|pwsh-*|powershell|powershell.exe)
                pwsh_profile="$(pwsh_profile_path || true)"
                if [[ -n "$pwsh_profile" ]]; then
                    SHELL_KIND="pwsh"; SHELL_RC="$pwsh_profile"; return
                fi
                ;;
        esac

        user_shell="${SHELL:-/bin/bash}"
        case "$user_shell" in
            */pwsh|*/pwsh-*|*/powershell|*/powershell.exe)
                pwsh_profile="$(pwsh_profile_path || true)"
                if [[ -n "$pwsh_profile" ]]; then
                    SHELL_KIND="pwsh"; SHELL_RC="$pwsh_profile"
                fi
                ;;
            */zsh)
                SHELL_KIND="zsh"; SHELL_RC="$HOME/.zshrc"
                ;;
            */bash)
                SHELL_KIND="bash"; SHELL_RC="$HOME/.bashrc"
                ;;
            *)
                if [[ -f "$HOME/.zshrc" ]]; then
                    SHELL_KIND="zsh"; SHELL_RC="$HOME/.zshrc"
                elif [[ -f "$HOME/.bashrc" ]]; then
                    SHELL_KIND="bash"; SHELL_RC="$HOME/.bashrc"
                else
                    pwsh_profile="$(pwsh_profile_path || true)"
                    if [[ -n "$pwsh_profile" ]]; then
                        SHELL_KIND="pwsh"; SHELL_RC="$pwsh_profile"
                    fi
                fi
                ;;
        esac
    }

    SHELL_KIND=""; SHELL_RC=""
    detect_shell_profile

    if [[ -z "$SHELL_RC" ]]; then
        warn "Could not detect shell profile — skipped"
        return
    fi

    # Already configured?
    local already=false
    case "$SHELL_KIND" in
        pwsh)
            [[ -f "$SHELL_RC" ]] && grep -Eqi 'function[[:space:]]+(global:)?claude([^[:alnum:]_]|$)' "$SHELL_RC" 2>/dev/null && already=true
            ;;
        *)
            [[ -f "$SHELL_RC" ]] && grep -q "claude() {" "$SHELL_RC" 2>/dev/null && already=true
            ;;
    esac

    if $already; then
        ok "Shell already configured ($SHELL_RC)"
        return
    fi

    if ! prompt_yesno "Add ${SHELL_KIND:-shell} convenience function to $SHELL_RC"; then
        info "Skipped — see docs/SHELL_FUNCTION.md"
        return
    fi

    mkdir -p "$(dirname "$SHELL_RC")"
    [[ -f "$SHELL_RC" ]] || touch "$SHELL_RC"
    cp "$SHELL_RC" "$SHELL_RC.bak.$(date +%s)" 2>/dev/null || true

    # Determine current port from .env
    local port ctx_limit
    port=$(grep -E '^PORT=' .env 2>/dev/null | tail -n1 | cut -d= -f2 | tr -d '"')
    port=${port:-8083}
    ctx_limit=$(grep -E '^BIG_MODEL_CONTEXT_LIMIT=' .env 2>/dev/null | tail -n1 | cut -d= -f2 | tr -d '"')
    ctx_limit=${ctx_limit:-0}

    if [[ "$SHELL_KIND" == "pwsh" ]]; then
        cat >> "$SHELL_RC" <<PWSH_FUNC

# Claude Shell Function - enables claude, claude --proxy, and claudius
function claude {
    param([Parameter(ValueFromRemainingArguments = \$true)] [string[]] \$ClaudeArgs)
    \$mainProxy = "http://localhost:$port"
    \$repoRoot = "$REPO_ROOT"
    \$claudeCommand = (Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    \$oldAuthToken = \$env:ANTHROPIC_AUTH_TOKEN
    \$oldApiKey = \$env:ANTHROPIC_API_KEY
    \$oldBaseUrl = \$env:ANTHROPIC_BASE_URL
    if (\$ClaudeArgs.Count -gt 0 -and \$ClaudeArgs[0] -eq "--proxy") {
        Write-Host "\`e[38;5;129m▐▛▜▌ Claude via Proxy\`e[0m  \`e[38;5;244m-> bearer auth via local proxy\`e[0m"
        \$defaultName = "session-" + (Get-Date -Format "yyyyMMdd-HHmmss")
        Write-Host "Session name [\`e[38;5;75m\$defaultName\`e[0m]: " -NoNewline
        [string] \$sessionName = Read-Host
        if ([string]::IsNullOrWhiteSpace(\$sessionName)) { \$sessionName = \$defaultName }
        [int] \$localPort = python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"
        \$forwarderJob = Start-Job -ScriptBlock {
            param(\$port, \$target, \$name, \$repo)
            python3 "\$repo/scripts/session_forwarder.py" \$port \$target \$name
        } -ArgumentList \$localPort, "localhost:$port", \$sessionName, \$repoRoot
        Start-Sleep -Milliseconds 800
        [string[]] \$remainingArgs = @()
        if (\$ClaudeArgs.Count -gt 1) {
            \$remainingArgs = [string[]] \$ClaudeArgs[1..(\$ClaudeArgs.Count - 1)]
        }
        \$forwarderUrl = "http://localhost:\$localPort"
        try {
            \$env:ANTHROPIC_AUTH_TOKEN = "claude-local"
            Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
            \$env:ANTHROPIC_BASE_URL = \$forwarderUrl
            if ($ctx_limit -gt 0 -and $ctx_limit -lt 1000000) { \$env:ANTHROPIC_MODEL = "claude-opus-4-7" }
            & \$claudeCommand @remainingArgs
        } finally {
            if (\$forwarderJob) { Stop-Job \$forwarderJob -ErrorAction SilentlyContinue; Remove-Job \$forwarderJob -ErrorAction SilentlyContinue }
            if (\$null -eq \$oldAuthToken) { Remove-Item Env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue } else { \$env:ANTHROPIC_AUTH_TOKEN = \$oldAuthToken }
            if (\$null -eq \$oldApiKey) { Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue } else { \$env:ANTHROPIC_API_KEY = \$oldApiKey }
            if (\$null -eq \$oldBaseUrl) { Remove-Item Env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue } else { \$env:ANTHROPIC_BASE_URL = \$oldBaseUrl }
        }
    } else {
        Write-Host "\`e[38;5;46m▐▛▜▌ Claude Direct\`e[0m  \`e[38;5;244m-> subscription login auth\`e[0m"
        try {
            Remove-Item Env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
            & \$claudeCommand @ClaudeArgs
        } finally {
            if (\$null -ne \$oldAuthToken) { \$env:ANTHROPIC_AUTH_TOKEN = \$oldAuthToken }
            if (\$null -ne \$oldApiKey) { \$env:ANTHROPIC_API_KEY = \$oldApiKey }
            if (\$null -ne \$oldBaseUrl) { \$env:ANTHROPIC_BASE_URL = \$oldBaseUrl }
        }
    }
}
function claudius {
    param([Parameter(ValueFromRemainingArguments = \$true)] [string[]] \$ClaudeArgs)
    claude --proxy @ClaudeArgs
}
PWSH_FUNC
        ok "Added to $SHELL_RC"
        info "Restart PowerShell or run:  . \$PROFILE"
    else
        cat >> "$SHELL_RC" <<SHELL_FUNC

# Claude Shell Function — enables claude, claude --proxy, and claudius
claude() {
    local main_proxy="http://localhost:$port"
    local repo_root="$REPO_ROOT"
    if [[ "\$1" == "--proxy" ]]; then
        printf "\033[38;5;129m▐▛▜▌ Claude via Proxy\033[0m  \033[38;5;244m→ bearer auth via local proxy\033[0m\n"
        local default_name="session-\$(date +%Y%m%d-%H%M%S)"
        printf "\033[38;5;244mSession name\033[0m [\033[38;5;75m%s\033[0m]: " "\$default_name"
        read -r session_name
        session_name="\${session_name:-\$default_name}"
        local local_port
        local_port=\$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
        python3 "\$repo_root/scripts/session_forwarder.py" "\$local_port" "localhost:$port" "\$session_name" &
        local forwarder_pid=\$!
        sleep 0.5
        local forwarder_url="http://localhost:\$local_port"
        (
            unset ANTHROPIC_API_KEY
            export ANTHROPIC_AUTH_TOKEN="claude-local"
            export ANTHROPIC_BASE_URL="\$forwarder_url"
            [ -n "$ctx_limit" ] && [ "$ctx_limit" -gt 0 ] && [ "$ctx_limit" -lt 1000000 ] && export ANTHROPIC_MODEL="claude-opus-4-7"
            command claude "\${@:2}"
        )
        local claude_exit=\$?
        kill "\$forwarder_pid" 2>/dev/null || true
        wait "\$forwarder_pid" 2>/dev/null || true
        return \$claude_exit
    else
        printf "\033[38;5;46m▐▛▜▌ Claude Direct\033[0m  \033[38;5;244m→ subscription login auth\033[0m\n"
        (
            unset ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
            command claude "\$@"
        )
    fi
}
alias claudius='claude --proxy'
SHELL_FUNC
        ok "Added to $SHELL_RC"
        info "Run:  source $SHELL_RC"
    fi
}

# ─── Main ───────────────────────────────────────────────────────
main() {
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$REPO_ROOT"

    print_banner

    step_01_prerequisites
    step_02_venv
    step_03_dependencies
    step_04_env
    step_05_validate_models

    if ! step_06_smoke_test; then
        printf '\n  %bInstall incomplete.%b\n' "$C_RED" "$C_RESET"
        printf '  %bFix the issue above, then re-run this script.%b\n\n' "$C_GRAY" "$C_RESET"
        exit 1
    fi

    printf '\n'
    printf '  %b▐▛▜▌%b  %b%bSetup Complete!%b\n\n' "$C_ICYAN" "$C_RESET" "$C_GREEN" "$C_BOLD" "$C_RESET"

    local port
    port=$(grep -E '^PORT=' .env 2>/dev/null | tail -n1 | cut -d= -f2 | tr -d '"')
    port=${port:-8083}

    printf '  %b╭───────────────────────────────────────────────────────────%b\n' "$C_PURPLE" "$C_RESET"
    printf '  %b│%b  %b✔%b Proxy validated on port %s                            %b│%b\n' "$C_PURPLE" "$C_RESET" "$C_GREEN" "$C_RESET" "$port" "$C_PURPLE" "$C_RESET"
    printf '  %b│%b                                                            %b│%b\n' "$C_PURPLE" "$C_RESET" "$C_PURPLE" "$C_RESET"
    printf '  %b│%b  %bStart the proxy:%b                                        %b│%b\n' "$C_PURPLE" "$C_RESET" "$C_GRAY" "$C_RESET" "$C_PURPLE" "$C_RESET"
    printf '  %b│%b    %b.venv/bin/python start_proxy.py%b                        %b│%b\n' "$C_PURPLE" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_PURPLE" "$C_RESET"
    printf '  %b│%b                                                            %b│%b\n' "$C_PURPLE" "$C_RESET" "$C_PURPLE" "$C_RESET"
    printf '  %b│%b  %bUse:%b                                                     %b│%b\n' "$C_PURPLE" "$C_RESET" "$C_GRAY" "$C_RESET" "$C_PURPLE" "$C_RESET"
    printf '  %b│%b    %bclaude --proxy%b   → Nebius via local proxy              %b│%b\n' "$C_PURPLE" "$C_RESET" "$C_PURPLE" "$C_RESET" "$C_PURPLE" "$C_RESET"
    printf '  %b│%b    %bclaude%b            → Direct (subscription)               %b│%b\n' "$C_PURPLE" "$C_RESET" "$C_GREEN" "$C_RESET" "$C_PURPLE" "$C_RESET"
    printf '  %b╰───────────────────────────────────────────────────────────%b\n\n' "$C_PURPLE" "$C_RESET"

    install_shell_function
    printf '\n'
}

main "$@"
