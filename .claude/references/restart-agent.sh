#!/usr/bin/env bash
# Delete an agent pod and wait for it to come back Ready.
# The StatefulSet recreates the pod; setup.sh re-runs the init container.
#
# Usage:
#   ./restart-agent.sh --agent devbot
#   ./restart-agent.sh --agent infrabot --namespace agents
set -euo pipefail

NAMESPACE="${NAMESPACE:-agents}"
AGENT=""
TIMEOUT="${TIMEOUT:-180}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent|-a)     AGENT="$2";     shift 2 ;;
    --namespace|-n) NAMESPACE="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2";   shift 2 ;;
    -h|--help)
      echo "Usage: $0 --agent <name> [--namespace <ns>] [--timeout <seconds>]"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$AGENT" ]; then
  echo "ERROR: --agent is required (e.g. --agent devbot)" >&2
  exit 1
fi

POD="${AGENT}-0"
echo "[restart] deleting pod ${NAMESPACE}/${POD}"
kubectl delete pod -n "${NAMESPACE}" "${POD}"

echo "[restart] waiting for ${POD} to come back Ready (timeout=${TIMEOUT}s)"
kubectl wait pod -n "${NAMESPACE}" "${POD}" \
  --for=condition=Ready \
  --timeout="${TIMEOUT}s"

echo "[restart] ${POD} is Ready"
echo "[restart] tail recent logs:"
kubectl logs -n "${NAMESPACE}" "${POD}" --tail=30
