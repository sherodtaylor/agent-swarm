# Chart Array of Agents + Persona Decouple + Staged Release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `charts/agent-smith` from one-agent-per-HelmRelease to a values-side `agents: [...]` array; decouple per-agent persona content from the Docker image by mounting it from ConfigMaps (hybrid: chart-bundled defaults + per-agent `configMapRef` override); add per-agent `image.tag` and `configMapRef` overrides for staged canary rolls.

**Architecture:** Templates wrap their resources in `{{- range .Values.agents }}` and emit one StatefulSet / ServiceAccount / ClusterRoleBinding / persona-ConfigMap / Service+Ingress per array entry. A single shared ConfigMap (`agent-smith-shared`) holds cross-cutting persona content. `setup.sh` reads CLAUDE.md from mounted ConfigMap paths instead of `/opt/agent-smith/agents/<name>/`. A backward-compat shim accepts the legacy `agentName: foo` shape and constructs a synthetic one-element array.

**Tech Stack:** Helm v3 chart, Go templating, `Files.Get` for ConfigMap content, bash + `helm` + `grep` for smoke tests, `jq` for diff verification.

**Spec:** `docs/superpowers/specs/2026-05-28-chart-array-config-staged-design.md`

---

## Repo & Working Tree

| Repo | Local path | Branch |
|------|-----------|--------|
| `sherodtaylor/agent-smith` | `/workspace/agent-swarm` | `feat/chart-array-of-agents` (cut off `main` after spec PR #56 merges; OR off `main` directly with the spec branch as a sibling) |

The spec lives on `feat/chart-array-of-agents-spec` (PR #56). This plan + the implementation land on a new `feat/chart-array-of-agents` branch.

---

## File Map

### Chart templates and metadata

| File | Action |
|------|--------|
| `charts/agent-smith/Chart.yaml` | **Modify** — bump `version` to `0.2.0`, update description if needed |
| `charts/agent-smith/values.yaml` | **Modify** — drop per-agent top-level fields (`agentName`, `existingSecret`, `matrix`, `agentRepos`, `primaryRepo`); add `agents: []` default; keep `image`, `persistence`, `resources`, `setup`, `extraEnv`, `reauth`, `ironProxy`, `rbac`, `nodeSelector`, `tolerations`, `affinity` at top level |
| `charts/agent-smith/templates/_helpers.tpl` | **Modify** — add `agent-smith.agentList` (returns either `.Values.agents` or synthetic one-element array from legacy fields); add `agent-smith.agentImageTag <agentEntry>` (returns per-agent override or top-level fallback); add `agent-smith.personaConfigMapName <agentEntry>` (returns `.configMapRef` or chart-rendered name) |
| `charts/agent-smith/templates/statefulset.yaml` | **Modify** — wrap in `{{- range }}`; mount persona ConfigMap at `/etc/agent-smith/persona/` and shared at `/etc/agent-smith/shared/`; add `checksum/persona-<name>` annotation; interpolate per-agent fields |
| `charts/agent-smith/templates/serviceaccount.yaml` | **Modify** — wrap in `{{- range }}` |
| `charts/agent-smith/templates/rbac.yaml` | **Modify** — one ClusterRole at top; N ClusterRoleBindings looped per agent |
| `charts/agent-smith/templates/service-reauth.yaml` | **Modify** — wrap in `{{- range }}`; conditional on top-level `reauth.tunnel.enabled` |
| `charts/agent-smith/templates/ingress-reauth.yaml` | **Modify** — wrap in `{{- range }}`; conditional on top-level `reauth.tunnel.enabled` |
| `charts/agent-smith/templates/configmap-shared.yaml` | **Create** — one ConfigMap with `_shared/CLAUDE.md` from `Files.Get` |
| `charts/agent-smith/templates/configmap-persona.yaml` | **Create** — per-agent ConfigMap; ONLY emit when `.configMapRef` is unset; renders `CLAUDE.md` + `mcp.json` + `subagents/*.md` from bundled `agents/<name>/` files |
| `charts/agent-smith/templates/NOTES.txt` | **Modify** — list agents on success; warn if legacy shape detected |

### Image-side

| File | Action |
|------|--------|
| `scripts/setup.sh` | **Modify** — read CLAUDE.md from `/etc/agent-smith/shared/CLAUDE.md` + `/etc/agent-smith/persona/CLAUDE.md` (was `${APP_DIR}/agents/_shared/CLAUDE.md` + `${AGENT_DIR}/CLAUDE.md`); same for `mcp.json` and `subagents/*.md` lookups |

### Tests + docs

| File | Action |
|------|--------|
| `tests/test-chart-render.sh` | **Create** — bash + helm + grep smoke tests for the rendered templates (10+ cases) |
| `CHANGELOG.md` | **Modify** — entry under `[Unreleased]` |
| `docs/architecture.md` | **Modify** — system overview describes the array-of-agents pattern |
| `docs/runbooks/adding-agent.md` | **Modify** — rewrite for the array shape |
| `docs/runbooks/release.md` | **Modify** — mention per-agent `image.tag` override as the supported canary mechanism |

Estimated diff: ~600 lines added (templates expand, test harness, docs), ~50 removed (legacy single-agent fields from values.yaml). Single PR.

---

## Phase 1 — Branch setup + test harness

### Task 1: Cut branch, install helm, scaffold smoke test

**Files:**
- Create: `/workspace/agent-swarm/tests/test-chart-render.sh`

- [ ] **Step 1: Pull latest, cut branch**

```bash
cd /workspace/agent-swarm
git fetch origin
git checkout main
git pull --ff-only
git checkout -b feat/chart-array-of-agents
```

- [ ] **Step 2: Verify `helm` is on PATH (install if missing)**

```bash
command -v helm 2>&1 && helm version --short || echo "helm not installed"
```

If missing:

```bash
SSL_CERT_FILE=/root/iron-proxy.crt CURL_CA_BUNDLE=/root/iron-proxy.crt \
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
  -o /tmp/get-helm-3.sh
chmod +x /tmp/get-helm-3.sh
SSL_CERT_FILE=/root/iron-proxy.crt CURL_CA_BUNDLE=/root/iron-proxy.crt \
  /tmp/get-helm-3.sh
helm version --short
```

Expected: `v3.x.y+gXXXXXXX` printed.

- [ ] **Step 3: Scaffold `tests/test-chart-render.sh`**

Create `/workspace/agent-swarm/tests/test-chart-render.sh`:

```bash
#!/usr/bin/env bash
# Smoke tests for charts/agent-smith. Each case invokes `helm template`
# with a values fragment and asserts the rendered YAML contains
# (or does not contain) specific strings. No real cluster needed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${REPO_ROOT}/charts/agent-smith"

PASS=0
FAIL=0

assert_eq() {
  local actual="$1"; local expected="$2"; local label="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  local haystack="$1"; local needle="$2"; local label="$3"
  if echo "$haystack" | grep -qE "$needle"; then
    PASS=$((PASS + 1)); echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $label"
    echo "    pattern: $needle"
    echo "    (not found in rendered output)"
  fi
}

assert_not_contains() {
  local haystack="$1"; local needle="$2"; local label="$3"
  if echo "$haystack" | grep -qE "$needle"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $label"
    echo "    pattern: $needle (should NOT be present)"
  else
    PASS=$((PASS + 1)); echo "  PASS: $label"
  fi
}

render() {
  local values_file="$1"
  helm template testrls "${CHART_DIR}" -f "${values_file}" 2>&1
}

render_fails() {
  local values_file="$1"
  if helm template testrls "${CHART_DIR}" -f "${values_file}" >/dev/null 2>&1; then
    echo ""
  else
    helm template testrls "${CHART_DIR}" -f "${values_file}" 2>&1
  fi
}

echo "[test-chart-render] harness loaded"

# Real cases land in Tasks 11 / 12. For now, just verify the harness loads.

echo "[test-chart-render] summary: pass=${PASS} fail=${FAIL}"
exit $FAIL
```

- [ ] **Step 4: Make executable, verify harness runs**

```bash
chmod +x /workspace/agent-swarm/tests/test-chart-render.sh
bash /workspace/agent-swarm/tests/test-chart-render.sh
```

Expected:
```
[test-chart-render] harness loaded
[test-chart-render] summary: pass=0 fail=0
```

Exit code 0.

- [ ] **Step 5: Commit**

```bash
cd /workspace/agent-swarm
git add tests/test-chart-render.sh
git commit -m "test(chart): scaffold helm-template smoke harness

assert_eq / assert_contains / assert_not_contains helpers plus
render() and render_fails() invokers. Tests against a fixed
testrls release name and read values from per-case YAML files.
Cases land in subsequent commits as TDD pairs."
```

---

## Phase 2 — values.yaml schema + agentList helper

### Task 2: Rewrite values.yaml; add `agentList` helper with legacy shim

**Files:**
- Modify: `/workspace/agent-swarm/charts/agent-smith/values.yaml`
- Modify: `/workspace/agent-swarm/charts/agent-smith/templates/_helpers.tpl`
- Modify: `/workspace/agent-swarm/tests/test-chart-render.sh`

- [ ] **Step 1: Read current `values.yaml` and `_helpers.tpl`**

```bash
cat /workspace/agent-swarm/charts/agent-smith/values.yaml
cat /workspace/agent-swarm/charts/agent-smith/templates/_helpers.tpl
```

Take note of: existing top-level fields, existing helper names, the `agent-smith.fullname` convention if present.

- [ ] **Step 2: Write the failing test (helper returns array from `.Values.agents`)**

Replace the placeholder block at the end of `tests/test-chart-render.sh` with:

```bash
echo "[test-chart-render] harness loaded"

# ── Case: new-shape values render with a single agent in the array ──
echo "[case] new-shape single agent renders"
cat > /tmp/values-new-single.yaml <<'EOF'
image:
  repository: ghcr.io/sherodtaylor/agent-smith
  tag: v0.2.0
  pullPolicy: IfNotPresent
existingSecret-placeholder: ""
agents:
  - name: testbot
    existingSecret: testbot-secrets
    matrix:
      botUserId: "@testbot:example.com"
      allowedUsers: "@admin:example.com"
    agentRepos: ["sherodtaylor/homelab"]
    primaryRepo: homelab
EOF
out=$(render /tmp/values-new-single.yaml)
assert_contains "$out" 'name: testbot' "single-agent: StatefulSet/SA name interpolated"

echo "[test-chart-render] summary: pass=${PASS} fail=${FAIL}"
exit $FAIL
```

- [ ] **Step 3: Run; expect failure (templates still use old top-level shape)**

```bash
cd /workspace/agent-swarm
bash tests/test-chart-render.sh
```

Expected: either a Helm error (unknown field `agents`) or render succeeds but produces something OTHER than `name: testbot`. Either way the assertion FAILs.

- [ ] **Step 4: Rewrite `values.yaml`**

Replace the entire `/workspace/agent-swarm/charts/agent-smith/values.yaml` content with:

```yaml
# agent-smith chart values (v0.2.0+)
#
# Declare one entry per agent under `agents`. Each entry is self-contained:
# name, secret reference, matrix bot identity, repos to clone, plus optional
# per-agent overrides for image.tag (canary rolls) and configMapRef (persona
# pinning). All other fields below the array are fleet-wide defaults applied
# to every agent.
#
# Legacy single-agent shape (top-level `agentName: foo` + sibling fields) is
# still accepted during the v0.2.x/v0.3.x deprecation window; see _helpers.tpl
# `agent-smith.agentList`.

agents: []
# Example:
# agents:
#   - name: infrabot
#     existingSecret: infrabot-secrets
#     # Optional per-agent overrides (default to top-level when unset):
#     # configMapRef: infrabot-persona-v3   # mount this CM as persona
#     # image:                              # canary image
#     #   tag: v0.2.1
#     matrix:
#       botUserId: "@infrabot:lab.sherodtaylor.dev"
#       allowedUsers: "@sherod:lab.sherodtaylor.dev,@devbot:..."
#     agentRepos: [sherodtaylor/homelab]
#     primaryRepo: homelab

image:
  repository: ghcr.io/sherodtaylor/agent-smith
  tag: ""              # defaults to Chart.AppVersion when empty
  pullPolicy: IfNotPresent

# iron-proxy egress credential firewall integration. When enabled the pod's
# dnsPolicy points at iron-proxy so HTTPS egress is intercepted and real
# tokens are swapped at the edge.
ironProxy:
  enabled: true
  clusterIp: 10.43.100.100

persistence:
  home:
    enabled: true
    size: 10Gi
    storageClass: ""
    accessMode: ReadWriteOnce
  workspace:
    enabled: true
    size: 20Gi
    storageClass: ""
    accessMode: ReadWriteOnce

resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: "2"
    memory: 4Gi

# Cluster-scoped RBAC. The chart ships read-only defaults safe for the
# infrabot-style observation use case; override for agents that need to
# mutate the cluster.
rbac:
  create: true
  rules:
    - apiGroups: [""]
      resources: ["pods", "services", "configmaps", "events", "namespaces", "nodes"]
      verbs: ["get", "list", "watch"]
    - apiGroups: [""]
      resources: ["pods/log"]
      verbs: ["get", "list"]
    - apiGroups: ["apps"]
      resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
      verbs: ["get", "list", "watch"]
    - apiGroups: ["helm.toolkit.fluxcd.io"]
      resources: ["helmreleases"]
      verbs: ["get", "list", "watch"]
    - apiGroups: ["kustomize.toolkit.fluxcd.io"]
      resources: ["kustomizations"]
      verbs: ["get", "list", "watch"]
    - apiGroups: ["source.toolkit.fluxcd.io"]
      resources: ["gitrepositories", "helmrepositories", "ocirepositories"]
      verbs: ["get", "list", "watch"]

nodeSelector: {}
tolerations: []
affinity: {}

# Optional user-supplied shell command at the end of the init container's
# setup.sh (e.g. dotfiles installer). Best-effort; failure logs a warning.
setup:
  command: ""

# Claude auth self-healing tunnel (ttyd-driven browser terminal).
reauth:
  tunnel:
    enabled: true
    hostSuffix: ".lab.sherodtaylor.dev"
    tlsSecretName: "lab-wildcard-tls"

extraEnv: []
# - name: FOO
#   value: bar
```

- [ ] **Step 5: Add the `agentList` and related helpers to `_helpers.tpl`**

Append to `/workspace/agent-swarm/charts/agent-smith/templates/_helpers.tpl` (preserve existing helpers, just add):

```yaml
{{/*
agent-smith.agentList returns the list of agent entries to render.

Three input shapes:
  - .Values.agents is non-empty       → return it directly (new shape)
  - .Values.agentName is set          → return a one-element synthetic
                                        array constructed from legacy
                                        top-level fields (deprecation shim)
  - both set                          → fail with explanatory error
  - neither set                       → fail with explanatory error

The deprecation shim survives v0.2.x and v0.3.x; removed in v0.4.0.
*/}}
{{- define "agent-smith.agentList" -}}
{{- $hasAgents := and .Values.agents (gt (len .Values.agents) 0) -}}
{{- $hasLegacy := .Values.agentName -}}
{{- if and $hasAgents $hasLegacy -}}
{{- fail "Both .Values.agentName and .Values.agents are set — remove top-level agentName; use agents[] only" -}}
{{- end -}}
{{- if $hasAgents -}}
{{ .Values.agents | toJson }}
{{- else if $hasLegacy -}}
{{- $synth := list (dict
  "name" .Values.agentName
  "existingSecret" (default "" .Values.existingSecret)
  "matrix" (default (dict) .Values.matrix)
  "agentRepos" (default (list) .Values.agentRepos)
  "primaryRepo" (default "" .Values.primaryRepo)
) -}}
{{ $synth | toJson }}
{{- else -}}
{{- fail "Set either .Values.agents (recommended) or .Values.agentName (legacy)" -}}
{{- end -}}
{{- end -}}

{{/*
agent-smith.agentImageTag returns the per-agent image tag override if set,
else falls back to the top-level .Values.image.tag, else Chart.AppVersion.
Pass the agent entry as the only argument.
*/}}
{{- define "agent-smith.agentImageTag" -}}
{{- $agent := . -}}
{{- if and $agent.image $agent.image.tag -}}
{{- $agent.image.tag -}}
{{- else if $.Values.image.tag -}}
{{- $.Values.image.tag -}}
{{- else -}}
{{- $.Chart.AppVersion -}}
{{- end -}}
{{- end -}}

{{/*
agent-smith.personaConfigMapName returns either the operator-supplied
configMapRef from the agent entry OR the chart-rendered default name.
*/}}
{{- define "agent-smith.personaConfigMapName" -}}
{{- $agent := . -}}
{{- if $agent.configMapRef -}}
{{- $agent.configMapRef -}}
{{- else -}}
{{- printf "agent-smith-persona-%s" $agent.name -}}
{{- end -}}
{{- end -}}
```

> Note: the `agentList` helper returns JSON which callers parse via `fromJson` to iterate. This sidesteps a subtle Helm limitation — `define` blocks return strings, not lists. An alternative is using `tpl` with `set-context-in-the-loop` tricks; JSON-serialize-then-fromJson is cleaner and well-tested.

- [ ] **Step 6: Note that StatefulSet etc. aren't yet wrapped in `range`**

The test in Step 2 asserts `name: testbot` appears in the render. The current `statefulset.yaml` still uses `.Values.agentName` (which we just removed from `values.yaml`). The test will FAIL with either an empty render or a template error — Task 3 fixes that.

Run the test again to confirm:

```bash
cd /workspace/agent-swarm
bash tests/test-chart-render.sh 2>&1 | tail -10
```

Expected: FAIL or template error.

- [ ] **Step 7: Commit (intermediate — schema in place, templates not yet wired)**

```bash
cd /workspace/agent-swarm
git add charts/agent-smith/values.yaml \
        charts/agent-smith/templates/_helpers.tpl \
        tests/test-chart-render.sh
git commit -m "feat(chart): introduce agents array schema + agentList helper

values.yaml drops per-agent top-level fields; introduces empty
agents: [] default. _helpers.tpl adds agent-smith.agentList (returns
either .Values.agents or a one-element synthetic array from legacy
agentName; fails when both/neither set), agent-smith.agentImageTag
(per-agent override → top-level → Chart.AppVersion), and
agent-smith.personaConfigMapName (configMapRef → chart default).

Templates not yet rewritten — the failing test in tests/test-chart-render.sh
confirms the new schema isn't honored until Task 3 wraps statefulset.yaml
in a range loop."
```

---

## Phase 3 — Templates fan out (range loops)

### Task 3: Wrap `statefulset.yaml` in `{{- range .Values.agents }}`

**Files:**
- Modify: `/workspace/agent-swarm/charts/agent-smith/templates/statefulset.yaml`
- Modify: `/workspace/agent-swarm/tests/test-chart-render.sh`

- [ ] **Step 1: Read current `statefulset.yaml`**

```bash
cat /workspace/agent-swarm/charts/agent-smith/templates/statefulset.yaml
```

Note: it references `.Values.agentName`, `.Values.existingSecret`, `.Values.matrix.*`, `.Values.agentRepos`, `.Values.primaryRepo`. Those become per-agent fields read from the loop variable.

- [ ] **Step 2: Rewrite the template**

Replace the entire `statefulset.yaml` with:

```yaml
{{- $root := . -}}
{{- $agents := fromJsonArray (include "agent-smith.agentList" .) -}}
{{- range $agent := $agents }}
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ $agent.name }}
  labels:
    {{- include "agent-smith.labels" $root | nindent 4 }}
    app.kubernetes.io/component: agent
    agent-smith.io/agent: {{ $agent.name }}
spec:
  serviceName: {{ $agent.name }}
  replicas: 1
  podManagementPolicy: OrderedReady
  selector:
    matchLabels:
      {{- include "agent-smith.selectorLabels" $root | nindent 6 }}
      agent-smith.io/agent: {{ $agent.name }}
  template:
    metadata:
      labels:
        {{- include "agent-smith.labels" $root | nindent 8 }}
        agent-smith.io/agent: {{ $agent.name }}
      annotations:
        checksum/persona-{{ $agent.name }}: {{ include (print $root.Template.BasePath "/configmap-persona.yaml") $root | sha256sum }}
        checksum/shared: {{ include (print $root.Template.BasePath "/configmap-shared.yaml") $root | sha256sum }}
    spec:
      serviceAccountName: {{ $agent.name }}
      {{- if $root.Values.ironProxy.enabled }}
      dnsPolicy: None
      dnsConfig:
        nameservers:
          - {{ $root.Values.ironProxy.clusterIp | quote }}
        searches:
          - {{ $root.Release.Namespace }}.svc.cluster.local
          - svc.cluster.local
          - cluster.local
      {{- end }}
      initContainers:
        - name: setup
          image: "{{ $root.Values.image.repository }}:{{ include "agent-smith.agentImageTag" (dict "agent" $agent "Values" $root.Values "Chart" $root.Chart) }}"
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          command: ["/opt/agent-smith/scripts/setup.sh"]
          env:
            - name: AGENT_NAME
              value: {{ $agent.name | quote }}
            - name: AGENT_REPOS
              value: {{ join " " $agent.agentRepos | quote }}
            - name: PRIMARY_REPO
              value: {{ $agent.primaryRepo | quote }}
            - name: MATRIX_BOT_USER_ID
              value: {{ $agent.matrix.botUserId | quote }}
            {{- if $agent.matrix.allowedUsers }}
            - name: MATRIX_ALLOWED_USERS
              value: {{ $agent.matrix.allowedUsers | quote }}
            {{- end }}
            {{- with $root.Values.extraEnv }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
            {{- if and $root.Values.setup $root.Values.setup.command }}
            - name: SETUP_COMMAND
              value: {{ $root.Values.setup.command | quote }}
            {{- end }}
          envFrom:
            - secretRef:
                name: {{ $agent.existingSecret }}
          volumeMounts:
            - name: home
              mountPath: /root
            - name: workspace
              mountPath: /workspace
            - name: persona
              mountPath: /etc/agent-smith/persona
              readOnly: true
            - name: shared
              mountPath: /etc/agent-smith/shared
              readOnly: true
      containers:
        - name: agent
          image: "{{ $root.Values.image.repository }}:{{ include "agent-smith.agentImageTag" (dict "agent" $agent "Values" $root.Values "Chart" $root.Chart) }}"
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          tty: true
          stdin: true
          env:
            - name: AGENT_NAME
              value: {{ $agent.name | quote }}
            - name: PRIMARY_REPO
              value: {{ $agent.primaryRepo | quote }}
            {{- if $root.Values.reauth.tunnel.enabled }}
            - name: REAUTH_TUNNEL_HOST
              value: {{ printf "%s-shell%s" $agent.name $root.Values.reauth.tunnel.hostSuffix | quote }}
            {{- end }}
            {{- with $root.Values.extraEnv }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          envFrom:
            - secretRef:
                name: {{ $agent.existingSecret }}
          volumeMounts:
            - name: home
              mountPath: /root
            - name: workspace
              mountPath: /workspace
            - name: persona
              mountPath: /etc/agent-smith/persona
              readOnly: true
            - name: shared
              mountPath: /etc/agent-smith/shared
              readOnly: true
          resources:
            {{- toYaml $root.Values.resources | nindent 12 }}
      volumes:
        - name: persona
          configMap:
            name: {{ include "agent-smith.personaConfigMapName" $agent }}
        - name: shared
          configMap:
            name: agent-smith-shared
      {{- with $root.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
  volumeClaimTemplates:
    {{- if $root.Values.persistence.home.enabled }}
    - metadata:
        name: home
      spec:
        accessModes: [{{ $root.Values.persistence.home.accessMode | quote }}]
        {{- with $root.Values.persistence.home.storageClass }}
        storageClassName: {{ . | quote }}
        {{- end }}
        resources:
          requests:
            storage: {{ $root.Values.persistence.home.size | quote }}
    {{- end }}
    {{- if $root.Values.persistence.workspace.enabled }}
    - metadata:
        name: workspace
      spec:
        accessModes: [{{ $root.Values.persistence.workspace.accessMode | quote }}]
        {{- with $root.Values.persistence.workspace.storageClass }}
        storageClassName: {{ . | quote }}
        {{- end }}
        resources:
          requests:
            storage: {{ $root.Values.persistence.workspace.size | quote }}
    {{- end }}
{{- end }}
```

Key points:
- `{{- $root := . -}}` captures the chart root context before the range loop changes `.`
- `{{- $agents := fromJsonArray (include "agent-smith.agentList" .) -}}` invokes the helper and parses the returned JSON into a Helm list
- Inside the loop, `.` is the agent entry; `$root` is the chart root; explicit `$root.Values.*` references are required because `.Values.*` would resolve against the agent entry
- The `agent-smith.agentImageTag` helper is called with a synthetic context dict `(dict "agent" $agent "Values" $root.Values "Chart" $root.Chart)` because the helper needs both per-agent overrides AND fleet-default fallbacks; it reads from `.agent.image.tag` and `.Values.image.tag`. Adjust the helper in `_helpers.tpl` accordingly:

Update the `agent-smith.agentImageTag` definition in `_helpers.tpl` (replace the one added in Task 2 — the calling convention needs to match):

```yaml
{{- define "agent-smith.agentImageTag" -}}
{{- $ctx := . -}}
{{- if and $ctx.agent.image $ctx.agent.image.tag -}}
{{- $ctx.agent.image.tag -}}
{{- else if $ctx.Values.image.tag -}}
{{- $ctx.Values.image.tag -}}
{{- else -}}
{{- $ctx.Chart.AppVersion -}}
{{- end -}}
{{- end -}}
```

> The earlier Task 2 sketch passed the agent entry directly; the calling site needs more context (Values + Chart), so the helper now takes a dict. Update the helper and the call site together.

- [ ] **Step 3: Run the test (the one from Task 2 Step 2), expect PASS**

```bash
cd /workspace/agent-swarm
bash tests/test-chart-render.sh
```

Expected: PASS for `single-agent: StatefulSet/SA name interpolated`.

If FAIL: read the helm template error. Common issues:
- ConfigMap-related references (`configmap-persona.yaml`, `configmap-shared.yaml`) don't exist yet → helm errors on the include + sha256sum. Workaround for THIS task only: temporarily comment out the `checksum/persona-*` annotation lines; uncomment when Tasks 6-7 create those files. Track as a sub-step:

```bash
# Comment out the two checksum/* annotation lines for now
sed -i '/checksum\/persona/d; /checksum\/shared/d' \
  charts/agent-smith/templates/statefulset.yaml
bash tests/test-chart-render.sh
```

Re-enable them in Task 8.

- [ ] **Step 4: Append second test case (two-agent fan-out)**

Append before the final `echo "[test-chart-render] summary:..."`:

```bash
# ── Case: two agents in array → two StatefulSets, two service accounts ──
echo "[case] two-agent fan-out"
cat > /tmp/values-two-agents.yaml <<'EOF'
image:
  repository: ghcr.io/sherodtaylor/agent-smith
  tag: v0.2.0
agents:
  - name: alpha
    existingSecret: alpha-secrets
    matrix: { botUserId: "@alpha:example.com" }
    agentRepos: [example/repo-a]
    primaryRepo: repo-a
  - name: beta
    existingSecret: beta-secrets
    matrix: { botUserId: "@beta:example.com" }
    agentRepos: [example/repo-b]
    primaryRepo: repo-b
EOF
out=$(render /tmp/values-two-agents.yaml)
sts_count=$(echo "$out" | grep -cE '^kind: StatefulSet' || true)
assert_eq "$sts_count" "2" "two-agent: exactly 2 StatefulSets emitted"
assert_contains "$out" 'name: alpha' "two-agent: alpha StatefulSet present"
assert_contains "$out" 'name: beta'  "two-agent: beta StatefulSet present"
```

Run:

```bash
bash /workspace/agent-swarm/tests/test-chart-render.sh
```

Expected: 4 passes (1 from Task 2 single-agent + 3 new for two-agent fan-out).

- [ ] **Step 5: Commit**

```bash
cd /workspace/agent-swarm
git add charts/agent-smith/templates/statefulset.yaml \
        charts/agent-smith/templates/_helpers.tpl \
        tests/test-chart-render.sh
git commit -m "feat(chart): fan StatefulSet out via range .Values.agents

statefulset.yaml wraps the entire template in {{ range }} over the
agentList helper output; emits one StatefulSet per array entry with
name = {{ \$agent.name }} (preserving PVC identity across the migration
from per-HR-per-agent). Per-agent image.tag override + fleet fallback
goes through agent-smith.agentImageTag helper. Persona + shared
ConfigMap volume mounts are wired in at /etc/agent-smith/{persona,shared}/
— the ConfigMaps themselves land in Tasks 6-7. Tests assert single-agent
+ two-agent fan-out emit the expected resource counts and names."
```

---

### Task 4: `serviceaccount.yaml` + `rbac.yaml` per-agent fan-out

**Files:**
- Modify: `/workspace/agent-swarm/charts/agent-smith/templates/serviceaccount.yaml`
- Modify: `/workspace/agent-swarm/charts/agent-smith/templates/rbac.yaml`
- Modify: `/workspace/agent-swarm/tests/test-chart-render.sh`

- [ ] **Step 1: Read the existing templates**

```bash
cat /workspace/agent-swarm/charts/agent-smith/templates/serviceaccount.yaml
cat /workspace/agent-swarm/charts/agent-smith/templates/rbac.yaml
```

- [ ] **Step 2: Rewrite `serviceaccount.yaml`**

Replace with:

```yaml
{{- $root := . -}}
{{- $agents := fromJsonArray (include "agent-smith.agentList" .) -}}
{{- range $agent := $agents }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $agent.name }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "agent-smith.labels" $root | nindent 4 }}
    agent-smith.io/agent: {{ $agent.name }}
{{- end }}
```

- [ ] **Step 3: Rewrite `rbac.yaml` (one ClusterRole + N ClusterRoleBindings)**

Replace with:

```yaml
{{- if .Values.rbac.create }}
{{- $root := . -}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: agent-smith-base
  labels:
    {{- include "agent-smith.labels" $root | nindent 4 }}
rules:
{{- toYaml $root.Values.rbac.rules | nindent 0 }}
{{- $agents := fromJsonArray (include "agent-smith.agentList" $root) -}}
{{- range $agent := $agents }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: agent-smith-{{ $agent.name }}
  labels:
    {{- include "agent-smith.labels" $root | nindent 4 }}
    agent-smith.io/agent: {{ $agent.name }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: agent-smith-base
subjects:
  - kind: ServiceAccount
    name: {{ $agent.name }}
    namespace: {{ $root.Release.Namespace }}
{{- end }}
{{- end }}
```

- [ ] **Step 4: Append test case (two-agent → 2 SAs, 1 ClusterRole, 2 ClusterRoleBindings)**

```bash
# ── Case: two-agent RBAC fan-out (1 CR, N CRBs, N SAs) ──
echo "[case] two-agent RBAC"
out=$(render /tmp/values-two-agents.yaml)
sa_count=$(echo "$out" | grep -cE '^kind: ServiceAccount' || true)
cr_count=$(echo "$out" | grep -cE '^kind: ClusterRole$' || true)
crb_count=$(echo "$out" | grep -cE '^kind: ClusterRoleBinding' || true)
assert_eq "$sa_count" "2" "RBAC: 2 ServiceAccounts"
assert_eq "$cr_count" "1" "RBAC: 1 shared ClusterRole"
assert_eq "$crb_count" "2" "RBAC: 2 ClusterRoleBindings"
```

Run:

```bash
bash /workspace/agent-swarm/tests/test-chart-render.sh
```

Expected: 7 passes total (3 prior assertions from Task 3 + 3 RBAC + 1 single-agent).

- [ ] **Step 5: Commit**

```bash
cd /workspace/agent-swarm
git add charts/agent-smith/templates/serviceaccount.yaml \
        charts/agent-smith/templates/rbac.yaml \
        tests/test-chart-render.sh
git commit -m "feat(chart): per-agent ServiceAccount + ClusterRoleBinding

serviceaccount.yaml wraps in range over agents. rbac.yaml emits one
shared ClusterRole/agent-smith-base then N ClusterRoleBindings
(named agent-smith-<agent>) binding each per-agent SA to the role.
homelab's rbac.yaml per-agent bindings become obsolete after this
ships."
```

---

### Task 5: `service-reauth.yaml` + `ingress-reauth.yaml` per-agent fan-out

**Files:**
- Modify: `/workspace/agent-swarm/charts/agent-smith/templates/service-reauth.yaml`
- Modify: `/workspace/agent-swarm/charts/agent-smith/templates/ingress-reauth.yaml`
- Modify: `/workspace/agent-swarm/tests/test-chart-render.sh`

- [ ] **Step 1: Read the existing templates**

```bash
cat /workspace/agent-swarm/charts/agent-smith/templates/service-reauth.yaml
cat /workspace/agent-swarm/charts/agent-smith/templates/ingress-reauth.yaml
```

- [ ] **Step 2: Rewrite `service-reauth.yaml`**

Replace with:

```yaml
{{- if .Values.reauth.tunnel.enabled }}
{{- $root := . -}}
{{- $agents := fromJsonArray (include "agent-smith.agentList" .) -}}
{{- range $agent := $agents }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $agent.name }}-shell
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "agent-smith.labels" $root | nindent 4 }}
    agent-smith.io/agent: {{ $agent.name }}
spec:
  type: ClusterIP
  selector:
    {{- include "agent-smith.selectorLabels" $root | nindent 4 }}
    agent-smith.io/agent: {{ $agent.name }}
  ports:
    - name: ttyd
      port: 7681
      targetPort: 7681
      protocol: TCP
{{- end }}
{{- end }}
```

- [ ] **Step 3: Rewrite `ingress-reauth.yaml`**

Replace with:

```yaml
{{- if .Values.reauth.tunnel.enabled }}
{{- $root := . -}}
{{- $agents := fromJsonArray (include "agent-smith.agentList" .) -}}
{{- range $agent := $agents }}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ $agent.name }}-shell
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "agent-smith.labels" $root | nindent 4 }}
    agent-smith.io/agent: {{ $agent.name }}
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  tls:
    - hosts:
        - {{ printf "%s-shell%s" $agent.name $root.Values.reauth.tunnel.hostSuffix }}
      secretName: {{ $root.Values.reauth.tunnel.tlsSecretName }}
  rules:
    - host: {{ printf "%s-shell%s" $agent.name $root.Values.reauth.tunnel.hostSuffix }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ $agent.name }}-shell
                port:
                  number: 7681
{{- end }}
{{- end }}
```

- [ ] **Step 4: Append test case (two-agent reauth fan-out + disabled case)**

```bash
# ── Case: reauth tunnel enabled → per-agent Service + Ingress ──
echo "[case] reauth tunnel fan-out"
out=$(render /tmp/values-two-agents.yaml)
svc_count=$(echo "$out" | grep -cE '^kind: Service$' || true)
ing_count=$(echo "$out" | grep -cE '^kind: Ingress$' || true)
assert_eq "$svc_count" "2" "reauth: 2 Services"
assert_eq "$ing_count" "2" "reauth: 2 Ingresses"
assert_contains "$out" 'alpha-shell' "reauth: alpha hostname"
assert_contains "$out" 'beta-shell'  "reauth: beta hostname"

# ── Case: reauth disabled → no Service/Ingress ──
echo "[case] reauth tunnel disabled"
cat > /tmp/values-reauth-off.yaml <<'EOF'
image: { repository: ghcr.io/sherodtaylor/agent-smith, tag: v0.2.0 }
reauth: { tunnel: { enabled: false } }
agents:
  - name: alpha
    existingSecret: alpha-secrets
    matrix: { botUserId: "@alpha:example.com" }
    agentRepos: [example/repo]
    primaryRepo: repo
EOF
out=$(render /tmp/values-reauth-off.yaml)
svc_count=$(echo "$out" | grep -cE '^kind: Service$' || true)
ing_count=$(echo "$out" | grep -cE '^kind: Ingress$' || true)
assert_eq "$svc_count" "0" "reauth off: no Services"
assert_eq "$ing_count" "0" "reauth off: no Ingresses"
```

Run:

```bash
bash /workspace/agent-swarm/tests/test-chart-render.sh
```

Expected: 13 passes.

- [ ] **Step 5: Commit**

```bash
cd /workspace/agent-swarm
git add charts/agent-smith/templates/service-reauth.yaml \
        charts/agent-smith/templates/ingress-reauth.yaml \
        tests/test-chart-render.sh
git commit -m "feat(chart): per-agent reauth Service + Ingress

Both templates wrap in {{ range agents }}; hostname pattern is
{{ \$agent.name }}-shell{{ .reauth.tunnel.hostSuffix }}. The
top-level reauth.tunnel.enabled toggle is still fleet-wide; per-agent
enable/disable is explicitly out of scope per the spec. Tests cover
both enabled (2 agents → 2 Services + 2 Ingresses) and disabled
(0 of each) configurations."
```

---

## Phase 4 — Persona ConfigMaps + mount

### Task 6: Shared ConfigMap (`configmap-shared.yaml`)

**Files:**
- Create: `/workspace/agent-swarm/charts/agent-smith/templates/configmap-shared.yaml`
- Modify: `/workspace/agent-swarm/tests/test-chart-render.sh`

- [ ] **Step 1: Create the template**

Create `/workspace/agent-swarm/charts/agent-smith/templates/configmap-shared.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: agent-smith-shared
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "agent-smith.labels" . | nindent 4 }}
data:
  CLAUDE.md: |
{{ .Files.Get "agents/_shared/CLAUDE.md" | indent 4 }}
```

This depends on the chart's source tree containing `charts/agent-smith/agents/_shared/CLAUDE.md`. Verify it exists:

```bash
ls /workspace/agent-swarm/charts/agent-smith/agents/_shared/CLAUDE.md 2>&1 | head -1
```

If absent: create a symlink or copy the agent-smith repo's top-level `agents/_shared/CLAUDE.md` to that path so `Files.Get` resolves. Helm only sees files INSIDE the chart directory.

```bash
mkdir -p /workspace/agent-swarm/charts/agent-smith/agents/_shared
cp /workspace/agent-swarm/agents/_shared/CLAUDE.md \
   /workspace/agent-swarm/charts/agent-smith/agents/_shared/CLAUDE.md
```

(Spec B will resolve the persona-file location convention; for now, copy is the right answer.)

- [ ] **Step 2: Append test case (shared ConfigMap rendered, has expected content)**

```bash
# ── Case: shared ConfigMap is rendered with CLAUDE.md content ──
echo "[case] shared ConfigMap"
out=$(render /tmp/values-two-agents.yaml)
shared_cm_count=$(echo "$out" | grep -cE 'name: agent-smith-shared$' || true)
assert_eq "$shared_cm_count" "1" "shared CM: exactly 1 instance (not per agent)"
assert_contains "$out" 'kind: ConfigMap' "shared CM: kind ConfigMap present"
```

- [ ] **Step 3: Run, expect pass**

```bash
bash /workspace/agent-swarm/tests/test-chart-render.sh
```

Expected: 15 passes.

- [ ] **Step 4: Commit**

```bash
cd /workspace/agent-swarm
git add charts/agent-smith/templates/configmap-shared.yaml \
        charts/agent-smith/agents/_shared/CLAUDE.md \
        tests/test-chart-render.sh
git commit -m "feat(chart): shared ConfigMap with _shared/CLAUDE.md

One ConfigMap (agent-smith-shared) emitted regardless of agent count.
Contains the cross-cutting CLAUDE.md from agents/_shared/ via
Files.Get. Mounted at /etc/agent-smith/shared/ in every init
container; setup.sh will concatenate with the per-agent persona.

Persona source files live inside the chart dir
(charts/agent-smith/agents/) so Helm's Files.Get can resolve them.
Copied from the repo's top-level agents/_shared/ for now; Spec B
will formalize the chart-bundled persona content convention."
```

---

### Task 7: Per-agent persona ConfigMap (`configmap-persona.yaml`)

**Files:**
- Create: `/workspace/agent-swarm/charts/agent-smith/templates/configmap-persona.yaml`
- Modify: `/workspace/agent-swarm/tests/test-chart-render.sh`

- [ ] **Step 1: Create the template**

Create `/workspace/agent-swarm/charts/agent-smith/templates/configmap-persona.yaml`:

```yaml
{{- $root := . -}}
{{- $agents := fromJsonArray (include "agent-smith.agentList" .) -}}
{{- range $agent := $agents }}
{{- /*
  Only emit a chart-rendered ConfigMap when configMapRef is unset.
  When configMapRef IS set, the operator is supplying their own
  ConfigMap by name; the chart just mounts it.
*/ -}}
{{- if not $agent.configMapRef }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: agent-smith-persona-{{ $agent.name }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "agent-smith.labels" $root | nindent 4 }}
    agent-smith.io/agent: {{ $agent.name }}
data:
{{- $personaDir := printf "agents/%s" $agent.name }}
{{- $claudeMdPath := printf "%s/CLAUDE.md" $personaDir }}
{{- $mcpJsonPath := printf "%s/mcp.json" $personaDir }}
{{- if $root.Files.Get $claudeMdPath }}
  CLAUDE.md: |
{{ $root.Files.Get $claudeMdPath | indent 4 }}
{{- else }}
  CLAUDE.md: |
    # {{ $agent.name }}
    (No persona content bundled for this agent. Set configMapRef to point at
    an operator-supplied ConfigMap with CLAUDE.md + mcp.json, or land
    persona files at charts/agent-smith/agents/{{ $agent.name }}/ in the
    chart source.)
{{- end }}
{{- if $root.Files.Get $mcpJsonPath }}
  mcp.json: |
{{ $root.Files.Get $mcpJsonPath | indent 4 }}
{{- else }}
  mcp.json: |
    { "mcpServers": {} }
{{- end }}
{{- end }}
{{- end }}
```

The template handles three cases:
- `configMapRef` set → emit nothing for this agent (operator-supplied)
- `configMapRef` unset, persona files present at `charts/agent-smith/agents/<name>/` → emit ConfigMap with the real content
- `configMapRef` unset, no persona files (e.g. a brand-new agent name) → emit ConfigMap with stub content + a helpful comment

- [ ] **Step 2: Copy the existing per-agent persona files into the chart dir**

```bash
mkdir -p /workspace/agent-swarm/charts/agent-smith/agents/infrabot \
         /workspace/agent-swarm/charts/agent-smith/agents/devbot
cp /workspace/agent-swarm/agents/infrabot/CLAUDE.md \
   /workspace/agent-swarm/charts/agent-smith/agents/infrabot/
cp /workspace/agent-swarm/agents/devbot/CLAUDE.md \
   /workspace/agent-swarm/charts/agent-smith/agents/devbot/
cp /workspace/agent-swarm/agents/infrabot/mcp.json \
   /workspace/agent-swarm/charts/agent-smith/agents/infrabot/ 2>/dev/null || true
cp /workspace/agent-swarm/agents/devbot/mcp.json \
   /workspace/agent-swarm/charts/agent-smith/agents/devbot/ 2>/dev/null || true
```

- [ ] **Step 3: Append test cases**

```bash
# ── Case: persona ConfigMap rendered per agent (no configMapRef) ──
echo "[case] persona ConfigMap chart-rendered"
out=$(render /tmp/values-two-agents.yaml)
persona_alpha=$(echo "$out" | grep -cE 'name: agent-smith-persona-alpha$' || true)
persona_beta=$(echo "$out" | grep -cE 'name: agent-smith-persona-beta$' || true)
assert_eq "$persona_alpha" "1" "persona CM: alpha rendered"
assert_eq "$persona_beta" "1" "persona CM: beta rendered"

# ── Case: configMapRef provided → no chart-rendered persona CM ──
echo "[case] configMapRef override skips chart-rendered CM"
cat > /tmp/values-configmapref.yaml <<'EOF'
image: { repository: ghcr.io/sherodtaylor/agent-smith, tag: v0.2.0 }
agents:
  - name: alpha
    existingSecret: alpha-secrets
    configMapRef: alpha-persona-v3
    matrix: { botUserId: "@alpha:example.com" }
    agentRepos: [example/repo]
    primaryRepo: repo
EOF
out=$(render /tmp/values-configmapref.yaml)
persona_alpha=$(echo "$out" | grep -cE 'name: agent-smith-persona-alpha$' || true)
mount_alpha=$(echo "$out" | grep -cE 'name: alpha-persona-v3' || true)
assert_eq "$persona_alpha" "0" "configMapRef: chart-rendered persona CM skipped"
assert_contains "$out" 'name: alpha-persona-v3' "configMapRef: mount references operator-supplied name"
```

- [ ] **Step 4: Run, expect pass**

```bash
bash /workspace/agent-swarm/tests/test-chart-render.sh
```

Expected: 19 passes.

- [ ] **Step 5: Commit**

```bash
cd /workspace/agent-swarm
git add charts/agent-smith/templates/configmap-persona.yaml \
        charts/agent-smith/agents/infrabot \
        charts/agent-smith/agents/devbot \
        tests/test-chart-render.sh
git commit -m "feat(chart): per-agent persona ConfigMap (chart-rendered or override)

configmap-persona.yaml ranges over agents; emits agent-smith-persona-<name>
ConfigMap when configMapRef is unset. Content sourced from
charts/agent-smith/agents/<name>/{CLAUDE.md,mcp.json} via Files.Get
(stub content with a helpful comment when files absent). When
configMapRef IS set, the chart emits nothing (operator owns the CM)
and the StatefulSet's volume.configMap.name references the operator-
supplied name via agent-smith.personaConfigMapName helper. Tests
cover both paths."
```

---

### Task 8: Re-enable checksum annotations in StatefulSet

**Files:**
- Modify: `/workspace/agent-swarm/charts/agent-smith/templates/statefulset.yaml`
- Modify: `/workspace/agent-swarm/tests/test-chart-render.sh`

If you commented out the `checksum/persona-*` and `checksum/shared` annotation lines in Task 3 Step 3, this task re-enables them now that the ConfigMaps exist.

- [ ] **Step 1: Restore the annotations in `statefulset.yaml`**

Locate the `annotations:` block on the StatefulSet pod template (under `spec.template.metadata`). Replace it with:

```yaml
      annotations:
        checksum/persona-{{ $agent.name }}: {{ include (print $root.Template.BasePath "/configmap-persona.yaml") $root | sha256sum }}
        checksum/shared: {{ include (print $root.Template.BasePath "/configmap-shared.yaml") $root | sha256sum }}
```

> The `include` returns the rendered template; `sha256sum` produces a stable digest. When persona content changes, the digest changes, the pod template hash changes, and Helm triggers a rolling restart.

- [ ] **Step 2: Append test (checksum annotation present)**

```bash
# ── Case: persona/shared checksum annotations present ──
echo "[case] checksum annotations"
out=$(render /tmp/values-two-agents.yaml)
assert_contains "$out" 'checksum/persona-alpha:' "checksum: alpha persona annotation"
assert_contains "$out" 'checksum/persona-beta:'  "checksum: beta persona annotation"
assert_contains "$out" 'checksum/shared:'         "checksum: shared annotation"
```

- [ ] **Step 3: Run, expect pass**

```bash
bash /workspace/agent-swarm/tests/test-chart-render.sh
```

Expected: 22 passes.

- [ ] **Step 4: Commit**

```bash
cd /workspace/agent-swarm
git add charts/agent-smith/templates/statefulset.yaml \
        tests/test-chart-render.sh
git commit -m "feat(chart): persona/shared checksum annotations on pod template

checksum/persona-<name> and checksum/shared annotations capture
sha256sum of the rendered ConfigMap templates. Persona edits change
the digest → pod template hash changes → Helm triggers a rolling
restart on the next reconcile. Standard Helm pattern for
ConfigMap-driven content rotation."
```

---

### Task 9: `setup.sh` reads persona from mount paths

**Files:**
- Modify: `/workspace/agent-swarm/scripts/setup.sh`

- [ ] **Step 1: Read the current persona assembly block in setup.sh**

```bash
grep -n -B1 -A10 'CLAUDE.md\|AGENT_DIR.*CLAUDE\|_shared' /workspace/agent-swarm/scripts/setup.sh | head -40
```

Identify the existing concat: `cat ${APP_DIR}/agents/_shared/CLAUDE.md ${AGENT_DIR}/CLAUDE.md > ${CLAUDE_DIR}/CLAUDE.md`.

- [ ] **Step 2: Update setup.sh to read from the mount paths**

Find the existing concat line in `scripts/setup.sh`:

```bash
# CLAUDE.md = shared base + agent persona
cat "${APP_DIR}/agents/_shared/CLAUDE.md" "${AGENT_DIR}/CLAUDE.md" \
  > "${CLAUDE_DIR}/CLAUDE.md"
```

Replace with:

```bash
# CLAUDE.md = shared base + agent persona.
# Mounted ConfigMaps are the source of truth in v0.2.0+:
#   /etc/agent-smith/shared/CLAUDE.md  (one shared CM, chart-mounted)
#   /etc/agent-smith/persona/CLAUDE.md (per-agent CM, chart-mounted)
# Legacy fallback: ${APP_DIR}/agents/<name>/CLAUDE.md (baked into image).
# The mount paths win when present; fallback kicks in only when an
# older chart version (v0.1.x) deploys without the volume mounts.
_SHARED_CLAUDE_MD="/etc/agent-smith/shared/CLAUDE.md"
_PERSONA_CLAUDE_MD="/etc/agent-smith/persona/CLAUDE.md"
if [ -f "${_SHARED_CLAUDE_MD}" ] && [ -f "${_PERSONA_CLAUDE_MD}" ]; then
  cat "${_SHARED_CLAUDE_MD}" "${_PERSONA_CLAUDE_MD}" > "${CLAUDE_DIR}/CLAUDE.md"
  echo "[setup] CLAUDE.md assembled from mounted ConfigMaps"
else
  cat "${APP_DIR}/agents/_shared/CLAUDE.md" "${AGENT_DIR}/CLAUDE.md" \
    > "${CLAUDE_DIR}/CLAUDE.md"
  echo "[setup] CLAUDE.md assembled from baked-in image files (legacy fallback)"
fi
```

Similarly for `mcp.json` — find the existing line:

```bash
# MCP servers (user scope, applies regardless of cwd)
cp "${AGENT_DIR}/mcp.json" "${CLAUDE_DIR}/.mcp.json"
```

Replace with:

```bash
# MCP servers (user scope). Mounted persona ConfigMap wins; fallback to
# baked-in image file.
_PERSONA_MCP_JSON="/etc/agent-smith/persona/mcp.json"
if [ -f "${_PERSONA_MCP_JSON}" ]; then
  cp "${_PERSONA_MCP_JSON}" "${CLAUDE_DIR}/.mcp.json"
else
  cp "${AGENT_DIR}/mcp.json" "${CLAUDE_DIR}/.mcp.json"
fi
```

Leave the subagents copy block (`cp "${AGENT_DIR}/subagents/"*.md ...`) alone for now — chart-bundled subagents are a refinement; the legacy baked-in copy keeps working in v0.2.0.

- [ ] **Step 3: Syntax check**

```bash
bash -n /workspace/agent-swarm/scripts/setup.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 4: Commit**

```bash
cd /workspace/agent-swarm
git add scripts/setup.sh
git commit -m "feat(setup): read persona from mounted ConfigMaps when present

setup.sh now reads CLAUDE.md from /etc/agent-smith/shared/ +
/etc/agent-smith/persona/ (chart-mounted ConfigMaps) when both
files exist; falls back to the baked-in /opt/agent-smith/agents/
paths when not (handles older chart versions that don't mount the
volumes). Same fallback pattern for mcp.json. Subagents copy is
unchanged (baked-in path) — chart-bundled subagents are a Spec B
refinement."
```

---

## Phase 5 — Legacy shape shim verification

### Task 10: Test legacy `agentName: foo` shape + both-set error

**Files:**
- Modify: `/workspace/agent-swarm/tests/test-chart-render.sh`

The shim was implemented in Task 2. This task adds the failing-case tests to prove the contract.

- [ ] **Step 1: Append test cases**

```bash
# ── Case: legacy agentName shape still renders (deprecation shim) ──
echo "[case] legacy agentName shape"
cat > /tmp/values-legacy.yaml <<'EOF'
image: { repository: ghcr.io/sherodtaylor/agent-smith, tag: v0.2.0 }
agentName: legacybot
existingSecret: legacybot-secrets
matrix: { botUserId: "@legacybot:example.com" }
agentRepos: [example/repo]
primaryRepo: repo
EOF
out=$(render /tmp/values-legacy.yaml)
sts_count=$(echo "$out" | grep -cE '^kind: StatefulSet' || true)
assert_eq "$sts_count" "1" "legacy: one StatefulSet from synthetic array"
assert_contains "$out" 'name: legacybot' "legacy: agentName interpolated into StatefulSet"

# ── Case: both agents AND agentName set → render fails ──
echo "[case] both shapes set → error"
cat > /tmp/values-both.yaml <<'EOF'
image: { repository: ghcr.io/sherodtaylor/agent-smith, tag: v0.2.0 }
agentName: oops
existingSecret: oops-secrets
matrix: { botUserId: "@oops:example.com" }
agentRepos: [example/repo]
primaryRepo: repo
agents:
  - name: also-oops
    existingSecret: also-oops-secrets
    matrix: { botUserId: "@also-oops:example.com" }
    agentRepos: [example/repo]
    primaryRepo: repo
EOF
err=$(render_fails /tmp/values-both.yaml)
assert_contains "$err" 'Both .Values.agentName and .Values.agents are set' "both-shape error: explanatory message"

# ── Case: neither agents nor agentName set → render fails ──
echo "[case] neither shape set → error"
cat > /tmp/values-empty.yaml <<'EOF'
image: { repository: ghcr.io/sherodtaylor/agent-smith, tag: v0.2.0 }
agents: []
EOF
err=$(render_fails /tmp/values-empty.yaml)
assert_contains "$err" 'Set either .Values.agents .* or .Values.agentName' "empty: explanatory error"
```

- [ ] **Step 2: Run, expect pass**

```bash
bash /workspace/agent-swarm/tests/test-chart-render.sh
```

Expected: 26 passes.

- [ ] **Step 3: Commit**

```bash
cd /workspace/agent-swarm
git add tests/test-chart-render.sh
git commit -m "test(chart): legacy agentName shim + both-set + empty error cases

Three cases pin the deprecation-shim contract:
- agentName: foo (single legacy field) → renders one StatefulSet from
  the synthetic array constructed by agentList helper
- both .Values.agents and .Values.agentName set → render fails with
  the explanatory \"Both ... are set\" message
- neither set → render fails with \"Set either .Values.agents ... or
  .Values.agentName\"

Shim itself was implemented in Task 2; these tests pin the behavior
against regression."
```

---

## Phase 6 — Smoke tests for staging knobs

### Task 11: Per-agent `image.tag` + `configMapRef` override smoke tests

**Files:**
- Modify: `/workspace/agent-swarm/tests/test-chart-render.sh`

- [ ] **Step 1: Append test cases**

```bash
# ── Case: per-agent image.tag override + fleet-default fallback ──
echo "[case] per-agent image.tag override"
cat > /tmp/values-tag-override.yaml <<'EOF'
image:
  repository: ghcr.io/sherodtaylor/agent-smith
  tag: v0.2.0
agents:
  - name: alpha
    existingSecret: alpha-secrets
    image: { tag: v0.2.1 }     # canary override
    matrix: { botUserId: "@alpha:example.com" }
    agentRepos: [example/repo]
    primaryRepo: repo
  - name: beta
    existingSecret: beta-secrets
    # no image override → uses top-level tag v0.2.0
    matrix: { botUserId: "@beta:example.com" }
    agentRepos: [example/repo]
    primaryRepo: repo
EOF
out=$(render /tmp/values-tag-override.yaml)
# alpha StatefulSet uses v0.2.1; beta uses v0.2.0
alpha_tag_021=$(echo "$out" | awk '/name: alpha$/,/name: beta$/' | grep -c 'image: "ghcr.io/sherodtaylor/agent-smith:v0.2.1"' || true)
beta_tag_020=$(echo "$out" | awk '/name: beta$/,0' | grep -c 'image: "ghcr.io/sherodtaylor/agent-smith:v0.2.0"' || true)
[ "$alpha_tag_021" -ge 1 ] && \
  { PASS=$((PASS + 1)); echo "  PASS: image override: alpha uses v0.2.1"; } || \
  { FAIL=$((FAIL + 1)); echo "  FAIL: image override: alpha not on v0.2.1"; }
[ "$beta_tag_020" -ge 1 ] && \
  { PASS=$((PASS + 1)); echo "  PASS: image override: beta uses top-level v0.2.0"; } || \
  { FAIL=$((FAIL + 1)); echo "  FAIL: image override: beta not on v0.2.0"; }

# ── Case: per-agent configMapRef override + chart-rendered default ──
echo "[case] mixed configMapRef + default"
cat > /tmp/values-mixed-cm.yaml <<'EOF'
image: { repository: ghcr.io/sherodtaylor/agent-smith, tag: v0.2.0 }
agents:
  - name: alpha
    existingSecret: alpha-secrets
    configMapRef: alpha-custom-cm   # operator-supplied
    matrix: { botUserId: "@alpha:example.com" }
    agentRepos: [example/repo]
    primaryRepo: repo
  - name: beta
    existingSecret: beta-secrets
    # no configMapRef → chart renders agent-smith-persona-beta
    matrix: { botUserId: "@beta:example.com" }
    agentRepos: [example/repo]
    primaryRepo: repo
EOF
out=$(render /tmp/values-mixed-cm.yaml)
chart_persona_alpha=$(echo "$out" | grep -cE 'name: agent-smith-persona-alpha$' || true)
chart_persona_beta=$(echo "$out" | grep -cE 'name: agent-smith-persona-beta$' || true)
mount_alpha=$(echo "$out" | grep -cE 'name: alpha-custom-cm$' || true)
assert_eq "$chart_persona_alpha" "0" "mixed: alpha gets no chart-rendered CM (override)"
assert_eq "$chart_persona_beta" "1" "mixed: beta gets chart-rendered CM"
assert_contains "$out" 'name: alpha-custom-cm' "mixed: alpha StatefulSet mounts alpha-custom-cm"
```

- [ ] **Step 2: Run, expect pass**

```bash
bash /workspace/agent-swarm/tests/test-chart-render.sh
```

Expected: 31 passes.

- [ ] **Step 3: Commit**

```bash
cd /workspace/agent-swarm
git add tests/test-chart-render.sh
git commit -m "test(chart): per-agent image.tag + configMapRef override smoke

Two cases pin the staging knobs:
- image.tag override: alpha gets per-agent v0.2.1, beta inherits
  top-level v0.2.0 (canary roll mechanism)
- configMapRef override: alpha gets no chart-rendered persona CM
  (operator supplies alpha-custom-cm), beta gets chart-rendered
  agent-smith-persona-beta (default)

These tests prove the spec's staging-knob mechanism works at the
template level."
```

---

## Phase 7 — Docs (no drift)

### Task 12: CHANGELOG entry + Chart.yaml version bump

**Files:**
- Modify: `/workspace/agent-swarm/charts/agent-smith/Chart.yaml`
- Modify: `/workspace/agent-swarm/CHANGELOG.md`

- [ ] **Step 1: Bump Chart.yaml version to 0.2.0**

```bash
grep -n '^version:' /workspace/agent-swarm/charts/agent-smith/Chart.yaml
```

Edit the `version:` field to `0.2.0` (minor bump — breaking with shim).

- [ ] **Step 2: Add CHANGELOG entry under `[Unreleased]`**

Insert after the `## [Unreleased]` header:

```markdown
## [Unreleased]

### Added

- **Chart `agents: [...]` array shape** — one HelmRelease can now
  deploy N agents from a values-side array. Replaces the prior
  one-HelmRelease-per-agent model.
- **Per-agent persona via mounted ConfigMaps** — `CLAUDE.md` + `mcp.json`
  no longer need to be baked into the image. Hybrid sourcing: chart
  renders a default ConfigMap from `charts/agent-smith/agents/<name>/`
  bundled content; agents set `configMapRef: <name>` to override with
  an operator-supplied ConfigMap. Persona iteration drops from ~5-10min
  (image rebuild) to ~90s (ConfigMap edit + pod restart).
- **Per-agent staging knobs** — each agent entry accepts an optional
  `image.tag` (defaults to fleet-wide `.image.tag`) and `configMapRef`
  (defaults to chart-rendered persona CM). Canary one agent without
  splitting the fleet across HelmReleases.
- **`tests/test-chart-render.sh`** — bash + helm + grep smoke harness
  covering single-agent, two-agent fan-out, RBAC fan-out, reauth
  on/off, persona CM rendering, configMapRef override, legacy shim,
  both-set error, neither-set error, and per-agent staging knobs.

### Changed

- **`charts/agent-smith/values.yaml`** — top-level `agentName`,
  `existingSecret`, `matrix`, `agentRepos`, `primaryRepo` removed.
  Per-agent equivalents move into `agents[].*`.
- **`scripts/setup.sh`** — reads CLAUDE.md from `/etc/agent-smith/{shared,persona}/`
  mount paths when present; falls back to the baked-in
  `/opt/agent-smith/agents/<name>/` paths for older chart versions.
- **Chart version** — `0.2.0` (minor; the deprecation shim keeps
  legacy `agentName:` consumers working).

### Deprecated

- **Top-level single-agent shape** (`agentName: foo` + sibling fields).
  The chart accepts it during v0.2.x and v0.3.x via a synthetic
  one-element array constructed by `agent-smith.agentList`. Removed
  in v0.4.0. Migrate to the `agents: [{name: foo, ...}]` shape.

### Migration

- Chart consumers (homelab) get a follow-up PR migrating from
  one-HelmRelease-per-agent to a single fleet HelmRelease with the
  agents array. PVC identity is preserved (StatefulSet name stays as
  `<agent-name>`), so no data migration is needed.
```

- [ ] **Step 3: Commit**

```bash
cd /workspace/agent-swarm
git add charts/agent-smith/Chart.yaml CHANGELOG.md
git commit -m "docs(changelog): describe v0.2.0 chart refactor

Bumps Chart.yaml version to 0.2.0 (minor — breaking with shim).
CHANGELOG entry covers: agents array, persona ConfigMap mount,
per-agent staging knobs, test harness, value-shape changes,
deprecation of agentName, migration path with PVC preservation."
```

---

### Task 13: Update `docs/architecture.md`

**Files:**
- Modify: `/workspace/agent-swarm/docs/architecture.md`

- [ ] **Step 1: Read current architecture doc**

```bash
grep -n '^#\|^## \|^### ' /workspace/agent-swarm/docs/architecture.md | head -40
```

Find the section that describes the chart / StatefulSet / per-agent topology.

- [ ] **Step 2: Edit the chart-topology section**

Whatever section describes "one chart per agent" or shows the StatefulSet/SA/CRB structure — rewrite to describe the array model:

Add (or replace) a sub-section like:

```markdown
## Agent fleet topology (v0.2.0+)

A single Helm release of `agent-smith` deploys N agents from a
values-side `agents: [...]` array. Chart templates fan out per agent:

- `StatefulSet/<agent-name>` (one replica, two PVCs: `home-<agent>-0`
  + `workspace-<agent>-0`)
- `ServiceAccount/<agent-name>`
- `ClusterRoleBinding/agent-smith-<agent-name>` → shared `ClusterRole/agent-smith-base`
- `ConfigMap/agent-smith-persona-<agent-name>` (chart-rendered from
  `agents/<name>/` files; skipped when `configMapRef` overrides)
- `Service/<agent-name>-shell` + `Ingress/<agent-name>-shell` (when
  `reauth.tunnel.enabled`)

One-instance resources:

- `ConfigMap/agent-smith-shared` — contains `_shared/CLAUDE.md`
  cross-cutting content; mounted by every agent's init container

Per-agent staging knobs:

- `agents[i].image.tag` — overrides fleet-wide `image.tag` for canary
  rolls. Drop the override after promotion.
- `agents[i].configMapRef` — points at an operator-supplied persona
  ConfigMap instead of the chart-rendered default. Use for persona
  A/B tests or staged content rollouts.
```

- [ ] **Step 3: Commit**

```bash
cd /workspace/agent-swarm
git add docs/architecture.md
git commit -m "docs(architecture): describe v0.2.0 agents-array fleet topology

Replaces or augments the prior per-HelmRelease-per-agent diagram with
the array model. Documents what the chart fans out per agent
(StatefulSet, SA, CRB, persona CM, Service+Ingress) and what's
shared (ClusterRole, shared CM). Calls out the per-agent staging
knobs (image.tag override, configMapRef override)."
```

---

### Task 14: Rewrite `docs/runbooks/adding-agent.md`

**Files:**
- Modify: `/workspace/agent-swarm/docs/runbooks/adding-agent.md`

- [ ] **Step 1: Read current runbook**

```bash
cat /workspace/agent-swarm/docs/runbooks/adding-agent.md
```

- [ ] **Step 2: Rewrite for the array shape**

Replace the content with:

```markdown
# Runbook: Add a new agent

Use this runbook when adding a brand-new agent to the fleet (a third
agent alongside infrabot + devbot, for example).

## Preconditions

- Agent has a Matrix account and access token; you have the bot's full
  user ID (e.g. `@cobot:lab.sherodtaylor.dev`).
- Decide which repos the agent should clone at startup (`agentRepos`).

## Steps

### 1. Provision the agent's secret in Infisical

In the Infisical UI, under workspace `k3` env `prod`, add the keys the
agent needs at runtime — at minimum:

- `MATRIX_ACCESS_TOKEN`
- `GITHUB_TOKEN` (the iron-proxy placeholder)
- `IRON_PROXY_CA_CRT`
- Any OAuth tokens (`CLAUDE_ACCESS_TOKEN`, `CLAUDE_REFRESH_TOKEN`,
  `CLAUDE_EXPIRES_AT`) if the agent will use Claude
- Project-specific tokens (e.g. `GIT_GITHUB_TOKEN`, others)

### 2. Add an ExternalSecret in homelab

Create `k8s/apps/agents/externalsecret-<agent>.yaml` modeled on the
existing `externalsecret-infrabot.yaml`. The output Secret name
becomes `<agent>-secrets`.

Add a reference to the new file in `k8s/apps/agents/kustomization.yaml`.

### 3. Author the agent's persona

Two options:

**Option A (chart-bundled, the public path):** Add a directory to the
agent-smith repo:

```
charts/agent-smith/agents/<agent-name>/
├── CLAUDE.md      # the agent's persona
└── mcp.json       # MCP server config
```

Open a PR against agent-smith; once merged + a new chart version is
cut (chart version bump), the new agent's persona is bundled.

**Option B (operator-supplied ConfigMap):** Create
`k8s/apps/agents/<agent>-persona-configmap.yaml` in homelab:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <agent>-persona
  namespace: agents
data:
  CLAUDE.md: |
    # MyAgent
    ...persona text...
  mcp.json: |
    { "mcpServers": { ... } }
```

Add it to the Kustomize bundle. Reference via `configMapRef: <agent>-persona`
in the next step.

### 4. Add the agent to the fleet HelmRelease

Edit `k8s/apps/agents/agent-smith-fleet-helmrelease.yaml`, append to
`spec.values.agents`:

```yaml
- name: <agent-name>
  existingSecret: <agent>-secrets
  # Option B only:
  # configMapRef: <agent>-persona
  matrix:
    botUserId: "@<agent>:lab.sherodtaylor.dev"
    allowedUsers: "@sherod:lab.sherodtaylor.dev,@infrabot:...,@devbot:..."
  agentRepos: ["sherodtaylor/homelab"]
  primaryRepo: homelab
```

### 5. Open a PR, merge, watch Flux

Open one PR with the ExternalSecret + (if Option B) ConfigMap + the
HelmRelease edit. Merge. Flux reconciles. A new pod
`<agent>-0` comes up; tail its setup logs:

```bash
kubectl logs -n agents <agent>-0 -c setup --tail=100
```

Look for `[setup] complete` near the end. If you see `[setup] FATAL`,
fix and re-roll.

### 6. Verify in Matrix

Tag the agent in `#dev` or `#infra`; it should respond per its persona.

## Staging the rollout

To bring up the new agent on a different chart or image version than
the rest of the fleet (canary), set `image.tag` on the agent entry:

```yaml
- name: <agent-name>
  existingSecret: <agent>-secrets
  image: { tag: v0.2.1 }   # canary
  matrix: { ... }
```

Drop the override after the agent proves out; the fleet-wide
`.image.tag` then applies.
```

- [ ] **Step 3: Commit**

```bash
cd /workspace/agent-swarm
git add docs/runbooks/adding-agent.md
git commit -m "docs(runbook): rewrite adding-agent for v0.2.0 array shape

Six-step procedure: Infisical secret → homelab ExternalSecret →
persona (chart-bundled or operator-supplied ConfigMap) → append to
agents array in fleet HelmRelease → merge + watch Flux → verify in
Matrix. Calls out the per-agent image.tag override as the canary
mechanism for staging a new agent on a different chart version."
```

---

### Task 15: Update `docs/runbooks/release.md` with staging notes

**Files:**
- Modify: `/workspace/agent-swarm/docs/runbooks/release.md`

- [ ] **Step 1: Read the current release runbook**

```bash
cat /workspace/agent-swarm/docs/runbooks/release.md
```

- [ ] **Step 2: Add a "Staged release" section**

Append a new section before the existing wrap-up:

```markdown
## Staged release (per-agent canary)

For v0.2.0+ charts using the `agents: [...]` shape, you can roll a
single agent onto a new image tag while the rest of the fleet stays
on the current tag — useful for surface-area changes (setup.sh, new
chart logic, plugin reconciler edits).

### Steps

1. Cut the release as usual (`cut-release.sh --version vX.Y.Z`).
2. Bump the homelab chart pin to the new chart version normally.
3. In `k8s/apps/agents/agent-smith-fleet-helmrelease.yaml`, set
   `agents[i].image.tag` on ONE agent (typically devbot first) to the
   new image tag. Leave the rest at the fleet default.
4. Flux reconciles → only that one agent rolls. The others stay
   pinned to the previous tag.
5. Observe ~24h. Verify the canary agent's setup completes cleanly,
   the plugin reconciler runs, Matrix sync works.
6. Promote: remove the `image.tag` override from the canary entry;
   the agent rolls onto the fleet default (now matching the rest).
7. Optional: bump the fleet-wide `.image.tag` to the new version; all
   remaining agents roll.

### Rollback

Delete the `image.tag` override; the canary agent rolls back to the
fleet default.
```

- [ ] **Step 3: Commit**

```bash
cd /workspace/agent-swarm
git add docs/runbooks/release.md
git commit -m "docs(runbook): document per-agent staged release flow

Seven-step procedure for canary-rolling one agent onto a new image
tag while the rest of the fleet stays pinned to the prior tag.
Rollback = remove the image.tag override."
```

---

## Phase 8 — Push + PR

### Task 16: Push branch + open PR + DevBot ping

**Files:** (no edits)

- [ ] **Step 1: Run the full test suite once more**

```bash
cd /workspace/agent-swarm
bash tests/test-chart-render.sh
```

Expected: 31 passes, 0 fail, exit 0.

- [ ] **Step 2: Syntax check all touched bash scripts**

```bash
bash -n /workspace/agent-swarm/scripts/setup.sh
bash -n /workspace/agent-swarm/tests/test-chart-render.sh
echo "all bash syntax OK"
```

- [ ] **Step 3: `helm lint` clean**

```bash
cd /workspace/agent-swarm
helm lint charts/agent-smith -f /tmp/values-two-agents.yaml
```

Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 4: Push the branch**

```bash
cd /workspace/agent-swarm
git push -u origin feat/chart-array-of-agents
```

- [ ] **Step 5: Open the PR**

```bash
cd /workspace/agent-swarm
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create \
  --repo sherodtaylor/agent-smith \
  --head feat/chart-array-of-agents --base main \
  --title "feat(chart): v0.2.0 — agents array + persona ConfigMap + staging knobs" \
  --body "$(cat <<'EOF'
## Summary
Refactors the chart from one-agent-per-HelmRelease to a values-side `agents: [...]` array. Decouples persona content from the image via mounted ConfigMaps (hybrid: chart-bundled defaults + per-agent `configMapRef` override). Adds per-agent `image.tag` and `configMapRef` overrides for staged canary rolls.

## Spec
[`docs/superpowers/specs/2026-05-28-chart-array-config-staged-design.md`](https://github.com/sherodtaylor/agent-smith/blob/main/docs/superpowers/specs/2026-05-28-chart-array-config-staged-design.md) (PR #56, merged).

## Changes
- Chart `v0.2.0`: new `agents: []` schema, range-loop templates, persona/shared ConfigMap mounts, `agent-smith.agentList` deprecation shim
- `scripts/setup.sh`: reads persona from `/etc/agent-smith/{shared,persona}/` when present; falls back to baked-in paths
- `tests/test-chart-render.sh`: 31 assertions across 10 cases (single, fan-out, RBAC, reauth on/off, persona, configMapRef, legacy shim, both-set error, empty error, staging knobs)
- Docs: `CHANGELOG.md`, `docs/architecture.md`, `docs/runbooks/adding-agent.md`, `docs/runbooks/release.md`

## Migration
Two-phase rollout in homelab follows in a separate PR:
- **Phase 1 (canary)**: new fleet HelmRelease with `agents: [devbot]`; suspend old `devbot-helmrelease.yaml`. PVCs preserved by StatefulSet name stability.
- **Phase 2**: append infrabot to the array; suspend then delete old HRs.
- **Rollback**: re-enable the suspended old HR at any phase.

Deprecation shim keeps the legacy `agentName: foo` shape working through `v0.2.x` and `v0.3.x`; removed in `v0.4.0`.

## Test plan
- [x] `bash tests/test-chart-render.sh` — 31/31 PASS
- [x] `helm lint charts/agent-smith -f <values>` — clean
- [x] `helm template` renders correctly for all 10 cases (single, fan-out, RBAC, reauth on/off, persona, configMapRef, legacy, both-set error, empty error, image.tag override)
- [ ] Post-merge: cut `v0.2.0`, then homelab Phase 1 PR (devbot canary on new fleet HR)
- [ ] Post-merge Phase 2: infrabot migration to fleet HR

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 6: Cross-agent ping**

Post in `#dev` Matrix room (`!p9BEyaj6qFakLyd5Pp:lab.sherodtaylor.dev`):

`@devbot:lab.sherodtaylor.dev review please: <PR URL>`

Wait for review, address comments, merge.

---

## Phase 9 — Cluster validation (deferred, follow-up homelab PRs)

### Task 17: Phase 1 cluster (devbot canary)

Deferred until the chart PR merges and `v0.2.0` is released.

- [ ] **Step 1: Cut release**

```bash
cd /workspace/agent-swarm
git fetch origin && git checkout main && git pull --ff-only
SSL_CERT_FILE=/root/iron-proxy.crt GH_TOKEN="$(SSL_CERT_FILE=/root/iron-proxy.crt gh auth token 2>/dev/null)" \
  .claude/references/cut-release.sh --version v0.2.0 \
  --message "agents array + persona ConfigMap + staging knobs"
```

- [ ] **Step 2: Wait for CI**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh run watch --repo sherodtaylor/agent-smith
```

Expected: build + chart jobs both green.

- [ ] **Step 3: Open homelab Phase 1 PR**

Create a new homelab branch with:

1. New `k8s/apps/agents/agent-smith-fleet-helmrelease.yaml` containing the chart pinned to `0.2.0` and `agents: [{name: devbot, ...}]` (single entry).
2. Edit `k8s/apps/agents/devbot-helmrelease.yaml` to set `spec.suspend: true`.
3. Update `kustomization.yaml`: keep both files in the list (suspended HR still present but inactive).

Push + open PR, ping DevBot for review.

- [ ] **Step 4: After merge, observe rollout**

```bash
kubectl get helmrelease -n agents
kubectl rollout status statefulset/devbot -n agents --timeout=3m
kubectl logs -n agents devbot-0 -c setup --tail=200 | grep -E '\[setup\]|\[reconcile\]'
```

Expected: `[setup] CLAUDE.md assembled from mounted ConfigMaps` (the new path), `[reconcile] starting`, etc.

- [ ] **Step 5: Verify devbot is still on the right Matrix identity**

In Matrix, ping devbot in `#dev`. Confirm response.

### Task 18: Phase 2 cluster (infrabot migration, kills my session)

After ~24h of devbot stability on the fleet HelmRelease:

- [ ] **Step 1: Append infrabot to the fleet HR's `agents` array**

Edit `agent-smith-fleet-helmrelease.yaml` in homelab; add an entry mirroring the existing `infrabot-helmrelease.yaml` values.

- [ ] **Step 2: Suspend old infrabot-helmrelease.yaml**

Set `spec.suspend: true` on the old HR.

- [ ] **Step 3: Open PR, merge**

Standard flow.

- [ ] **Step 4: Post Matrix warning before infrabot rolls (kills session)**

`@sherod: about to migrate infrabot to fleet HR; my session will end at the rollover. Next-spawn infrabot picks up the new chart shape automatically.`

- [ ] **Step 5: Flux reconciles, infrabot rolls**

The next-spawn pod (a fresh me) runs from the new fleet HR.

### Task 19: Cleanup — delete suspended HRs

After both agents stable on the fleet HR (~24h after Phase 2):

- [ ] **Step 1: Delete `k8s/apps/agents/{devbot,infrabot}-helmrelease.yaml`** in homelab.
- [ ] **Step 2: Update `kustomization.yaml`** to drop the entries.
- [ ] **Step 3: PR + merge.** Flux removes the suspended HR objects; no resource impact (already suspended).

---

## Self-Review Notes

**Spec coverage** — every section of `docs/superpowers/specs/2026-05-28-chart-array-config-staged-design.md` maps to a task:

- agents[] schema → Task 2 (values.yaml + helpers) + Task 3 (statefulset template)
- Per-agent persona mount → Tasks 6 (shared CM) + 7 (per-agent CM) + 8 (checksum annotations) + 9 (setup.sh)
- Per-agent staging knobs (image.tag, configMapRef) → Tasks 3 (template wiring) + 11 (smoke tests)
- Chart-generated per-agent resources → Tasks 3 (STS) + 4 (SA + RBAC) + 5 (reauth Svc + Ingress)
- Shared resources → Task 4 (one ClusterRole) + 6 (shared CM)
- Deprecation shim → Task 2 (helper) + 10 (smoke tests for legacy + both-set + empty)
- Migration plan → Tasks 17-19 (deferred cluster work)
- File map → covered across tasks 2-15
- Acceptance criteria → smoke tests in tasks 3, 4, 5, 7, 8, 10, 11; cluster work in 17-18
- Docs (no drift per Sherod's living-docs rule) → Tasks 12 (CHANGELOG), 13 (architecture), 14 (adding-agent runbook), 15 (release runbook)

**Placeholders** — none. Every step has concrete commands, code blocks, expected output.

**Type / naming consistency:**

- `agent-smith.agentList` returns JSON (string); callers always `fromJsonArray (include "agent-smith.agentList" .)` — consistent.
- `$root` is the chart context, `$agent` is the loop var — consistent across all templates.
- `agent-smith.agentImageTag` takes a dict `{agent, Values, Chart}` — called consistently in statefulset.yaml (init + main containers).
- `agent-smith.personaConfigMapName` takes the agent entry directly — consistent.
- ConfigMap naming: `agent-smith-shared` (singleton), `agent-smith-persona-<name>` (chart-rendered), operator-supplied via `configMapRef` (any name) — consistent across templates.

**Open dependencies** — Task 6 Step 1 requires manually copying `agents/_shared/CLAUDE.md` from the repo root into `charts/agent-smith/agents/_shared/` so Helm's `Files.Get` can resolve. This is a Spec B convention question (where do persona files live in the chart source?); for this plan, we accept the copy. A symlink would work in development but doesn't ship in the chart archive; Spec B will formalize.

**Risk acknowledged in spec, addressed in plan:**

- PVC identity preservation → Tasks 3-5 keep `metadata.name: {{ $agent.name }}` (no release-name prefix). Implicit assertion via the smoke tests that grep for exact `name: <agent>` strings.
- ConfigMap-driven pod restart → Task 8 adds `checksum/persona-*` and `checksum/shared` annotations.
- Suspended HelmRelease ownership conflict → Migration runbook (Task 17 Step 3) orders suspend-old-first before commit-new. Risk acknowledged in the spec.
