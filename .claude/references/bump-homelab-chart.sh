#!/usr/bin/env bash
# Bump the agent-smith chart version on HelmRelease files in sherodtaylor/homelab.
# Updates devbot-helmrelease.yaml and infrabot-helmrelease.yaml (and any additional
# *-helmrelease.yaml files that reference chart: agent-smith).
#
# Usage:
#   ./bump-homelab-chart.sh --version 0.1.16
#   ./bump-homelab-chart.sh --version 0.1.16 --dry-run
set -euo pipefail
source "$(dirname "$0")/gh-token.sh"

HOMELAB_REPO="${HOMELAB_REPO:-sherodtaylor/homelab}"
AGENTS_PATH="k8s/apps/agents"
VERSION=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)       VERSION="$2";       shift 2 ;;
    --homelab-repo)  HOMELAB_REPO="$2";  shift 2 ;;
    --dry-run)       DRY_RUN=1;          shift   ;;
    -h|--help)
      echo "Usage: $0 --version X.Y.Z [--homelab-repo owner/name] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "ERROR: --version is required (e.g. --version 0.1.16)" >&2
  exit 1
fi
# Accept either "0.1.16" or "v0.1.16"
VERSION="${VERSION#v}"

echo "[bump] repo=${HOMELAB_REPO} version=${VERSION} dry_run=${DRY_RUN}"

# Find all agent HelmRelease files under the agents path
FILES=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/${HOMELAB_REPO}/contents/${AGENTS_PATH}" \
  | python3 -c "
import json, sys
items = json.load(sys.stdin)
for f in items:
    if f['name'].endswith('-helmrelease.yaml'):
        print(f['path'])
")

if [ -z "$FILES" ]; then
  echo "ERROR: no *-helmrelease.yaml files found under ${AGENTS_PATH}" >&2
  exit 1
fi

for FILEPATH in $FILES; do
  echo "[bump] processing $FILEPATH"

  # Fetch current content + SHA
  RESP=$(curl -s -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/${HOMELAB_REPO}/contents/${FILEPATH}")
  FILE_SHA=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['sha'])")
  CONTENT=$(echo "$RESP" | python3 -c "
import json, sys, base64
print(base64.b64decode(json.load(sys.stdin)['content']).decode())
")

  # Check whether this file references chart: agent-smith
  if ! echo "$CONTENT" | grep -q "chart: agent-smith"; then
    echo "[bump] $FILEPATH does not reference chart: agent-smith — skipping"
    continue
  fi

  # Detect current version
  CURRENT=$(echo "$CONTENT" | python3 -c "
import sys, re
m = re.search(r'version:\s+\"([^\"]+)\"', sys.stdin.read())
print(m.group(1) if m else '')
")
  if [ "$CURRENT" = "$VERSION" ]; then
    echo "[bump] $FILEPATH already at $VERSION — skipping"
    continue
  fi

  echo "[bump] $FILEPATH: $CURRENT → $VERSION"

  NEW_CONTENT=$(echo "$CONTENT" | python3 -c "
import sys, re
content = sys.stdin.read()
# Only replace the chart spec version, not any other version: field
new = re.sub(r'(chart:\s*\n\s*spec:\s*\n(?:.*\n)*?.*version:\s+\")[^\"]+\"', lambda m: m.group(0).replace(m.group(0).split('\"')[-2], '${VERSION}'), content)
# Simpler targeted replace: first occurrence after 'chart: agent-smith'
lines = content.splitlines(keepends=True)
in_chart_spec = False
for i, line in enumerate(lines):
    if 'chart: agent-smith' in line:
        in_chart_spec = True
    if in_chart_spec and re.match(r'\s+version:\s+\"', line):
        lines[i] = re.sub(r'version:\s+\"[^\"]+\"', 'version: \"${VERSION}\"', line)
        break
print(''.join(lines), end='')
")

  if [ "$DRY_RUN" = "1" ]; then
    echo "[bump] DRY RUN — would update $FILEPATH to version $VERSION"
    continue
  fi

  ENCODED=$(echo -n "$NEW_CONTENT" | base64 -w0)
  curl -s -X PUT \
    -H "Authorization: token $GH_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.github.com/repos/${HOMELAB_REPO}/contents/${FILEPATH}" \
    -d "{
      \"message\": \"chore: bump agent-smith chart to v${VERSION}\",
      \"content\": \"${ENCODED}\",
      \"sha\": \"${FILE_SHA}\"
    }" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if 'content' in d:
    print('[bump] updated:', d['content']['name'])
else:
    print('[bump] ERROR:', json.dumps(d)[:200])
    sys.exit(1)
"
done

echo "[bump] done — Flux will reconcile on next poll (or run: flux reconcile helmrelease devbot infrabot -n agents)"
