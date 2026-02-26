#!/usr/bin/env bash
# health-probe.sh — MemOS server health check on port 8001
# Usage: ./health-probe.sh [--quiet]
# Exit 0 = healthy, Exit 1 = unhealthy

QUIET="${1:-}"
ENDPOINT="http://localhost:8001/product/search"
PAYLOAD='{"query":"healthcheck","limit":1,"user_id":"openclaw-user"}'
TIMEOUT=5

response=$(curl -s -m "$TIMEOUT" -o /tmp/memos-health.json -w "%{http_code}" \
  -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>/dev/null)

http_code="$response"

if [ "$http_code" = "200" ]; then
  code=$(python3 -c "import json,sys; d=json.load(open('/tmp/memos-health.json')); print(d.get('code',''))" 2>/dev/null)
  if [ "$code" = "200" ]; then
    [ -z "$QUIET" ] && echo "✅ MemOS healthy (HTTP 200, code=200, port 8001)"
    exit 0
  else
    [ -z "$QUIET" ] && echo "⚠️  MemOS responded HTTP 200 but API code=$code"
    exit 1
  fi
elif [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
  [ -z "$QUIET" ] && echo "❌ MemOS unreachable (port 8001 not responding)"
  exit 1
else
  [ -z "$QUIET" ] && echo "❌ MemOS returned HTTP $http_code"
  exit 1
fi
