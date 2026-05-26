#!/usr/bin/env bash
# Restore stub credentials in a running agent pod.
# Used when claude-loop.sh's normal restore hasn't fired yet but you need to
# confirm the stub is in place without a full pod restart.
#
# Usage:
#   ./restore-stub-creds.sh --agent devbot
set -euo pipefail

NAMESPACE="${NAMESPACE:-agents}"
AGENT=""
STUB_SRC="/opt/agent-smith/agents/_shared/.credentials.json"
CREDS_DST="/root/.claude/.credentials.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent|-a)     AGENT="$2";     shift 2 ;;
    --namespace|-n) NAMESPACE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --agent <name> [--namespace <ns>]"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$AGENT" ]; then
  echo "ERROR: --agent is required" >&2
  exit 1
fi

POD="${AGENT}-0"

echo "[restore-creds] checking current credentials in ${NAMESPACE}/${POD}"
CURRENT=$(kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  jq -r '.claudeAiOauth.accessToken' "${CREDS_DST}" 2>/dev/null || echo "error reading")
echo "[restore-creds] current accessToken: ${CURRENT}"

if [ "$CURRENT" = "access-token-stub" ]; then
  echo "[restore-creds] stub already in place — nothing to do"
  exit 0
fi

echo "[restore-creds] restoring stub credentials..."
kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  bash -c "cp '${STUB_SRC}' '${CREDS_DST}' && chmod 600 '${CREDS_DST}'"

AFTER=$(kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  jq -r '.claudeAiOauth.accessToken' "${CREDS_DST}" 2>/dev/null)
echo "[restore-creds] accessToken after restore: ${AFTER}"

if [ "$AFTER" = "access-token-stub" ]; then
  echo "[restore-creds] restored successfully"
else
  echo "[restore-creds] ERROR: restore did not work (got: ${AFTER})" >&2
  exit 1
fi
