#!/usr/bin/env bash
# Shared helper: resolve GH_TOKEN from env or ~/.config/gh/hosts.yml
# Source this file; it exports GH_TOKEN into the calling script's env.
#
# Usage: source "$(dirname "$0")/gh-token.sh"

if [ -z "${GH_TOKEN:-}" ]; then
  _HOSTS="${HOME}/.config/gh/hosts.yml"
  if [ -f "$_HOSTS" ]; then
    GH_TOKEN=$(python3 -c "
import re, sys
data = open('${_HOSTS}').read()
m = re.search(r'oauth_token:\s+(\S+)', data)
if m: print(m.group(1))
else: sys.exit(1)
" 2>/dev/null) || true
  fi
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "[gh-token] ERROR: GH_TOKEN not set and not found in ~/.config/gh/hosts.yml" >&2
  exit 1
fi

export GH_TOKEN
