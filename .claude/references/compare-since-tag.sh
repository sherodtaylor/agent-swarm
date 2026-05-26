#!/usr/bin/env bash
# Show commits on main since the last vX.Y.Z tag.
# Use this before cutting a release to decide what version bump is appropriate.
#
# Usage: ./compare-since-tag.sh [--repo owner/name]
set -euo pipefail
source "$(dirname "$0")/gh-token.sh"

REPO="${REPO:-sherodtaylor/agent-smith}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--repo owner/name]"
      echo "Shows commits on main since the last vX.Y.Z tag."
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

echo "[compare] repo=$REPO"

# Latest semver tag
LAST_TAG=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/${REPO}/tags?per_page=20" \
  | python3 -c "
import json, sys, re
tags = json.load(sys.stdin)
semver = [t['name'] for t in tags if re.match(r'^v\d+\.\d+\.\d+$', t['name'])]
print(semver[0] if semver else '')
")

if [ -z "$LAST_TAG" ]; then
  echo "[compare] No semver tags found. Showing all commits on main." >&2
  BASE="$(curl -s -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/${REPO}/commits?sha=main&per_page=1" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['parents'][0]['sha'] if json.load(sys.stdin) else '')" 2>/dev/null || echo "")"
  LAST_TAG="HEAD~1"
fi

echo "[compare] comparing ${LAST_TAG}...main"
echo ""

curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/${REPO}/compare/${LAST_TAG}...main" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
ahead = d.get('ahead_by', 0)
if ahead == 0:
    print('main is even with', sys.argv[1], '— nothing to release.')
    sys.exit(0)
print(f'main is {ahead} commit(s) ahead of', sys.argv[1])
print()
for c in d['commits']:
    msg = c['commit']['message'].splitlines()[0]
    sha = c['sha'][:8]
    print(f'  {sha}  {msg}')
" "$LAST_TAG"
