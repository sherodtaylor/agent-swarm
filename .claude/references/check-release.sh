#!/usr/bin/env bash
# Verify that a released version has all expected artifacts:
#   1. Git tag exists
#   2. GitHub Release exists
#   3. Container image pullable from GHCR
#   4. Helm chart pullable from GHCR OCI
#
# Usage:
#   ./check-release.sh --version 0.1.15
#   ./check-release.sh --version v0.1.15
set -euo pipefail
source "$(dirname "$0")/gh-token.sh"

REPO="${REPO:-sherodtaylor/agent-smith}"
CHART_REPO="${CHART_REPO:-ghcr.io/sherodtaylor/charts}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/sherodtaylor/agent-smith}"
VERSION=""
FAILURES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --repo)    REPO="$2";    shift 2 ;;
    -h|--help)
      echo "Usage: $0 --version X.Y.Z [--repo owner/name]"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "ERROR: --version is required" >&2
  exit 1
fi
VERSION="${VERSION#v}"
TAG="v${VERSION}"

echo "[check-release] $REPO $TAG"
echo ""

# 1. Git tag
printf '%-40s' "Git tag $TAG ..."
TAG_SHA=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/${REPO}/git/refs/tags/${TAG}" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['object']['sha'][:12] if 'object' in d else '')
" 2>/dev/null)
if [ -n "$TAG_SHA" ]; then
  echo "OK ($TAG_SHA)"
else
  echo "MISSING"
  FAILURES=$((FAILURES + 1))
fi

# 2. GitHub Release
printf '%-40s' "GitHub Release $TAG ..."
RELEASE=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('html_url', ''))
" 2>/dev/null)
if [ -n "$RELEASE" ]; then
  echo "OK"
else
  echo "MISSING"
  FAILURES=$((FAILURES + 1))
fi

# 3. Container image (manifest inspect via GHCR API — no pull needed)
printf '%-40s' "Image ${IMAGE_REPO}:${TAG} ..."
IMG_TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:sherodtaylor/agent-smith:pull" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))")
IMG_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $IMG_TOKEN" \
  "https://ghcr.io/v2/sherodtaylor/agent-smith/manifests/${TAG}")
if [ "$IMG_STATUS" = "200" ]; then
  echo "OK"
else
  echo "MISSING (HTTP $IMG_STATUS)"
  FAILURES=$((FAILURES + 1))
fi

# 4. Helm chart OCI (via GHCR manifest inspect)
printf '%-40s' "Chart agent-smith:${VERSION} ..."
CHART_TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:sherodtaylor/charts/agent-smith:pull" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))")
CHART_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $CHART_TOKEN" \
  "https://ghcr.io/v2/sherodtaylor/charts/agent-smith/manifests/${VERSION}")
if [ "$CHART_STATUS" = "200" ]; then
  echo "OK"
else
  echo "MISSING (HTTP $CHART_STATUS)"
  FAILURES=$((FAILURES + 1))
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All artifacts present for $TAG ✓"
else
  echo "$FAILURES artifact(s) missing — check CI at https://github.com/${REPO}/actions"
  exit 1
fi
