#!/usr/bin/env bash
# Telegram provider for actions/notify.
#
# NOTIFY_URL form:
#   telegram://<bot_token>@<chat_id>[?thread=<message_thread_id>]
#
# <chat_id> is whatever Telegram's sendMessage expects: a numeric chat id,
# or "@channelusername". <thread> is optional, for forum supergroups.
#
# Env in: NOTIFY_URL, STATUS, TITLE, LINK, DESCRIPTION, FIELDS (see action.yml)
set -euo pipefail

: "${NOTIFY_URL:?}" "${STATUS:?}" "${TITLE:?}"
LINK="${LINK:-${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}}"
DESCRIPTION="${DESCRIPTION:-}"
FIELDS="${FIELDS:-}"

rest="${NOTIFY_URL#telegram://}"
query=""
if [[ "$rest" == *"?"* ]]; then
  query="${rest#*\?}"
  rest="${rest%%\?*}"
fi
bot_token="${rest%%@*}"
chat_id="${rest#*@}"

thread_id=""
if [[ "$query" == *"thread="* ]]; then
  thread_id="${query#*thread=}"
  thread_id="${thread_id%%&*}"
fi

case "$STATUS" in
  started) emoji="🔨" ;;
  success) emoji="🚀" ;;
  failure) emoji="💥" ;;
  *)       emoji="ℹ️" ;;
esac

escape_html() {
  sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

title_esc=$(printf '%s' "$TITLE" | escape_html)
text="${emoji} <b>${title_esc}</b>"

if [ -n "$DESCRIPTION" ]; then
  desc_esc=$(printf '%s' "$DESCRIPTION" | escape_html)
  text="${text}
${desc_esc}"
fi

if [ -n "$FIELDS" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name="${line%%|*}"
    value="${line#*|}"
    name_esc=$(printf '%s' "$name" | escape_html)
    value_esc=$(printf '%s' "$value" | escape_html)
    text="${text}
<b>${name_esc}:</b> ${value_esc}"
  done <<<"$FIELDS"
fi

text="${text}

<a href=\"${LINK}\">View run</a>"
text="${text:0:4096}" # Telegram's hard cap per message.

api_url="https://api.telegram.org/bot${bot_token}/sendMessage"
payload=$(jq -n \
  --arg chat_id "$chat_id" \
  --arg text "$text" \
  --arg thread "$thread_id" \
  '{chat_id: $chat_id, text: $text, parse_mode: "HTML", disable_web_page_preview: true}
    + (if ($thread | length) > 0 then {message_thread_id: ($thread | tonumber)} else {} end)')

if curl -sS -f -X POST -H "Content-Type: application/json" -d "$payload" "$api_url" -o /dev/null; then
  echo "notify(telegram): sent"
else
  echo "notify(telegram): request failed" >&2
  exit 1
fi
