#!/usr/bin/env bash
# memos-healthcheck.sh — MemOS 5-minute health monitoring
# Runs every 5 min via LaunchAgent: com.openclaw.memos-healthcheck
#
# Checks:
#   1. HTTP liveness  → POST /product/search must return 200
#   2. Test write     → POST /product/add must succeed
#   3. Test recall    → POST /product/search must return >0 results
#   4. Log scan       → grep memos-server.log for LLM errors + rate limits
#
# Logs: ~/.openclaw/logs/memos-health-YYYY-MM-DD.jsonl
# Alerts: Discord #ops (1475523339316629604) on non-self-resolving failures
# Clean-day tracker: ~/.openclaw/logs/memos-clean-days.json
#   - Resets only on failures requiring manual intervention
#   - 429 rate limits are self-resolving and do NOT reset the counter
#   - 5 consecutive clean days = cutover-ready signal

MEMOS_URL="http://localhost:8001"
MEMOS_USER="openclaw-user"
LOG_DIR="${HOME}/.openclaw/logs"
MEMOS_LOG="${LOG_DIR}/memos-server.log"
OPS_CHANNEL="1475523339316629604"
CLEAN_DAYS_FILE="${LOG_DIR}/memos-clean-days.json"
ENV_FILE="${HOME}/.openclaw/.env"
TMP_SEARCH="/tmp/memos-hc-search.json"
TMP_WRITE="/tmp/memos-hc-write.json"
TMP_RECALL="/tmp/memos-hc-recall.json"

# Load env (for DISCORD_FORGE_BOT_TOKEN)
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}"

TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
DATE=$(date '+%Y-%m-%d')
DAILY_LOG="${LOG_DIR}/memos-health-${DATE}.jsonl"

# Result state
PORT_UP="false"
WRITE_OK="false"
RECALL_OK="false"
LLM_ERRORS=0
RATE_LIMITS=0
NEEDS_ALERT="false"
NEEDS_COUNTER_RESET="false"
ALERT_PARTS=""

# ─── Check 1: HTTP liveness ───────────────────────────────────────────────────
HTTP_CODE=$(curl -s -o "${TMP_SEARCH}" -w "%{http_code}" \
  -X POST "${MEMOS_URL}/product/search" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"healthcheck\",\"limit\":1,\"user_id\":\"${MEMOS_USER}\"}" \
  --connect-timeout 5 --max-time 10 2>/dev/null) || HTTP_CODE="000"

if [[ "${HTTP_CODE}" == "200" ]]; then
  PORT_UP="true"
else
  NEEDS_ALERT="true"
  NEEDS_COUNTER_RESET="true"
  ALERT_PARTS="${ALERT_PARTS}⛔ Port 8001 DOWN (HTTP ${HTTP_CODE})\n"
fi

# ─── Check 2: Test write ─────────────────────────────────────────────────────
if [[ "${PORT_UP}" == "true" ]]; then
  WRITE_CODE=$(curl -s -o "${TMP_WRITE}" -w "%{http_code}" \
    -X POST "${MEMOS_URL}/product/add" \
    -H "Content-Type: application/json" \
    -d "{\"user_id\":\"${MEMOS_USER}\",\"messages\":[{\"role\":\"user\",\"content\":\"healthcheck-probe-${TS}\"},{\"role\":\"assistant\",\"content\":\"healthcheck-ok\"}]}" \
    --connect-timeout 5 --max-time 25 2>/dev/null) || WRITE_CODE="000"

  if [[ "${WRITE_CODE}" == "200" ]]; then
    WRITE_OK="true"
  else
    NEEDS_ALERT="true"
    NEEDS_COUNTER_RESET="true"
    ALERT_PARTS="${ALERT_PARTS}⚠️ Write check FAILED (HTTP ${WRITE_CODE})\n"
  fi
fi

# ─── Check 3: Test recall ─────────────────────────────────────────────────────
if [[ "${PORT_UP}" == "true" ]]; then
  RECALL_CODE=$(curl -s -o "${TMP_RECALL}" -w "%{http_code}" \
    -X POST "${MEMOS_URL}/product/search" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"healthcheck-probe\",\"limit\":3,\"user_id\":\"${MEMOS_USER}\"}" \
    --connect-timeout 5 --max-time 25 2>/dev/null) || RECALL_CODE="000"

  if [[ "${RECALL_CODE}" == "200" ]]; then
    MEM_COUNT=$(python3 -c "
import json, sys
try:
    with open('${TMP_RECALL}') as f:
        d = json.load(f)
    data = d.get('data') or {}
    # MemOS returns: text_mem, act_mem, para_mem, pref_mem, tool_mem, skill_mem (all lists)
    total = sum(len(v) for v in data.values() if isinstance(v, list))
    print(total)
except:
    print(0)
" 2>/dev/null || echo "0")
    if [[ "${MEM_COUNT}" -gt 0 ]]; then
      RECALL_OK="true"
    else
      NEEDS_ALERT="true"
      NEEDS_COUNTER_RESET="true"
      ALERT_PARTS="${ALERT_PARTS}⚠️ Recall returned 0 results\n"
    fi
  else
    NEEDS_ALERT="true"
    NEEDS_COUNTER_RESET="true"
    ALERT_PARTS="${ALERT_PARTS}⚠️ Recall check FAILED (HTTP ${RECALL_CODE})\n"
  fi
fi

# ─── Check 4: Log scan (last ~5 min = ~150 lines at normal traffic) ──────────
# grep -c exits 1 when 0 matches but still outputs "0" — do NOT use "|| echo N"
# (that would double-output and corrupt the variable)
#
# Exclude [PROCESS_SKILLS] LLM errors — those are background skill memory
# processing failures, non-critical and expected. We only count LLM errors
# that indicate actual OpenRouter/API failures (lines with LLM generate failed
# but WITHOUT the [PROCESS_SKILLS] tag, and with error keywords like "rate",
# "connection", "timeout", or "500/503").
if [[ -f "${MEMOS_LOG}" ]]; then
  LLM_ERRORS=$(tail -150 "${MEMOS_LOG}" 2>/dev/null | grep "LLM generate failed" | grep -vc "\[PROCESS_SKILLS\]" 2>/dev/null)
  LLM_ERRORS=${LLM_ERRORS:-0}
  RATE_LIMITS=$(tail -150 "${MEMOS_LOG}" 2>/dev/null | grep -cE "429|RateLimitError|rate_limit_exceeded" 2>/dev/null)
  RATE_LIMITS=${RATE_LIMITS:-0}
fi

if [[ "${LLM_ERRORS}" -gt 0 ]]; then
  NEEDS_ALERT="true"
  NEEDS_COUNTER_RESET="true"
  ALERT_PARTS="${ALERT_PARTS}⚠️ LLM generate errors: ${LLM_ERRORS} in recent log\n"
fi

# 429s are self-resolving: alert but do NOT reset clean-day counter
if [[ "${RATE_LIMITS}" -gt 0 ]]; then
  NEEDS_ALERT="true"
  ALERT_PARTS="${ALERT_PARTS}⏳ Rate limits: ${RATE_LIMITS} (self-resolving — counter NOT reset)\n"
fi

# ─── Write JSONL entry ────────────────────────────────────────────────────────
python3 -c "
import json
entry = {
    'ts': '${TS}',
    'port_up': '${PORT_UP}' == 'true',
    'write_ok': '${WRITE_OK}' == 'true',
    'recall_ok': '${RECALL_OK}' == 'true',
    'llm_errors': int('${LLM_ERRORS}'),
    'rate_limits': int('${RATE_LIMITS}')
}
print(json.dumps(entry))
" >> "${DAILY_LOG}" 2>/dev/null || true

# ─── Discord alert ────────────────────────────────────────────────────────────
if [[ "${NEEDS_ALERT}" == "true" && -n "${DISCORD_FORGE_BOT_TOKEN:-}" ]]; then
  python3 -c "
import json, sys, subprocess
parts = '${ALERT_PARTS}'.replace('\\\\n', '\n')
msg = f'🔴 **MemOS Health Alert** \`${TS}\`\n{parts}\nSee: \`memos-health-${DATE}.jsonl\`'
payload = json.dumps({'content': msg[:1990]})
result = subprocess.run([
    'curl', '-s', '-X', 'POST',
    'https://discord.com/api/v10/channels/${OPS_CHANNEL}/messages',
    '-H', 'Authorization: Bot ${DISCORD_FORGE_BOT_TOKEN}',
    '-H', 'Content-Type: application/json',
    '-d', payload,
    '--max-time', '10'
], capture_output=True, timeout=15)
" 2>/dev/null || true
fi

# ─── State file update ────────────────────────────────────────────────────────
# Lens spec: state file must use `last_failure_type` ("auto-resolve" | "manual-intervention")
# and `cutover_eligible` (not `cutover_ready`).
# 429s = "auto-resolve": alert only, do NOT reset counter
# port/write/recall/llm = "manual-intervention": reset counter to 0

if [[ "${NEEDS_COUNTER_RESET}" == "true" ]]; then
  # Manual-intervention failure — reset streak
  python3 -c "
import json, os
f = '${CLEAN_DAYS_FILE}'
try:
    with open(f) as fp:
        state = json.load(fp)
except:
    state = {}
state['consecutive_clean_days'] = 0
state['last_failure_type'] = 'manual-intervention'
state['last_failure_ts'] = '${TS}'
state['cutover_eligible'] = False
with open(f, 'w') as fp:
    json.dump(state, fp, indent=2)
" 2>/dev/null || true
elif [[ "${RATE_LIMITS}" -gt 0 ]]; then
  # Self-resolving failure (429) — record but do NOT reset streak
  python3 -c "
import json, os
f = '${CLEAN_DAYS_FILE}'
try:
    with open(f) as fp:
        state = json.load(fp)
except:
    state = {}
# Only update failure metadata — do NOT touch consecutive_clean_days or cutover_eligible
state['last_failure_type'] = 'auto-resolve'
state['last_failure_ts'] = '${TS}'
with open(f, 'w') as fp:
    json.dump(state, fp, indent=2)
" 2>/dev/null || true
fi

# ─── End-of-day tally (runs once at 23:55–23:59 each day) ────────────────────
HOUR=$(date '+%H')
MINUTE=$(date '+%M')
TALLY_SENTINEL="${LOG_DIR}/.memos-tally-${DATE}"

if [[ "${HOUR}" == "23" && "${MINUTE}" -ge "55" && ! -f "${TALLY_SENTINEL}" ]]; then
  touch "${TALLY_SENTINEL}"

  python3 << PYEOF
import json, os, sys
from datetime import datetime

daily_log  = '${DAILY_LOG}'
state_file = '${CLEAN_DAYS_FILE}'
date_str   = '${DATE}'
ops_channel = '${OPS_CHANNEL}'
bot_token  = '${DISCORD_FORGE_BOT_TOKEN}'

if not os.path.exists(daily_log):
    sys.exit(0)

entries = []
with open(daily_log) as f:
    for line in f:
        try:
            entries.append(json.loads(line.strip()))
        except:
            pass

if not entries:
    sys.exit(0)

total     = len(entries)
# streak_ok: port + write + recall all good AND no llm errors
# 429s (rate_limits) do NOT disqualify a window from streak_ok
healthy   = sum(1 for e in entries
               if e.get('port_up') and e.get('write_ok')
               and e.get('recall_ok') and e.get('llm_errors', 0) == 0)
llm_total = sum(e.get('llm_errors', 0) for e in entries)
rl_total  = sum(e.get('rate_limits', 0) for e in entries)
pct       = healthy / total * 100 if total else 0
is_clean  = (pct >= 95) and (llm_total == 0)

try:
    with open(state_file) as fp:
        state = json.load(fp)
except:
    state = {'consecutive_clean_days': 0, 'cutover_eligible': False}

# Migrate old schema: cutover_ready → cutover_eligible
if 'cutover_ready' in state and 'cutover_eligible' not in state:
    state['cutover_eligible'] = state.pop('cutover_ready')

if is_clean:
    state['consecutive_clean_days'] = state.get('consecutive_clean_days', 0) + 1
    state['last_clean_day'] = date_str
    if state['consecutive_clean_days'] >= 5 and not state.get('cutover_eligible'):
        state['cutover_eligible'] = True
        # Notify #ops: cutover eligible!
        try:
            import subprocess, json as _json
            msg = (f'✅ **MemOS Cutover Eligible** — 5 consecutive clean days achieved!\n'
                   f'Port ✅ | Write ✅ | Recall ✅ | LLM errors: 0\n'
                   f'Safe to cut over from QMD + MEMORY.md to MemOS.')
            payload = _json.dumps({'content': msg})
            subprocess.run([
                'curl', '-s', '-X', 'POST',
                f'https://discord.com/api/v10/channels/{ops_channel}/messages',
                '-H', f'Authorization: Bot {bot_token}',
                '-H', 'Content-Type: application/json',
                '-d', payload, '--max-time', '10'
            ], capture_output=True, timeout=15)
        except:
            pass
else:
    # Only reset if we didn't already reset mid-day due to a manual-intervention failure
    if state.get('consecutive_clean_days', 0) > 0:
        state['consecutive_clean_days'] = 0
        state['cutover_eligible'] = False

state['last_checked_day'] = date_str
state['last_day_stats'] = {
    'total_checks': total,
    'healthy_checks': healthy,
    'pct_healthy': round(pct, 1),
    'llm_errors': llm_total,
    'rate_limits': rl_total,
    'clean': is_clean
}
with open(state_file, 'w') as fp:
    json.dump(state, fp, indent=2)

print(f'Day tally {date_str}: {healthy}/{total} ({pct:.0f}% healthy), '
      f'clean={is_clean}, streak={state["consecutive_clean_days"]}')
PYEOF
fi

exit 0
