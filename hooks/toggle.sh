#!/usr/bin/env bash
# =============================================================================
# pocket-lab: toggle.sh
# Enable or disable push notifications from the command line.
# Usage:
#   toggle.sh on       — enable notifications
#   toggle.sh off      — disable notifications
#   toggle.sh status   — check current state
#   toggle.sh flip     — toggle current state
# =============================================================================

set -euo pipefail

CONFIG_FILE="${POCKET_LAB_CONFIG:-$HOME/.config/pocket-lab/config}"
NOTIFY_ENABLED_FILE="${NOTIFY_ENABLED_FILE:-$HOME/.config/pocket-lab/enabled}"

# Load config if it exists (may override NOTIFY_ENABLED_FILE)
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

is_enabled() {
  [[ -f "$NOTIFY_ENABLED_FILE" ]]
}

cmd="${1:-status}"

case "$cmd" in
  on|enable)
    touch "$NOTIFY_ENABLED_FILE"
    echo "✅ Pocket Lab notifications ON"
    ;;

  off|disable)
    rm -f "$NOTIFY_ENABLED_FILE"
    echo "🔕 Pocket Lab notifications OFF"
    ;;

  flip|toggle)
    if is_enabled; then
      rm -f "$NOTIFY_ENABLED_FILE"
      echo "🔕 Pocket Lab notifications OFF"
    else
      touch "$NOTIFY_ENABLED_FILE"
      echo "✅ Pocket Lab notifications ON"
    fi
    ;;

  status)
    if is_enabled; then
      echo "✅ Pocket Lab notifications are ON"
    else
      echo "🔕 Pocket Lab notifications are OFF"
    fi
    ;;

  *)
    echo "Usage: $(basename "$0") {on|off|flip|status}"
    exit 1
    ;;
esac