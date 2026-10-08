#!/usr/bin/env bash
# Discord provider for actions/notify.
#
# NOTIFY_URL forms accepted:
#   discord://<webhook_id>/<webhook_token>
#   https://discord.com/api/webhooks/<webhook_id>/<webhook_token>  (pasted straight from Discord)
#
# Env in: NOTIFY_URL, STATUS, TITLE, LINK, DESCRIPTION, FIELDS (see action.yml)
set -euo pipefail

: "${NOTIFY_URL:?}" "${STATUS:?}" "${TITLE:?}"
LINK="${LINK:-${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}}"
DESCRIPTION="${DESCRIPTION:-}"
FIELDS="${FIELDS:-}"

if [[ "$NOTIFY_URL" == discord://* ]]; then
  rest="${NOTIFY_URL#discord://}"
  webhook_id="${rest%%/*}"
  webhook_token="${rest#*/}"
  webhook_url="https://discord.com/api/webhooks/${webhook_id}/${webhook_token}"
else
  webhook_url="$NOTIFY_URL"
fi

case "$STATUS" in
  started) color=3900151 ;;  # blurple
  success) color=3066993 ;;  # green
  failure) color=15158332 ;; # red
  *)       color=9807270 ;;  # grey
esac

# "Name|Value" lines -> Discord embed fields (max 25 fields, 256/1024 char caps).
fields_json=$(printf '%s\n' "$FIELDS" | jq -R -s '
  split("\n")
  | map(select(length > 0))
  | map(split("|"))
  | map(select(length >= 2))
  | map({name: (.[0][0:256]), value: ((.[1:] | join("|"))[0:1024]), inline: false})
  | .[0:25]
')

payload=$(jq -n \
  --arg title "$TITLE" \
  --arg url "$LINK" \
  --arg desc "${DESCRIPTION:0:4096}" \
  --argjson color "$color" \
  --argjson fields "$fields_json" \
  '{
    embeds: [
      ({title: $title, url: $url, color: $color}
        + (if ($desc | length) > 0 then {description: $desc} else {} end)
        + (if ($fields | length) > 0 then {fields: $fields} else {} end))
    ]
  }')

if curl -sS -f -X POST -H "Content-Type: application/json" -d "$payload" "$webhook_url" -o /dev/null; then
  echo "notify(discord): sent"
else
  echo "notify(discord): request failed" >&2
  exit 1
fi
