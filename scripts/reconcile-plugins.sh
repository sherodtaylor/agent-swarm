#!/usr/bin/env bash
# reconcile-plugins.sh — converge installed Claude plugins to the declarations
# in agents/_shared/settings.json (enabledPlugins map).
#
# Usage: APP_DIR=/opt/agent-smith CLAUDE_DIR=$HOME/.claude bash reconcile-plugins.sh
#
# Fail-open: set -uo pipefail (no -e). Individual failures are logged as
# warnings; the script always exits 0 so it never blocks agent startup.

set -uo pipefail

# ── Environment ────────────────────────────────────────────────────────────
APP_DIR="${APP_DIR:-/opt/agent-smith}"
CLAUDE_DIR="${CLAUDE_DIR:-${HOME}/.claude}"

SETTINGS="${APP_DIR}/agents/_shared/settings.json"
INSTALLED="${CLAUDE_DIR}/plugins/installed_plugins.json"

# ── Helpers ────────────────────────────────────────────────────────────────
log() {
  echo "[reconcile] $*"
}

warn() {
  echo "[reconcile] WARN: $*" >&2
}

# ── Start ──────────────────────────────────────────────────────────────────
log "starting (APP_DIR=${APP_DIR} CLAUDE_DIR=${CLAUDE_DIR})"

if [ ! -f "${SETTINGS}" ]; then
  warn "settings not found: ${SETTINGS}"
  log "complete"
  exit 0
fi

# ── Phase 1: marketplace registration ─────────────────────────────────────
# TODO(Task 7): iterate extraKnownMarketplaces and run `claude marketplace add`
# for any marketplace not yet registered.

# ── Phase 2: plugin reconciliation ────────────────────────────────────────
# reconcile_plugin <plugin_id> <declared_version>
#
# declared_version is "" when the enabledPlugins value is plain true (no pin).
# The real implementation (Task 4) will:
#   - "" (no pin): install if missing, skip drift check
#   - non-empty: install if missing; uninstall+reinstall if version drifts
reconcile_plugin() {
  local plugin_id="$1"
  local declared_version="$2"
  # STUB — replaced in Task 4
  :
}

# Iterate declared plugins and call the stub for each.
# For an empty enabledPlugins map, jq emits nothing and the loop runs zero times.
while IFS= read -r plugin_id; do
  declared=$(jq -r ".enabledPlugins.\"${plugin_id}\" | if type == \"object\" then .version else \"\" end" "${SETTINGS}")
  reconcile_plugin "${plugin_id}" "${declared}"
done < <(jq -r '.enabledPlugins | keys[]' "${SETTINGS}")

log "complete"
exit 0
