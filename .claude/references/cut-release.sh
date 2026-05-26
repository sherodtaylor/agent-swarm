#!/usr/bin/env bash
# Cut a versioned release: annotated tag + GitHub Release.
# CI publishes the image and Helm chart automatically on the tag.
#
# Usage:
#   ./cut-release.sh --version v0.1.16 --message "short summary"
#   ./cut-release.sh --version v0.1.16 --message "short summary" --dry-run
#
# After this: run bump-homelab-chart.sh to roll the cluster.
set -euo pipefail
source "$(dirname "$0")/gh-token.sh"

REPO="${REPO:-sherodtaylor/agent-smith}"
VERSION=""
MESSAGE=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  VERSION="$2";  shift 2 ;;
    --message)  MESSAGE="$2";  shift 2 ;;
    --repo)     REPO="$2";     shift 2 ;;
    --dry-run)  DRY_RUN=1;     shift   ;;
    -h|--help)
      echo "Usage: $0 --version vX.Y.Z --message 'summary' [--repo owner/name] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$VERSION" ] || [ -z "$MESSAGE" ]; then
  echo "ERROR: --version and --message are required" >&2
  exit 1
fi
if ! echo "$VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: version must be vX.Y.Z (got: $VERSION)" >&2
  exit 1
fi

echo "[release] repo=$REPO version=$VERSION dry_run=$DRY_RUN"

# Get main HEAD
MAIN_SHA=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/${REPO}/git/refs/heads/main" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['object']['sha'])")
echo "[release] main HEAD: ${MAIN_SHA:0:12}"

# Check tag doesn't already exist
EXISTS=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/${REPO}/git/refs/tags/${VERSION}" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if 'ref' in d else 'no')")
if [ "$EXISTS" = "yes" ]; then
  echo "ERROR: tag $VERSION already exists on $REPO" >&2
  exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "[release] DRY RUN — would tag $VERSION at ${MAIN_SHA:0:12} with message: $MESSAGE"
  echo "[release] DRY RUN — would create GitHub Release '$VERSION'"
  exit 0
fi

# Create annotated tag object
TAG_SHA=$(curl -s -X POST \
  -H "Authorization: token $GH_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/${REPO}/git/tags" \
  -d "{
    \"tag\": \"${VERSION}\",
    \"message\": \"${VERSION} — ${MESSAGE}\",
    \"object\": \"${MAIN_SHA}\",
    \"type\": \"commit\",
    \"tagger\": {
      \"name\": \"sherodtaylor\",
      \"email\": \"sherodtaylor@gmail.com\",
      \"date\": \"$(date -u +%FT%TZ)\"
    }
  }" | python3 -c "import json,sys; print(json.load(sys.stdin)['sha'])")
echo "[release] tag object created: ${TAG_SHA:0:12}"

# Create ref
curl -s -X POST \
  -H "Authorization: token $GH_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/${REPO}/git/refs" \
  -d "{\"ref\":\"refs/tags/${VERSION}\",\"sha\":\"${TAG_SHA}\"}" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('[release] ref created:', d.get('ref','ERROR'))"

# Create GitHub Release
RELEASE_URL=$(curl -s -X POST \
  -H "Authorization: token $GH_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/${REPO}/releases" \
  -d "{
    \"tag_name\": \"${VERSION}\",
    \"name\": \"${VERSION}\",
    \"body\": \"## ${VERSION}\\n\\n${MESSAGE}\\n\\n---\\n_Update CHANGELOG.md body if not yet done._\",
    \"draft\": false,
    \"prerelease\": false
  }" | python3 -c "import json,sys; print(json.load(sys.stdin)['html_url'])")

echo "[release] GitHub Release: $RELEASE_URL"
echo "[release] CI is now building image + chart — watch: https://github.com/${REPO}/actions"
echo "[release] Next step: run bump-homelab-chart.sh --version ${VERSION#v}"
