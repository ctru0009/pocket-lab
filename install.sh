#!/usr/bin/env bash
# =============================================================================
# pocket-lab: install.sh
# One-shot installer for push notifications from AI coding tools via Telegram or ntfy.
#
# Supports: Claude Code
# Platforms: Linux, macOS, Windows (Telegram only)
#
# Usage:
#   bash install.sh
#   bash install.sh --uninstall
#   bash install.sh --help
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colours & formatting
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
fatal()   { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}$*${RESET}"; }

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
REPO_URL="https://raw.githubusercontent.com/ctru0009/pocket-lab/main"
INSTALL_DIR="$HOME/.config/pocket-lab"
HOOKS_DIR="$INSTALL_DIR/hooks"
CONFIG_FILE="$INSTALL_DIR/config"
NOTIFY_ENABLED_FILE="$INSTALL_DIR/enabled"
LOG_FILE="$INSTALL_DIR/notify.log"
BIN_DIR="$HOME/.local/bin"

NOTIFY_HOOK="$HOOKS_DIR/notify.sh"
TOGGLE_SCRIPT="$BIN_DIR/pocket-lab"

if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
UNINSTALL=false
SKIP_PROMPTS=false

for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=true ;;
    --yes|-y)    SKIP_PROMPTS=true ;;
    --help|-h)
      echo "Usage: bash install.sh [--uninstall] [--yes] [--help]"
      echo ""
      echo "  --uninstall   Remove pocket-lab from this machine"
      echo "  --yes / -y    Skip confirmation prompts"
      echo "  --help        Show this help"
      exit 0
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
detect_os() {
  case "$(uname -s)" in
    Linux*)  echo "linux" ;;
    Darwin*) echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) echo "windows" ;;
    *)       fatal "Unsupported OS: $(uname -s). Supported platforms are Linux, macOS, and Windows (Telegram only)." ;;
  esac
}

OS=$(detect_os)
info "Detected OS: $OS"

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
check_deps() {
  header "Checking dependencies..."
  local missing=()

  command -v curl &>/dev/null || missing+=("curl")
  command -v bash &>/dev/null || missing+=("bash")
  command -v jq &>/dev/null || missing+=("jq")

  if [[ ${#missing[@]} -gt 0 ]]; then
    fatal "Missing required dependencies: ${missing[*]}. Please install them and re-run."
  fi

  success "All required dependencies found."
}

jq_install_hint() {
  case "$OS" in
    linux)
      if command -v apt-get &>/dev/null; then echo "sudo apt-get install -y jq"
      elif command -v dnf &>/dev/null; then echo "sudo dnf install -y jq"
      elif command -v pacman &>/dev/null; then echo "sudo pacman -S jq"
      else echo "https://jqlang.github.io/jq/download/"
      fi
      ;;
    macos) echo "brew install jq" ;;
  esac
}

# ---------------------------------------------------------------------------
# Detect installed AI tools
# ---------------------------------------------------------------------------
detect_ai_tools() {
  local found=()
  command -v claude  &>/dev/null && found+=("claude")
  echo "${found[@]:-}"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
  header "Uninstalling pocket-lab..."

  # Remove hooks from Claude Code settings
  local claude_settings="$HOME/.claude/settings.json"
  if [[ -f "$claude_settings" ]]; then
    if command -v jq &>/dev/null; then
      local tmp
      tmp=$(mktemp)
      if jq 'del(.hooks.Notification, .hooks.Stop, .hooks.SubagentStop) |
          if .hooks == {} then del(.hooks) else . end' \
        "$claude_settings" > "$tmp"; then
        mv "$tmp" "$claude_settings"
        success "Removed pocket-lab hooks from Claude Code settings."
      else
        rm -f "$tmp"
        fatal "Failed to update $claude_settings."
      fi
    else
      warn "jq not found — please manually remove pocket-lab hook entries from $claude_settings"
    fi
  fi

  # Remove files
  rm -f "$TOGGLE_SCRIPT"
  rm -rf "$INSTALL_DIR"

  success "pocket-lab uninstalled."
  exit 0
}

# ---------------------------------------------------------------------------
# Prompt helper
# ---------------------------------------------------------------------------
prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"
  local value=""
  local prompt_input="/dev/tty"

  if [[ ! -r "$prompt_input" ]]; then
    prompt_input="/dev/stdin"
  fi

  if [[ "$SKIP_PROMPTS" == "true" && -n "$default" ]]; then
    value="$default"
  else
    if [[ -n "$default" ]]; then
      read -rp "$(echo -e "${prompt_text} ${YELLOW}[$default]${RESET}: ")" value < "$prompt_input"
      value="${value:-$default}"
    else
      while [[ -z "$value" ]]; do
        read -rp "$(echo -e "${prompt_text}: ")" value < "$prompt_input"
        [[ -z "$value" ]] && warn "This field is required."
      done
    fi
  fi

  printf -v "$var_name" '%s' "$value"
}

prompt_yn() {
  local prompt_text="$1"
  local default="${2:-n}"
  local answer=""
  local prompt_input="/dev/tty"

  if [[ ! -r "$prompt_input" ]]; then
    prompt_input="/dev/stdin"
  fi

  if [[ "$SKIP_PROMPTS" == "true" ]]; then
    answer="$default"
  else
    read -rp "$(echo -e "${prompt_text} ${YELLOW}[y/N]${RESET}: ")" answer < "$prompt_input"
    answer="${answer:-$default}"
  fi

  [[ "$answer" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Gather config from user
# ---------------------------------------------------------------------------
gather_config() {
  header "Configuration"

  echo ""
  echo "pocket-lab supports two notification providers:"
  echo "  1) Telegram  — bot messages (recommended, no extra app needed)"
  echo "  2) ntfy      — self-hostable push service"
  echo ""

  # ── Provider selection ───────────────────────────────────────────────────
  local notify_provider=""
  while [[ "$notify_provider" != "telegram" && "$notify_provider" != "ntfy" ]]; do
    prompt notify_provider "  Choose provider" "telegram"
    notify_provider=$(echo "$notify_provider" | tr '[:upper:]' '[:lower:]')
    [[ "$notify_provider" != "telegram" && "$notify_provider" != "ntfy" ]] && \
      warn "Please enter 'telegram' or 'ntfy'"
  done

  if [[ "$OS" == "windows" && "$notify_provider" == "ntfy" ]]; then
    fatal "ntfy support is available on Linux and macOS only. On Windows, choose Telegram."
  fi

  # ── Telegram setup ───────────────────────────────────────────────────────
  local telegram_bot_token=""
  local telegram_chat_id=""
  local telegram_silent_on_stop="false"

  if [[ "$notify_provider" == "telegram" ]]; then
    echo ""
    echo "  Telegram setup — 3 quick steps:"
    echo "  ① Open Telegram and search for @BotFather"
    echo "  ② Send /newbot and follow the prompts — you'll get a token like:"
    echo "     110201543:AAHdqTcvCH1vGWJxfSeofSs4thjN7nhxh"
    echo "  ③ Start a chat with your new bot (send it any message first)"
    echo ""

    prompt telegram_bot_token "  Paste your bot token"

    echo ""
    echo "  Now we need your chat ID. Running getUpdates to fetch it..."
    echo "  (Make sure you've sent at least one message to your bot first)"
    echo ""

    # Auto-fetch chat ID
    local fetched_id=""
    fetched_id=$(curl -s "https://api.telegram.org/bot${telegram_bot_token}/getUpdates" \
      | jq -r '.result[-1].message.chat.id // empty' 2>/dev/null || true)

    if [[ -n "$fetched_id" ]]; then
      success "Auto-detected chat ID: $fetched_id"
      telegram_chat_id="$fetched_id"
    else
      warn "Could not auto-detect chat ID."
      echo "  Manual steps:"
      echo "  • Open: https://api.telegram.org/bot${telegram_bot_token}/getUpdates"
      echo "  • Look for: .result[0].message.chat.id"
      prompt telegram_chat_id "  Enter your chat ID manually"
    fi

    if prompt_yn "  Send task-complete notifications silently (no buzz for Stop events)?"; then
      telegram_silent_on_stop="true"
    fi
  fi

  # ── ntfy setup ───────────────────────────────────────────────────────────
  local ntfy_server="https://ntfy.sh"
  local ntfy_topic=""
  local ntfy_token=""

  if [[ "$notify_provider" == "ntfy" ]]; then
    echo ""
    local use_selfhosted="n"
    if prompt_yn "  Are you self-hosting ntfy on your homelab?"; then
      use_selfhosted="y"
    fi

    if [[ "$use_selfhosted" == "y" ]]; then
      prompt ntfy_server "  ntfy server URL (e.g. http://100.x.x.x:8080)"
    else
      info "Using public ntfy.sh — pick a unique, hard-to-guess topic name."
    fi

    local default_topic="pocket-lab-$(openssl rand -hex 4 2>/dev/null || echo 'abc123')"
    prompt ntfy_topic "  ntfy topic name" "$default_topic"

    if prompt_yn "  Does your ntfy server require an auth token?"; then
      prompt ntfy_token "  ntfy auth token"
    fi
  fi

  # ── Shared: Tailscale presence ───────────────────────────────────────────
  local tailscale_presence="false"
  local tailscale_desktop=""
  echo ""
  if prompt_yn "Enable Tailscale presence detection? (skip notifications when your desktop is online)"; then
    tailscale_presence="true"
    echo "  Run 'tailscale status' on your homelab to find your desktop's hostname."
    prompt tailscale_desktop "  Desktop Tailscale hostname"
  fi

  # ── Shared: Hook selection ───────────────────────────────────────────────
  echo ""
  local notify_on_stop="y"
  if ! prompt_yn "  Notify when task finishes (Stop hook)?" "y"; then
    notify_on_stop="n"
  fi

  local notify_on_input="y"
  if ! prompt_yn "  Notify when Claude needs input (Notification hook)?" "y"; then
    notify_on_input="n"
  fi

  local notify_on_subagent="n"
  if prompt_yn "  Notify on sub-agent completion (SubagentStop hook)?" "n"; then
    notify_on_subagent="y"
  fi

  # ── Write config ─────────────────────────────────────────────────────────
  mkdir -p "$INSTALL_DIR"
  cat > "$CONFIG_FILE" <<EOF
# pocket-lab configuration
# Generated by install.sh on $(date)
# Edit this file to change settings.

# Provider: telegram or ntfy
NOTIFY_PROVIDER="${notify_provider}"

# ── Telegram ─────────────────────────────────────────────────────────────
TELEGRAM_BOT_TOKEN="${telegram_bot_token}"
TELEGRAM_CHAT_ID="${telegram_chat_id}"
# true = no sound/vibration for ALL messages
TELEGRAM_SILENT="false"
# true = no sound/vibration for task-complete (Stop) messages only
TELEGRAM_SILENT_ON_STOP="${telegram_silent_on_stop}"

# ── ntfy ─────────────────────────────────────────────────────────────────
NTFY_SERVER="${ntfy_server}"
NTFY_TOPIC="${ntfy_topic}"
NTFY_TOKEN="${ntfy_token}"
NTFY_PRIORITY="default"

# ── Presence detection ───────────────────────────────────────────────────
# Skip notifications when your desktop is active on Tailscale
TAILSCALE_PRESENCE="${tailscale_presence}"
TAILSCALE_DESKTOP_NAME="${tailscale_desktop}"

# ── Misc ─────────────────────────────────────────────────────────────────
RATE_LIMIT_SECS=10
LOG_FILE="${LOG_FILE}"
NOTIFY_ENABLED_FILE="${NOTIFY_ENABLED_FILE}"

# Which hooks were registered (internal — do not edit)
_HOOK_STOP="${notify_on_stop}"
_HOOK_NOTIFICATION="${notify_on_input}"
_HOOK_SUBAGENT="${notify_on_subagent}"
EOF

  chmod 600 "$CONFIG_FILE"
  success "Config written to $CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Install hook scripts
# ---------------------------------------------------------------------------
install_hooks() {
  header "Installing hook scripts..."
  mkdir -p "$HOOKS_DIR"

  # Copy from local repo if running from the cloned dir, else download
  local notify_src=""
  local toggle_src=""

  if [[ -n "$SCRIPT_DIR" ]]; then
    notify_src="$SCRIPT_DIR/hooks/notify.sh"
    toggle_src="$SCRIPT_DIR/hooks/toggle.sh"
  fi

  if [[ -f "$notify_src" ]]; then
    cp "$notify_src" "$NOTIFY_HOOK"
    info "Copied notify.sh from local repo."
  else
    info "Downloading notify.sh..."
    curl -fsSL "$REPO_URL/hooks/notify.sh" -o "$NOTIFY_HOOK" \
      || fatal "Failed to download notify.sh. Check your internet connection."
  fi

  chmod +x "$NOTIFY_HOOK"
  success "notify.sh installed to $NOTIFY_HOOK"

  # Install toggle as 'pocket-lab' CLI command
  mkdir -p "$BIN_DIR"
  if [[ -f "$toggle_src" ]]; then
    cp "$toggle_src" "$TOGGLE_SCRIPT"
  else
    info "Downloading toggle.sh..."
    curl -fsSL "$REPO_URL/hooks/toggle.sh" -o "$TOGGLE_SCRIPT" \
      || fatal "Failed to download toggle.sh."
  fi

  chmod +x "$TOGGLE_SCRIPT"
  success "Toggle CLI installed: pocket-lab {on|off|status|flip}"
}

# ---------------------------------------------------------------------------
# Ensure ~/.local/bin is in PATH
# ---------------------------------------------------------------------------
ensure_bin_in_path() {
  if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    warn "$BIN_DIR is not in your PATH."
    local shell_rc=""
    case "${SHELL:-}" in
      */zsh)  shell_rc="$HOME/.zshrc" ;;
      */fish) shell_rc="$HOME/.config/fish/config.fish" ;;
      *)      shell_rc="$HOME/.bashrc" ;;
    esac

    if [[ -n "$shell_rc" ]]; then
      if prompt_yn "  Add $BIN_DIR to PATH in $shell_rc?"; then
        echo "" >> "$shell_rc"
        echo "# pocket-lab" >> "$shell_rc"
        if [[ "${SHELL:-}" == */fish ]]; then
          echo 'set -gx PATH $HOME/.local/bin $PATH' >> "$shell_rc"
        else
          echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$shell_rc"
        fi
        warn "Restart your shell or run: source $shell_rc"
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# Register hooks with Claude Code
# ---------------------------------------------------------------------------
register_claude_code_hooks() {
  local settings="$HOME/.claude/settings.json"

  if ! command -v claude &>/dev/null && [[ ! -d "$HOME/.claude" ]]; then
    info "Claude Code not detected — skipping Claude Code hook registration."
    return
  fi

  header "Registering hooks with Claude Code..."
  mkdir -p "$HOME/.claude"

  # Create settings.json if it doesn't exist
  if [[ ! -f "$settings" ]]; then
    echo '{}' > "$settings"
    info "Created $settings"
  fi

  if ! command -v jq &>/dev/null; then
    warn "jq not found — cannot auto-register hooks. Add them manually to $settings"
    print_manual_hook_instructions
    return
  fi

  # Load which hooks were selected (source may set _HOOK_* vars)
  # shellcheck source=/dev/null
  source "$CONFIG_FILE" 2>/dev/null || true
  local hook_stop="${_HOOK_STOP:-y}"
  local hook_notification="${_HOOK_NOTIFICATION:-y}"
  local hook_subagent="${_HOOK_SUBAGENT:-n}"

  local tmp
  tmp=$(mktemp)

  # Build hooks object — only add selected hooks
  local jq_expr='. '

  if [[ "$hook_notification" == "y" ]]; then
    jq_expr+='| .hooks.Notification = [{"matcher": "", "hooks": [{"type": "command", "command": $notify_hook + " Notification"}]}] '
  fi

  if [[ "$hook_stop" == "y" ]]; then
    jq_expr+='| .hooks.Stop = [{"matcher": "", "hooks": [{"type": "command", "command": $notify_hook + " Stop"}]}] '
  fi

  if [[ "$hook_subagent" == "y" ]]; then
    jq_expr+='| .hooks.SubagentStop = [{"matcher": "", "hooks": [{"type": "command", "command": $notify_hook + " SubagentStop"}]}] '
  fi

  # Backup existing settings
  cp "$settings" "${settings}.pocket-lab.bak"
  info "Backed up existing settings to ${settings}.pocket-lab.bak"

  jq --arg notify_hook "$NOTIFY_HOOK" "$jq_expr" "$settings" > "$tmp" && mv "$tmp" "$settings"
  success "Claude Code hooks registered in $settings"
}

# ---------------------------------------------------------------------------
# Print manual instructions when jq isn't available
# ---------------------------------------------------------------------------
print_manual_hook_instructions() {
  echo ""
  echo "Add the following to $HOME/.claude/settings.json:"
  echo ""
  cat <<EOF
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "$NOTIFY_HOOK Notification"}]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "$NOTIFY_HOOK Stop"}]
      }
    ]
  }
}
EOF
}

# ---------------------------------------------------------------------------
# Enable notifications by default
# ---------------------------------------------------------------------------
enable_notifications() {
  touch "$NOTIFY_ENABLED_FILE"
  success "Notifications enabled by default. Use 'pocket-lab off' to disable."
}

# ---------------------------------------------------------------------------
# Send a test notification
# ---------------------------------------------------------------------------
send_test_notification() {
  header "Sending test notification..."

  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  local ok=false

  case "${NOTIFY_PROVIDER:-ntfy}" in
    telegram)
      local payload
      if command -v jq &>/dev/null; then
        payload=$(jq -n \
          --arg chat_id "${TELEGRAM_CHAT_ID}" \
          --arg text "<b>Pocket Lab ✅</b>"$'\n'"pocket-lab is installed and working! Your AI notifications are ready." \
          '{chat_id: $chat_id, text: $text, parse_mode: "HTML"}')
      else
        payload='{"chat_id":"'"${TELEGRAM_CHAT_ID}"'","text":"<b>Pocket Lab ✅<\/b>\npocket-lab is installed and working! Your AI notifications are ready.","parse_mode":"HTML"}'
      fi
      local response
      response=$(curl -s --max-time 10 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" 2>&1)
      if echo "$response" | grep -q '"ok":true'; then
        ok=true
        success "Test notification sent via Telegram to chat ID ${TELEGRAM_CHAT_ID}"
      else
        local tg_err=""
        command -v jq &>/dev/null && \
          tg_err=$(echo "$response" | jq -r '.description // empty' 2>/dev/null || true)
        warn "Telegram test failed: ${tg_err:-$response}"
        echo "  Check TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in $CONFIG_FILE"
        echo "  Make sure you sent at least one message to your bot first."
      fi
      ;;
    ntfy)
      local curl_args=(-s --max-time 10)
      [[ -n "${NTFY_TOKEN:-}" ]] && curl_args+=(-H "Authorization: Bearer $NTFY_TOKEN")
      curl_args+=(
        -H "Title: Pocket Lab ✅"
        -H "Priority: default"
        -H "Tags: white_check_mark"
        -d "pocket-lab is installed and working! Your AI notifications are ready."
        "${NTFY_SERVER}/${NTFY_TOPIC}"
      )
      if curl "${curl_args[@]}" &>/dev/null; then
        ok=true
        success "Test notification sent via ntfy to ${NTFY_SERVER}/${NTFY_TOPIC}"
      else
        warn "ntfy test failed. Check NTFY_SERVER and NTFY_TOPIC in $CONFIG_FILE"
      fi
      ;;
  esac

  $ok && echo "  Check your phone — you should see a notification now."
}

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
print_summary() {
  header "Installation complete 🎉"
  echo ""
  echo "  Config:      $CONFIG_FILE"
  echo "  Hook script: $NOTIFY_HOOK"
  echo "  Logs:        $LOG_FILE"
  echo ""
  echo "  Commands:"
  echo "    pocket-lab on      — enable notifications (e.g. when leaving your desk)"
  echo "    pocket-lab off     — disable notifications (e.g. when at your PC)"
  echo "    pocket-lab status  — check current state"
  echo "    pocket-lab flip    — toggle current state"
  echo ""
  echo "  To edit config:  nano $CONFIG_FILE"
  echo "  To uninstall:    bash install.sh --uninstall"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo -e "${BOLD}"
  echo "  ╔═══════════════════════════════════════╗"
  echo "  ║         🔔 pocket-lab installer       ║"
  echo "  ║  AI notifications from your homelab   ║"
  echo "  ╚═══════════════════════════════════════╝"
  echo -e "${RESET}"

  [[ "$UNINSTALL" == "true" ]] && do_uninstall

  check_deps
  gather_config
  install_hooks
  ensure_bin_in_path
  enable_notifications

  # Register with detected AI tools
  local tools
  tools=$(detect_ai_tools)

  if echo "$tools" | grep -q "claude"; then
    register_claude_code_hooks
  fi

  if [[ -z "$tools" ]]; then
    warn "No supported AI tools (claude) detected in PATH."
    warn "Install your AI tool first, then re-run this script — or register hooks manually."
    print_manual_hook_instructions
  fi

  if prompt_yn "Send a test notification to verify setup?"; then
    send_test_notification
  fi

  print_summary
}

main "$@"