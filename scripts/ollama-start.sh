#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-9000}"
MODEL="${2:-qwen3.6:35b}"
KEEP_ALIVE_HOURS="${3:-24}"
STATUS_INTERVAL_SECONDS="${STATUS_INTERVAL_SECONDS:-60}"
HOST="127.0.0.1:${PORT}"
OLLAMA_BIN="${OLLAMA_BIN:-/opt/homebrew/bin/ollama}"
SERVER_PID=""
PRELOAD_PID=""

if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
  echo "port must be an integer between 1 and 65535" >&2
  exit 1
fi

if ! [[ "${KEEP_ALIVE_HOURS}" =~ ^[0-9]+$ ]] || ((KEEP_ALIVE_HOURS < 1)); then
  echo "keep-alive hours must be a positive integer" >&2
  exit 1
fi

if ! command -v "${OLLAMA_BIN}" >/dev/null 2>&1; then
  echo "ollama binary not found at ${OLLAMA_BIN}" >&2
  exit 1
fi

if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port ${PORT} is already in use" >&2
  exit 1
fi

cleanup() {
  trap - INT TERM EXIT
  echo
  echo "Stopping Ollama server..."

  if [[ -n "${PRELOAD_PID}" ]] && kill -0 "${PRELOAD_PID}" >/dev/null 2>&1; then
    kill "${PRELOAD_PID}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi

  echo "Stopped."
}

wait_for_server() {
  for _ in {1..60}; do
    if curl -fsS "http://${HOST}/api/tags" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "server did not become ready at http://${HOST}" >&2
  return 1
}

model_status() {
  OLLAMA_HOST="${HOST}" "${OLLAMA_BIN}" ps 2>/dev/null |
    awk -v model="${MODEL}" 'NR > 1 && $1 == model { found = 1 } END { print found ? "loaded" : "not-loaded" }'
}

trap cleanup INT TERM EXIT

echo "Starting Ollama server..."
echo "  endpoint:   http://${HOST}"
echo "  model:      ${MODEL}"
echo "  keep_alive: ${KEEP_ALIVE_HOURS}h"
echo "  status:     every ${STATUS_INTERVAL_SECONDS}s"
echo "  stop:       Ctrl+C"

OLLAMA_HOST="${HOST}" \
OLLAMA_KEEP_ALIVE="${KEEP_ALIVE_HOURS}h" \
OLLAMA_CONTEXT_LENGTH="8192" \
OLLAMA_FLASH_ATTENTION="1" \
OLLAMA_KV_CACHE_TYPE="q8_0" \
"${OLLAMA_BIN}" serve &
SERVER_PID="$!"

wait_for_server

(
  if curl -fsS "http://${HOST}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"keep_alive\":\"${KEEP_ALIVE_HOURS}h\"}" >/dev/null; then
    echo "Preloaded ${MODEL} with keep_alive=${KEEP_ALIVE_HOURS}h"
  else
    echo "Failed to preload ${MODEL}" >&2
  fi
) &
PRELOAD_PID="$!"

while kill -0 "${SERVER_PID}" >/dev/null 2>&1; do
  echo "[$(date '+%H:%M:%S')] server=up endpoint=http://${HOST} model=${MODEL} status=$(model_status)"
  sleep "${STATUS_INTERVAL_SECONDS}"
done

wait "${SERVER_PID}"
