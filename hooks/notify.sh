#!/usr/bin/env bash
# =============================================================================
# pocket-lab: notify.sh
# Sends push notifications via ntfy OR Telegram when Claude Code (or other
# AI tools) need input or finish a task.
#
# Triggered by Claude Code hooks: Notification, Stop, SubagentStop
# Provider is selected in config: NOTIFY_PROVIDER=telegram|ntfy
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config — read from config file, then env overrides
# ---------------------------------------------------------------------------
CONFIG_FILE="${POCKET_LAB_CONFIG:-$HOME/.config/pocket-lab/config}"
NOTIFY_ENABLED_FILE="${NOTIFY_ENABLED_FILE:-$HOME/.config/pocket-lab/enabled}"
LOG_FILE="${LOG_FILE:-$HOME/.config/pocket-lab/notify.log}"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Provider — telegram or ntfy
NOTIFY_PROVIDER="${NOTIFY_PROVIDER:-ntfy}"

# ntfy settings
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
NTFY_PRIORITY="${NTFY_PRIORITY:-default}"

# Telegram settings
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_SILENT="${TELEGRAM_SILENT:-false}"
TELEGRAM_SILENT_ON_STOP="${TELEGRAM_SILENT_ON_STOP:-false}"

# Presence / rate limiting
TAILSCALE_PRESENCE="${TAILSCALE_PRESENCE:-false}"
TAILSCALE_DESKTOP_NAME="${TAILSCALE_DESKTOP_NAME:-}"
RATE_LIMIT_SECS="${RATE_LIMIT_SECS:-10}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  local level="$1"; shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Guard: notifications enabled?
# ---------------------------------------------------------------------------
if [[ ! -f "$NOTIFY_ENABLED_FILE" ]]; then
  log "INFO" "Notifications disabled. Skipping."
  exit 0
fi

# ---------------------------------------------------------------------------
# Guard: validate provider config
# ---------------------------------------------------------------------------
case "$NOTIFY_PROVIDER" in
  ntfy)
    if [[ -z "$NTFY_TOPIC" ]]; then
      log "ERROR" "NOTIFY_PROVIDER=ntfy but NTFY_TOPIC is not set in $CONFIG_FILE"
      exit 1
    fi
    ;;
  telegram)
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
      log "ERROR" "NOTIFY_PROVIDER=telegram but TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set in $CONFIG_FILE"
      exit 1
    fi
    ;;
  *)
    log "ERROR" "Unknown NOTIFY_PROVIDER '$NOTIFY_PROVIDER'. Must be 'ntfy' or 'telegram'."
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Guard: Tailscale presence detection
# ---------------------------------------------------------------------------
if [[ "$TAILSCALE_PRESENCE" == "true" && -n "$TAILSCALE_DESKTOP_NAME" ]]; then
  if command -v tailscale &>/dev/null; then
    PEER_LINE=$(tailscale status 2>/dev/null | grep -i "$TAILSCALE_DESKTOP_NAME" || true)
    if [[ -n "$PEER_LINE" ]]; then
      PEER_STATUS=$(echo "$PEER_LINE" | awk '{print $NF}')
      if [[ "$PEER_STATUS" == "active" || "$PEER_STATUS" == "-" ]]; then
        log "INFO" "Desktop ($TAILSCALE_DESKTOP_NAME) is online. Skipping notification."
        exit 0
      fi
    fi
  else
    log "WARN" "TAILSCALE_PRESENCE=true but tailscale CLI not found."
  fi
fi

# ---------------------------------------------------------------------------
# Read JSON payload from stdin (Claude Code sends hook context as JSON)
# ---------------------------------------------------------------------------
HOOK_ARG="${1:-}"
INPUT=""
if ! tty -s; then
  INPUT=$(cat 2>/dev/null || echo "{}")
fi

PROJECT_NAME=""
MESSAGE=""
HOOK_TITLE=""

if command -v jq &>/dev/null && [[ -n "$INPUT" ]]; then
  PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
  [[ -n "$PROJECT_DIR" ]] && PROJECT_DIR=$(echo "$PROJECT_DIR" | tr '\\' '/')
  MESSAGE=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null || echo "")
  HOOK_TITLE=$(echo "$INPUT" | jq -r '.title // empty' 2>/dev/null || echo "")
  [[ -n "$PROJECT_DIR" ]] && PROJECT_NAME=$(basename "$PROJECT_DIR" 2>/dev/null || echo "")
else
  log "WARN" "jq not found — limited notification context"
fi

# ---------------------------------------------------------------------------
# Build notification content
# ---------------------------------------------------------------------------
build_title() {
  if [[ -n "$HOOK_TITLE" ]]; then
    echo "$HOOK_TITLE"
  elif [[ -n "$PROJECT_NAME" ]]; then
    echo "Pocket Lab ($PROJECT_NAME)"
  else
    echo "Pocket Lab"
  fi
}

build_body() {
  local hook="${HOOK_ARG}"
  case "$hook" in
    Stop)
      [[ -n "$MESSAGE" ]] && echo "✅ Done: $MESSAGE" || echo "✅ Task complete${PROJECT_NAME:+ in $PROJECT_NAME}"
      ;;
    Notification)
      [[ -n "$MESSAGE" ]] && echo "🤖 Input needed: $MESSAGE" || echo "🤖 Claude needs your input${PROJECT_NAME:+ in $PROJECT_NAME}"
      ;;
    SubagentStop)
      echo "🔁 Sub-task complete${PROJECT_NAME:+ in $PROJECT_NAME}"
      ;;
    *)
      [[ -n "$MESSAGE" ]] && echo "$MESSAGE" || echo "👋 Claude needs attention${PROJECT_NAME:+ in $PROJECT_NAME}"
      ;;
  esac
}

# Telegram HTML-formatted message
build_telegram_text() {
  local title body
  title=$(build_title)
  body=$(build_body)
  # Escape HTML special chars in body
  body=$(echo "$body" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g')
  echo "<b>${title}</b>&#10;${body}"
}

TITLE=$(build_title)
BODY=$(build_body)

# Priority for ntfy
case "$HOOK_ARG" in
  Notification) PRIORITY="high" ;;
  *)            PRIORITY="${NTFY_PRIORITY:-default}" ;;
esac

# ---------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------
RATE_KEY="${NOTIFY_PROVIDER}-${NTFY_TOPIC:-tg}-${PROJECT_NAME//[^a-zA-Z0-9]/_}"
RATE_FILE="/tmp/pocket-lab-rate-${RATE_KEY}"

should_rate_limit() {
  if [[ -f "$RATE_FILE" ]]; then
    local last_sent now diff
    last_sent=$(cat "$RATE_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    diff=$(( now - last_sent ))
    (( diff < RATE_LIMIT_SECS )) && return 0
  fi
  return 1
}

if should_rate_limit; then
  log "INFO" "Rate limited — skipping (within ${RATE_LIMIT_SECS}s window)"
  exit 0
fi

date +%s > "$RATE_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Provider: ntfy
# ---------------------------------------------------------------------------
send_ntfy() {
  local url="${NTFY_SERVER}/${NTFY_TOPIC}"
  local curl_args=(-s --fail-with-body --max-time 10 --retry 2 --retry-delay 2)

  [[ -n "$NTFY_TOKEN" ]] && curl_args+=(-H "Authorization: Bearer $NTFY_TOKEN")

  curl_args+=(
    -H "Title: $TITLE"
    -H "Priority: $PRIORITY"
    -H "Tags: bell"
    -d "$BODY"
    "$url"
  )

  local response
  if response=$(curl "${curl_args[@]}" 2>&1); then
    log "INFO" "[ntfy] Sent: [$TITLE] $BODY"
  else
    log "ERROR" "[ntfy] Failed: $response"
  fi
}

# ---------------------------------------------------------------------------
# Provider: Telegram
# ---------------------------------------------------------------------------
send_telegram() {
  local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
  local text
  text=$(build_telegram_text)

  local silent="false"
  [[ "$TELEGRAM_SILENT" == "true" ]] && silent="true"
  [[ "$HOOK_ARG" == "Stop" && "$TELEGRAM_SILENT_ON_STOP" == "true" ]] && silent="true"

  # Build JSON safely — use jq when available, sed fallback otherwise
  local payload
  if command -v jq &>/dev/null; then
    payload=$(jq -n \
      --arg chat_id "$TELEGRAM_CHAT_ID" \
      --arg text "$text" \
      --argjson silent "$silent" \
      '{chat_id: $chat_id, text: $text, parse_mode: "HTML", disable_notification: $silent}')
  else
    payload=$(printf '{"chat_id":"%s","text":"%s","parse_mode":"HTML","disable_notification":%s}' \
      "$TELEGRAM_CHAT_ID" \
      "$(echo "$text" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')" \
      "$silent")
  fi

  local response
  if response=$(curl -s --max-time 10 --retry 2 --retry-delay 2 \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$url" 2>&1); then

    if echo "$response" | grep -q '"ok":true'; then
      log "INFO" "[telegram] Sent: [$TITLE] $BODY"
    else
      local tg_error=""
      command -v jq &>/dev/null && \
        tg_error=$(echo "$response" | jq -r '.description // empty' 2>/dev/null || true)
      log "ERROR" "[telegram] API error: ${tg_error:-$response}"
    fi
  else
    log "ERROR" "[telegram] curl failed: $response"
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
if ! command -v curl &>/dev/null; then
  log "ERROR" "curl not found — cannot send notification"
  exit 1
fi

case "$NOTIFY_PROVIDER" in
  ntfy)     send_ntfy ;;
  telegram) send_telegram ;;
esac