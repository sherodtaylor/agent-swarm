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
  local declared="$2"

  local installed
  installed=$(jq -r ".plugins.\"${plugin_id}\"[0].version // \"\"" "${INSTALLED}" 2>/dev/null || true)

  # Plain `true` value in enabledPlugins → declared="" → install-if-missing, skip drift check.
  if [ -z "${declared}" ]; then
    if [ -z "${installed}" ]; then
      log "${plugin_id}: not installed (no version pin) → installing latest"
      claude plugin install "${plugin_id}" 2>&1 || warn "${plugin_id}: install failed; continuing"
    else
      log "${plugin_id}: installed at ${installed} (no version pin, skipping drift check)"
    fi
    return 0
  fi

  if [ "${installed}" = "${declared}" ]; then
    log "${plugin_id}: in sync at ${declared}"
    return 0
  fi

  if [ -z "${installed}" ]; then
    log "${plugin_id}: not installed → installing ${declared}"
  else
    log "${plugin_id}: drift ${installed} → ${declared}, reinstalling"
    claude plugin uninstall "${plugin_id}" 2>&1 || true
  fi

  if ! claude plugin install "${plugin_id}" 2>&1; then
    warn "${plugin_id}: install failed; continuing"
    return 0
  fi

  local new_installed
  new_installed=$(jq -r ".plugins.\"${plugin_id}\"[0].version // \"\"" "${INSTALLED}" 2>/dev/null || true)
  if [ "${new_installed}" != "${declared}" ]; then
    warn "${plugin_id}: declared ${declared} but marketplace served ${new_installed:-<none>}"
  fi
}

# Iterate declared plugins and call reconcile_plugin for each.
# For an empty enabledPlugins map, jq emits nothing and the loop runs zero times.
plugin_ids=$(jq -r '.enabledPlugins | keys[]' "${SETTINGS}" 2>/dev/null || true)
for plugin_id in ${plugin_ids}; do
  declared=$(jq -r ".enabledPlugins.\"${plugin_id}\" | if type == \"object\" then .version else \"\" end" "${SETTINGS}" 2>/dev/null || true)
  reconcile_plugin "${plugin_id}" "${declared}"
done

log "complete"
exit 0
