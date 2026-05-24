#!/usr/bin/env bash
# Called by the Stop hook (asyncRewake). Checks open PRs authored by this
# agent for unaddressed review comments. Exits 2 (rewake) if any are found.
set -euo pipefail

pending=""
for repo in sherodtaylor/homelab sherodtaylor/agent-swarm; do
  while IFS=$'\t' read -r num title; do
    count=$(gh pr view "$num" --repo "$repo" --json comments \
      --jq '.comments | length' 2>/dev/null || echo 0)
    [ "$count" -gt 0 ] && pending="${pending} ${repo}#${num}(${count} comment(s))"
  done < <(gh pr list --author "@me" --state open --repo "$repo" \
    --json number,title --jq '.[] | [.number, .title] | @tsv' 2>/dev/null || true)
done

if [ -n "$pending" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"PRs with unaddressed review comments:%s. Use: gh pr view <n> --comments --repo <repo>"}}\n' "$pending"
  exit 2
fi
