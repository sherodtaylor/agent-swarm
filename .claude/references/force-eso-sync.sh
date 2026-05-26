#!/usr/bin/env bash
# Force an ExternalSecret to re-sync from Infisical immediately,
# without waiting for the 1-hour refresh interval.
#
# Usage:
#   ./force-eso-sync.sh --name devbot-secrets --namespace agents
#   ./force-eso-sync.sh --name iron-proxy-upstream-secrets --namespace agent-infra
set -euo pipefail

NAMESPACE=""
SECRET_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|-n)      SECRET_NAME="$2"; shift 2 ;;
    --namespace|-s) NAMESPACE="$2";   shift 2 ;;
    -h|--help)
      echo "Usage: $0 --name <externalsecret-name> --namespace <ns>"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$SECRET_NAME" ] || [ -z "$NAMESPACE" ]; then
  echo "ERROR: --name and --namespace are required" >&2
  exit 1
fi

echo "[eso-sync] annotating ${NAMESPACE}/${SECRET_NAME}"
kubectl annotate externalsecret -n "${NAMESPACE}" "${SECRET_NAME}" \
  force-sync="$(date +%s)" --overwrite

echo "[eso-sync] waiting for sync..."
for i in $(seq 1 30); do
  REFRESH=$(kubectl get externalsecret -n "${NAMESPACE}" "${SECRET_NAME}" \
    -o jsonpath='{.status.refreshTime}' 2>/dev/null || echo "")
  STATUS=$(kubectl get externalsecret -n "${NAMESPACE}" "${SECRET_NAME}" \
    -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "")
  if [ "$STATUS" = "SecretSynced" ]; then
    echo "[eso-sync] synced at ${REFRESH}"
    break
  fi
  echo "[eso-sync] still waiting (${i}/30)... status=${STATUS}"
  sleep 2
done

echo "[eso-sync] current status:"
kubectl get externalsecret -n "${NAMESPACE}" "${SECRET_NAME}" \
  -o jsonpath='{.status}' | python3 -m json.tool 2>/dev/null || \
  kubectl get externalsecret -n "${NAMESPACE}" "${SECRET_NAME}"
