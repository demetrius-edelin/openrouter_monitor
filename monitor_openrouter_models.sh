#!/usr/bin/env bash
#
# monitor_openrouter_models.sh
#
# Cron-friendly script to monitor https://openrouter.ai/models for newly
# listed models and send a Slack and/or Telegram notification for any additions.
#
# Usage (example cron, runs every 15 minutes):
#   */15 * * * * /usr/bin/env bash /path/to/monitor_openrouter_models.sh
#
# Notes:
# - This script keeps state in ".openrouter_models_last.json" in the same
#   directory as the script.
# - On the very first run, it only initializes the baseline and does NOT
#   send notifications (to avoid spamming with all existing models).
# - Requires: bash, curl, jq
# - The script loads the notification configuration from .env:
#   - SLACK_WEBHOOK_URL for Slack.
#   - TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID for Telegram.
#   Set one channel or both channels.
#

set -euo pipefail

# ------------- Paths -------------

# Determine directory where this script resides (for state and .env)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# State file to store the last seen model IDs
STATE_FILE="${SCRIPT_DIR}/.openrouter_models_last.json"

# Optional .env file path
ENV_FILE="${SCRIPT_DIR}/.env"

# ------------- Load Environment -------------

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' "${ENV_FILE}" | xargs -0 -I {} bash -c 'printf "%s\n" "{}"' 2>/dev/null || true)
fi

# Notification channels. Each channel is optional, but you must set at least one.
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

if [[ -n "${TELEGRAM_BOT_TOKEN}" && -z "${TELEGRAM_CHAT_ID}" ]] ||
  [[ -z "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
  echo "Error: Set both TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID, or set neither." >&2
  exit 1
fi

if [[ -z "${SLACK_WEBHOOK_URL}" && -z "${TELEGRAM_BOT_TOKEN}" ]]; then
  echo "Error: No notification channel is set. Define SLACK_WEBHOOK_URL or TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env or the environment." >&2
  exit 1
fi

# ------------- Configuration -------------

# OpenRouter models API
OPENROUTER_MODELS_URL="https://openrouter.ai/api/v1/models"

# Base URL for model detail pages
OPENROUTER_MODEL_PAGE_BASE_URL="https://openrouter.ai/models"

# ------------- Functions -------------

log() {
  # Log with timestamp (stdout so cron can capture)
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

fetch_models_json() {
  # Fetch models JSON from OpenRouter API
  # Using short timeout for cron robustness
  curl -sS --fail \
    --max-time 15 \
    "${OPENROUTER_MODELS_URL}"
}

extract_model_ids() {
  # Input: full JSON from OpenRouter
  # Output: sorted unique list of model ids, one per line
  jq -r '.data[]?.id' 2>/dev/null | sort -u
}

send_slack_message() {
  local text=$1

  # Construct payload and POST to Slack webhook
  curl -sS -X POST "${SLACK_WEBHOOK_URL}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg text "$text" '{text: $text}')" \
    >/dev/null || log "Warning: Failed to send Slack notification"
}

# Telegram rejects a message that has more than 4096 characters.
# Use a lower limit to keep a safety margin.
TELEGRAM_MAX_CHARS=4000

post_telegram_chunk() {
  local text=$1

  curl -sS --fail -X POST \
    --max-time 15 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "disable_web_page_preview=true" \
    >/dev/null || log "Warning: Failed to send Telegram notification"
}

send_telegram_message() {
  local text=$1
  local chunk=""
  local line

  # Divide the text at line breaks so that each message stays below the limit.
  while IFS= read -r line; do
    if [[ -n "$chunk" && $((${#chunk} + ${#line} + 1)) -gt ${TELEGRAM_MAX_CHARS} ]]; then
      post_telegram_chunk "$chunk"
      chunk=""
    fi
    if [[ -z "$chunk" ]]; then
      chunk="$line"
    else
      chunk+=$'\n'"$line"
    fi
  done < <(printf '%s\n' "$text")

  [[ -n "$chunk" ]] && post_telegram_chunk "$chunk"
  return 0
}

# ------------- Main Logic -------------

# 1) Fetch current models
JSON=$(fetch_models_json) || {
  log "Error: Failed to fetch models from ${OPENROUTER_MODELS_URL}"
  exit 1
}

CURRENT_IDS=$(printf '%s\n' "$JSON" | extract_model_ids)

if [[ -z "$CURRENT_IDS" ]]; then
  log "Error: No model IDs parsed from API response; aborting."
  exit 1
fi

# 2) If no previous state, initialize and exit without notifying
if [[ ! -f "$STATE_FILE" ]]; then
  printf '%s\n' "$CURRENT_IDS" >"$STATE_FILE"
  log "Initialized state with current model list; no notifications sent (first run)."
  exit 0
fi

# 3) Load previous IDs
PREV_IDS=$(cat "$STATE_FILE" 2>/dev/null || echo "")

# Sanity: if previous is empty for some reason, just reset baseline
if [[ -z "$PREV_IDS" ]]; then
  printf '%s\n' "$CURRENT_IDS" >"$STATE_FILE"
  log "Previous state empty; baseline reset; no notifications sent this run."
  exit 0
fi

# 4) Compute new IDs: CURRENT - PREV
# Using `comm` requires sorted inputs; we already sort in extract_model_ids
NEW_IDS=$(comm -13 <(printf '%s\n' "$PREV_IDS") <(printf '%s\n' "$CURRENT_IDS"))

if [[ -z "$NEW_IDS" ]]; then
  log "No new models detected."
  # Update state anyway in case ordering changed or previous got stale
  printf '%s\n' "$CURRENT_IDS" >"$STATE_FILE"
  exit 0
fi

# 5) Fetch mapping of id -> name and slug (if available) or fallback to id
# Build associative arrays: id -> display name, id -> slug
declare -A MODEL_NAME_BY_ID
declare -A MODEL_SLUG_BY_ID

while IFS=$'\t' read -r mid mname mslug; do
  [[ -z "$mid" ]] && continue
  MODEL_NAME_BY_ID["$mid"]="$mname"
  # Prefer explicit slug if present; otherwise derive a URL-safe slug from id
  if [[ -n "$mslug" && "$mslug" != "null" ]]; then
    MODEL_SLUG_BY_ID["$mid"]="$mslug"
  else
    # Derive slug from id by replacing non-alphanumeric/_.- with hyphens
    MODEL_SLUG_BY_ID["$mid"]="$(echo "$mid" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g')"
  fi
done < <(
  printf '%s\n' "$JSON" |
    jq -r '.data[] | [.id,
                      (.name // .id // ""),
                      (.slug // .id // "")]
           | @tsv' 2>/dev/null
)

# 6) Prepare notification text with direct links
NEW_LIST_TEXT=""
while IFS= read -r mid; do
  [[ -z "$mid" ]] && continue
  display="${MODEL_NAME_BY_ID[$mid]:-$mid}"
  slug="${MODEL_SLUG_BY_ID[$mid]:-$mid}"
  model_url="${OPENROUTER_MODEL_PAGE_BASE_URL}/${slug}"
  NEW_LIST_TEXT+=$'\n'"• ${display} (${mid}) - ${model_url}"
done < <(printf '%s\n' "$NEW_IDS")

MESSAGE="New OpenRouter model(s) detected:${NEW_LIST_TEXT}"

# 7) Send notifications to each channel that has a configuration
if [[ -n "${SLACK_WEBHOOK_URL}" ]]; then
  send_slack_message "$MESSAGE"
fi

if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
  send_telegram_message "$MESSAGE"
fi

# 8) Update state
printf '%s\n' "$CURRENT_IDS" >"$STATE_FILE"

log "Notification sent for new models:"
printf '%s\n' "$NEW_IDS"