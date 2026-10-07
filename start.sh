#!/usr/bin/env bash
set -euo pipefail

RUNNER="$HOME/Documents/agent-runner"
WS="$HOME/Documents/agent-workspace"
PROJECT="build-it-timer"

KEY_FILE="${KEY_FILE:-$HOME/.continue/.env}"
if [ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$KEY_FILE" ]; then
  OPENROUTER_API_KEY=$(grep -E '^(export[[:space:]]+)?OPENROUTER_API_KEY=' "$KEY_FILE" \
    | tail -n1 | tr -d '\r' | cut -d= -f2- | sed -E "s/^[\"']//; s/[\"']\$//")
fi
: "${OPENROUTER_API_KEY:?Chiave non trovata: controlla $KEY_FILE}"

MODEL="${MODEL:-openrouter/deepseek/deepseek-v4.1-flash}"

for p in "$WS/$PROJECT" "$WS/logs" "$RUNNER/run-agent.sh" "$RUNNER/opencode.jsonc"; do
  [ -e "$p" ] || { echo "Percorso mancante: $p"; exit 1; }
done

# File in cui l'agente propone il messaggio di commit.
# NB: sono due path diversi. Sull'host lo creo io (UID 1000) perché altrimenti docker lo
# creerebbe come root; nel container il file è visibile come /logs/COMMIT_MSG.txt
# (/logs è il bind mount di $WS/logs), ed è quel path che va comunicato all'agente.
HOST_COMMIT_MSG_FILE="$WS/logs/COMMIT_MSG.txt"
CONTAINER_COMMIT_MSG_FILE="/logs/COMMIT_MSG.txt"
[ -e "$HOST_COMMIT_MSG_FILE" ] || : > "$HOST_COMMIT_MSG_FILE"

if [ "${1:-}" = "--shell" ]; then CMD=(bash); else CMD=(bash /opt/agent/run-agent.sh "$@"); fi

sudo docker run --rm -it \
  --name agent \
  --user 1000:1000 \
  --cap-drop ALL --security-opt no-new-privileges \
  --memory 8g --cpus 4 --pids-limit 512 \
  --mount type=bind,source="$WS/$PROJECT",target=/workspace \
  --mount type=bind,source="$WS/logs",target=/logs \
  --mount type=bind,source="$RUNNER/run-agent.sh",target=/opt/agent/run-agent.sh,readonly \
  --mount type=bind,source="$RUNNER/opencode.jsonc",target=/home/node/.config/opencode/opencode.jsonc,readonly \
  -e OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
  -e MODEL="$MODEL" \
  -e COMMIT_MSG_FILE="$CONTAINER_COMMIT_MSG_FILE" \
  -e START_TASK="${START_TASK:-M2.T9}" \
  -e MAX_TASKS="${MAX_TASKS:-1}" \
  -e SKIP_TASKS="${SKIP_TASKS:-}" \
  agent-runner "${CMD[@]}"
