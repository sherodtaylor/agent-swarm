#!/usr/bin/env bash
# Smoke tests for loop scripts — credential restoration and error-exit behavior.
# Run from repo root: bash tests/test-loops.sh
set -uo pipefail   # intentionally no -e: we capture non-zero exits explicitly

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Mock credentials template
CREDS_SRC="${WORKDIR}/shared/.credentials.json"
mkdir -p "$(dirname "$CREDS_SRC")"
echo '{"claudeAiOauth":{"accessToken":"access-token-stub","subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}' \
  > "$CREDS_SRC"

MOCK_HOME="${WORKDIR}/home"
mkdir -p "${MOCK_HOME}/.claude"

MOCK_BIN="${WORKDIR}/bin"
mkdir -p "$MOCK_BIN"

# Mock sleep: no-op so backoff doesn't slow tests down
cat > "${MOCK_BIN}/sleep" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "${MOCK_BIN}/sleep"

# Mock claude binary:
# - records whether subscriptionType was 'max' at invocation time (credential restoration check)
# - corrupts subscriptionType to null on each invocation (simulates OAuth refresh)
# - exits 0 after 3 runs so the test loop terminates
cat > "${MOCK_BIN}/claude" <<'MOCKEOF'
#!/usr/bin/env bash
CREDS="${HOME}/.claude/.credentials.json"
RUNFILE="${HOME}/.claude/.runcount"
RESTORE_LOG="${HOME}/.claude/.restore_log"
COUNT=$(cat "$RUNFILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$RUNFILE"

# Record whether subscriptionType was 'max' at this invocation
SUBTYPE=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
print(d['claudeAiOauth']['subscriptionType'])
" "$CREDS" 2>/dev/null || echo "error")
echo "$SUBTYPE" >> "$RESTORE_LOG"

# Corrupt the credential (simulates OAuth token refresh clobbering it)
python3 -c "
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
d['claudeAiOauth']['subscriptionType'] = None
with open(sys.argv[1], 'w') as f: json.dump(d, f)
" "$CREDS" 2>/dev/null || true

if [ "$COUNT" -ge 3 ]; then exit 0; fi
exit 1
MOCKEOF
chmod +x "${MOCK_BIN}/claude"

# ── Test 1: claude-loop.sh restores subscriptionType before each start ──
echo "--- Test 1: credential restoration on restart ---"
rm -f "${MOCK_HOME}/.claude/.runcount" "${MOCK_HOME}/.claude/.restore_log"

CREDS_SRC="$CREDS_SRC" HOME="$MOCK_HOME" PATH="${MOCK_BIN}:${PATH}" \
  timeout 15 bash "${SCRIPT_DIR}/../scripts/claude-loop.sh" 2>/dev/null || true

# Every entry in the restore log should be 'max' (creds restored before each run)
RESTORE_LOG="${MOCK_HOME}/.claude/.restore_log"
BAD_ENTRIES=$(grep -cv '^max$' "$RESTORE_LOG" 2>/dev/null; true)
GOOD_ENTRIES=$(grep -c '^max$' "$RESTORE_LOG" 2>/dev/null; true)

if [ "${BAD_ENTRIES:-1}" = "0" ] && [ "${GOOD_ENTRIES:-0}" -ge 1 ]; then
  pass "subscriptionType was 'max' at every claude invocation (${GOOD_ENTRIES} run(s))"
else
  fail "subscriptionType was not always 'max' before invocation — restore_log: $(cat "$RESTORE_LOG" 2>/dev/null)"
fi

RUNCOUNT=$(cat "${MOCK_HOME}/.claude/.runcount" 2>/dev/null || echo 0)
if [ "$RUNCOUNT" -ge 3 ]; then
  pass "claude restarted at least 3 times (got ${RUNCOUNT})"
else
  fail "claude only ran ${RUNCOUNT} time(s) — expected 3+"
fi

# ── Test 2: claude-loop.sh exits 1 when creds template is missing ──
echo "--- Test 2: exit 1 on missing credentials template ---"
EXIT_CODE=0
CREDS_SRC="/nonexistent/path" HOME="$MOCK_HOME" PATH="${MOCK_BIN}:${PATH}" \
  bash "${SCRIPT_DIR}/../scripts/claude-loop.sh" 2>/dev/null || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 1 ]; then
  pass "claude-loop.sh exits 1 when credentials template is missing"
else
  fail "claude-loop.sh expected exit 1, got exit ${EXIT_CODE}"
fi

# ── Test 3: rc-loop.sh exits 1 when creds template is missing ──
echo "--- Test 3: rc-loop.sh exits 1 on missing credentials template ---"
EXIT_CODE=0
CREDS_SRC="/nonexistent/path" HOME="$MOCK_HOME" PATH="${MOCK_BIN}:${PATH}" \
  bash "${SCRIPT_DIR}/../scripts/rc-loop.sh" 2>/dev/null || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 1 ]; then
  pass "rc-loop.sh exits 1 when credentials template is missing"
else
  fail "rc-loop.sh expected exit 1, got exit ${EXIT_CODE}"
fi

# ── Test 4: keepalive-loop.sh exits 0 when prompts file is absent ──
echo "--- Test 4: keepalive exits 0 when prompts file absent ---"
EXIT_CODE=0
AGENT_NAME="devbot" bash "${SCRIPT_DIR}/../scripts/keepalive-loop.sh" 2>/dev/null || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  pass "keepalive-loop.sh exits 0 when prompts file is absent"
else
  fail "keepalive-loop.sh expected exit 0, got exit ${EXIT_CODE}"
fi

# ── Test 5: rc-loop.sh writes credentials to /root/rc-home ──
echo "--- Test 5: rc-loop.sh credential destination ---"
if [ -w "/root" ] || [ -w "/root/rc-home" ] 2>/dev/null; then
  mkdir -p /root/rc-home/.claude
  rm -f /root/rc-home/.claude/.credentials.json

  # Run rc-loop.sh briefly (it will try to start claude and fail immediately)
  CREDS_SRC="$CREDS_SRC" PATH="${MOCK_BIN}:${PATH}" \
    timeout 5 bash "${SCRIPT_DIR}/../scripts/rc-loop.sh" 2>/dev/null || true

  # The loop should have copied credentials before trying to run claude
  if [ -f "/root/rc-home/.claude/.credentials.json" ]; then
    SUBTYPE=$(python3 -c "
import json
with open('/root/rc-home/.claude/.credentials.json') as f:
    d = json.load(f)
print(d['claudeAiOauth']['subscriptionType'])
" 2>/dev/null || echo "error")
    if [ "$SUBTYPE" = "max" ]; then
      pass "rc-loop.sh writes credentials with subscriptionType='max' to /root/rc-home"
    else
      fail "rc-loop.sh wrote credentials but subscriptionType='${SUBTYPE}' not 'max'"
    fi
  else
    fail "rc-loop.sh did not write credentials to /root/rc-home/.claude/.credentials.json"
  fi
else
  echo "SKIP: Test 5 requires write access to /root — skipping in non-root environment"
fi

# ── Summary ──
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
