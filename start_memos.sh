#!/bin/bash
# start_memos.sh — MemOS server launcher with pre-start port cleanup
# Prevents [Errno 48] address already in use restart loops under launchd.
#
# Usage: ./start_memos.sh
# LaunchAgent: com.openclaw.memos

set -euo pipefail

PORT=8001
VENV_UVICORN="/Users/jack_family_office/.openclaw/workspace/projects/MemOS/.venv/bin/uvicorn"
LOG_PREFIX="[start_memos.sh]"

echo "$LOG_PREFIX Checking for existing process on port $PORT..."

# Kill any process holding port 8001 (uvicorn/python)
if /usr/sbin/lsof -ti tcp:"$PORT" >/dev/null 2>&1; then
  PIDS=$(/usr/sbin/lsof -ti tcp:"$PORT")
  echo "$LOG_PREFIX Killing existing PID(s) on port $PORT: $PIDS"
  kill $PIDS 2>/dev/null || true
  sleep 2
  # Force kill if still alive
  if /usr/sbin/lsof -ti tcp:"$PORT" >/dev/null 2>&1; then
    PIDS=$(/usr/sbin/lsof -ti tcp:"$PORT")
    echo "$LOG_PREFIX Force-killing remaining PID(s): $PIDS"
    kill -9 $PIDS 2>/dev/null || true
    sleep 1
  fi
fi

echo "$LOG_PREFIX Starting MemOS server on port $PORT..."
exec "$VENV_UVICORN" memos.api.server_api:app \
  --host 0.0.0.0 \
  --port "$PORT" \
  --log-level warning
