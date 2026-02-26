#!/bin/bash
# start-memos.sh — Start MemOS server with Python 3.13 venv
# Fix for: pydantic.v1.typing incompatible with Python 3.14 (via volcengine SDK)
# JAC-xxx — Applied by Forge 2026-02-25
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"
LOG="/tmp/memos-server.log"

if ! "$VENV/bin/python" --version 2>&1 | grep -q "3.13"; then
  echo "ERROR: .venv Python is not 3.13 — check venv setup"
  exit 1
fi

# Kill existing server if running
pkill -f "uvicorn memos.api.server_api" 2>/dev/null || true
sleep 1

# Load env and start server
cd "$SCRIPT_DIR"
set -a && source .env && set +a
nohup "$VENV/bin/uvicorn" memos.api.server_api:app \
  --host 0.0.0.0 --port 8001 --log-level warning \
  > "$LOG" 2>&1 &

echo "MemOS server started (PID $!) with Python 3.13 on port 8001"
echo "Log: $LOG"
