#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-9000}"
MODEL="${2:-qwen3.6:35b}"
KEEP_ALIVE_HOURS="${3:-24}"
STATUS_INTERVAL_SECONDS="${STATUS_INTERVAL_SECONDS:-60}"
BACKEND_PORT="${OLLAMA_BACKEND_PORT:-$((PORT + 1))}"
HOST="127.0.0.1:${PORT}"
BACKEND_HOST="127.0.0.1:${BACKEND_PORT}"
OLLAMA_BIN="${OLLAMA_BIN:-/opt/homebrew/bin/ollama}"
SERVER_PID=""
PRELOAD_PID=""
PROXY_PID=""

if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
  echo "port must be an integer between 1 and 65535" >&2
  exit 1
fi

if ! [[ "${KEEP_ALIVE_HOURS}" =~ ^[0-9]+$ ]] || ((KEEP_ALIVE_HOURS < 1)); then
  echo "keep-alive hours must be a positive integer" >&2
  exit 1
fi

if ! [[ "${BACKEND_PORT}" =~ ^[0-9]+$ ]] || ((BACKEND_PORT < 1 || BACKEND_PORT > 65535)); then
  echo "backend port must be an integer between 1 and 65535" >&2
  exit 1
fi

if [[ "${BACKEND_PORT}" == "${PORT}" ]]; then
  echo "backend port must be different from public port ${PORT}" >&2
  exit 1
fi

if ! command -v "${OLLAMA_BIN}" >/dev/null 2>&1; then
  echo "ollama binary not found at ${OLLAMA_BIN}" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for the request logging proxy" >&2
  exit 1
fi

if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port ${PORT} is already in use" >&2
  exit 1
fi

if lsof -nP -iTCP:"${BACKEND_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "backend port ${BACKEND_PORT} is already in use" >&2
  exit 1
fi

cleanup() {
  trap - INT TERM EXIT
  echo
  echo "Stopping Ollama server..."

  if [[ -n "${PRELOAD_PID}" ]] && kill -0 "${PRELOAD_PID}" >/dev/null 2>&1; then
    kill "${PRELOAD_PID}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${PROXY_PID}" ]] && kill -0 "${PROXY_PID}" >/dev/null 2>&1; then
    kill "${PROXY_PID}" >/dev/null 2>&1 || true
    wait "${PROXY_PID}" 2>/dev/null || true
  fi

  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi

  echo "Stopped."
}

wait_for_server() {
  for _ in {1..60}; do
    if curl -fsS "http://${BACKEND_HOST}/api/tags" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "server did not become ready at http://${BACKEND_HOST}" >&2
  return 1
}

model_status() {
  OLLAMA_HOST="${BACKEND_HOST}" "${OLLAMA_BIN}" ps 2>/dev/null |
    awk -v model="${MODEL}" 'NR > 1 && $1 == model { found = 1 } END { print found ? "loaded" : "not-loaded" }'
}

start_logging_proxy() {
  OLLAMA_PROXY_LISTEN="${HOST}" OLLAMA_PROXY_UPSTREAM="${BACKEND_HOST}" python3 -u <<'PY' &
import datetime
import http.client
import itertools
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}
REDACTED_HEADERS = {"authorization", "cookie", "x-api-key"}
TEXT_CONTENT_TYPES = ("application/json", "application/x-ndjson", "text/")

listen_host, listen_port = os.environ["OLLAMA_PROXY_LISTEN"].rsplit(":", 1)
upstream_host, upstream_port = os.environ["OLLAMA_PROXY_UPSTREAM"].rsplit(":", 1)
upstream_port = int(upstream_port)
request_ids = itertools.count(1)


def timestamp() -> str:
    return datetime.datetime.now().strftime("%H:%M:%S")


def log(message: str = "") -> None:
    print(message, flush=True)


def format_headers(headers) -> str:
    lines = []
    for name, value in headers.items():
        rendered_value = "<redacted>" if name.lower() in REDACTED_HEADERS else value
        lines.append(f"{name}: {rendered_value}")
    return "\n".join(lines)


def is_text_response(content_type: str) -> bool:
    normalized_content_type = content_type.lower()
    return any(normalized_content_type.startswith(prefix) for prefix in TEXT_CONTENT_TYPES)


def body_to_text(body: bytes) -> str:
    return body.decode("utf-8", errors="replace")


class LoggingProxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        return

    def do_HEAD(self):
        self.proxy_request()

    def do_GET(self):
        self.proxy_request()

    def do_POST(self):
        self.proxy_request()

    def do_OPTIONS(self):
        self.proxy_request()

    def proxy_request(self):
        request_id = next(request_ids)
        started_at = time.monotonic()
        request_body = self.read_request_body()
        self.log_request_detail(request_id, request_body)

        connection = http.client.HTTPConnection(upstream_host, upstream_port, timeout=None)
        try:
            connection.request(
                self.command,
                self.path,
                body=request_body if request_body else None,
                headers=self.upstream_headers(),
            )
            response = connection.getresponse()
            self.forward_response(request_id, response, started_at)
        except Exception as error:
            log(f"[{timestamp()}] response #{request_id} upstream_error={error}")
            self.send_error(502, f"upstream error: {error}")
        finally:
            connection.close()

    def read_request_body(self) -> bytes:
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length == 0:
            return b""
        return self.rfile.read(content_length)

    def upstream_headers(self) -> dict[str, str]:
        headers = {}
        for name, value in self.headers.items():
            if name.lower() in HOP_BY_HOP_HEADERS:
                continue
            headers[name] = value
        headers["Host"] = f"{upstream_host}:{upstream_port}"
        return headers

    def log_request_detail(self, request_id: int, request_body: bytes) -> None:
        log(f"[{timestamp()}] request #{request_id} {self.command} {self.path}")
        if self.headers:
            log(f"--- request #{request_id} headers ---")
            log(format_headers(self.headers))
        if request_body:
            log(f"--- request #{request_id} body ({len(request_body)} bytes) ---")
            log(body_to_text(request_body))
        else:
            log(f"--- request #{request_id} body: <empty> ---")

    def forward_response(self, request_id: int, response, started_at: float) -> None:
        duration_ms = (time.monotonic() - started_at) * 1000
        content_type = response.getheader("Content-Type", "")
        should_log_body = is_text_response(content_type)

        log(f"[{timestamp()}] response #{request_id} {response.status} {response.reason} after {duration_ms:.1f}ms")
        log(f"--- response #{request_id} headers ---")
        log(format_headers(response.headers))
        if should_log_body:
            log(f"--- response #{request_id} body stream ---")
        else:
            log(f"--- response #{request_id} body stream: <non-text content-type={content_type or 'unknown'}> ---")

        self.send_response(response.status, response.reason)
        for name, value in response.headers.items():
            if name.lower() in HOP_BY_HOP_HEADERS:
                continue
            self.send_header(name, value)
        self.send_header("Connection", "close")
        self.end_headers()

        while True:
            chunk = response.read(4096)
            if not chunk:
                break
            self.wfile.write(chunk)
            self.wfile.flush()
            if should_log_body:
                sys.stdout.write(body_to_text(chunk))
                sys.stdout.flush()

        if should_log_body:
            log("")
            log(f"--- response #{request_id} body end ---")
        log(f"[{timestamp()}] response #{request_id} complete")
        self.close_connection = True


server = ThreadingHTTPServer((listen_host, int(listen_port)), LoggingProxy)
log(f"Logging proxy listening at http://{listen_host}:{listen_port}, upstream=http://{upstream_host}:{upstream_port}")
server.serve_forever()
PY
}

trap cleanup INT TERM EXIT

echo "Starting Ollama server..."
echo "  endpoint:   http://${HOST}"
echo "  upstream:   http://${BACKEND_HOST}"
echo "  model:      ${MODEL}"
echo "  keep_alive: ${KEEP_ALIVE_HOURS}h"
echo "  status:     every ${STATUS_INTERVAL_SECONDS}s"
echo "  stop:       Ctrl+C"

OLLAMA_HOST="${BACKEND_HOST}" \
OLLAMA_KEEP_ALIVE="${KEEP_ALIVE_HOURS}h" \
OLLAMA_CONTEXT_LENGTH="8192" \
OLLAMA_FLASH_ATTENTION="1" \
OLLAMA_KV_CACHE_TYPE="q8_0" \
"${OLLAMA_BIN}" serve &
SERVER_PID="$!"

wait_for_server
start_logging_proxy
PROXY_PID="$!"

(
  if curl -fsS "http://${BACKEND_HOST}/api/generate" \
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
