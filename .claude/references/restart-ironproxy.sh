#!/usr/bin/env bash
# Rollout restart iron-proxy and wait for the new pod to be Ready.
# Required when rotating CLAUDE_CODE_OAUTH_TOKEN or changing the domain allowlist,
# since iron-proxy reads env values only at process start.
#
# Usage: ./restart-ironproxy.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-agent-infra}"
DEPLOY="${DEPLOY:-iron-proxy}"

echo "[ironproxy] restarting deployment/${DEPLOY} in namespace ${NAMESPACE}"
kubectl rollout restart deployment/"${DEPLOY}" -n "${NAMESPACE}"

echo "[ironproxy] waiting for rollout to complete..."
kubectl rollout status deployment/"${DEPLOY}" -n "${NAMESPACE}"

echo "[ironproxy] done. Current pods:"
kubectl get pods -n "${NAMESPACE}" -l app="${DEPLOY}"
