# Adaptive Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Make Assistant Framework select an auditable role-plus-capability route before each Codex subagent dispatch, using static named profiles as the compatibility baseline and runtime overrides only when confirmed.

**Architecture:** The workflow owns the policy and records one structured `agent_routing_plan` per dispatch. Native Codex agent TOMLs own the profile defaults. Hooks may capture runtime model fields only when the runtime provides them; they never infer an effective configuration or spawn agents. The installer keeps the root-agent `--adaptive-routing` default independent from subagent profile selection.

**Tech Stack:** Bash installer and contract tests; Markdown/YAML skill contracts; Codex TOML agent definitions; Python Codex hooks.

## Global Constraints

- Preserve the existing mandatory Codex hook work and repair its installer regression before adding routing profiles.
- Do not overwrite user-owned AGENTS.md content or claim requested configuration is effective without runtime evidence.
- Static named profiles are the cross-runtime fallback; per-dispatch model overrides are optional and must be marked unavailable when unsupported.
- Keep each role's sandbox boundary unchanged across profile variants.
- Do not introduce a hook that dispatches agents, changes models, or weakens approval/safety behavior.
- Keep root `skills/assistant-*` authoritative and refresh the generated assistant-dev skill mirror after changes.

---

### Task 1: Repair and lock down the generated Codex guidance

**Files:**
- Modify: `tests/p0-p4/installer-contracts.sh`
- Modify: `install.sh`

**Interfaces:**
- Consumes: `AGENTS_MD_CONTENT` in `install.sh`.
- Produces: an installable `~/.codex/AGENTS.md` whose routing-title example is literal text, not Bash command substitution.

- [ ] **Step 1: Add a failing installer assertion**

Extend the first Codex install scenario to require the generated `AGENTS.md` to contain this literal guidance:

```text
Req: <requested model>/<requested reasoning> | Real: <effective model|pending-runtime>/<effective reasoning|pending-runtime> | <task>
```

Run:

```bash
P0P4_DIRECT_RUN_GUARD=1 bash tests/p0-p4/installer-contracts.sh
```

Expected: failure caused by `install.sh` interpreting the backtick-delimited example as command substitution.

- [ ] **Step 2: Escape only the Bash interpolation hazard**

In the double-quoted `AGENTS_MD_CONTENT` assignment, render the title example with escaped literal backticks:

```bash
set its title through the Codex title API as \`Req: <requested model>/<requested reasoning> | Real: <effective model|pending-runtime>/<effective reasoning|pending-runtime> | <task>\`.
```

Do not alter the routing guidance itself.

- [ ] **Step 3: Verify the RED-to-GREEN repair**

Run the same focused installer suite. Expected: exit code `0`; the generated file preserves the literal title example and installation completes.

- [ ] **Step 4: Commit**

```bash
git add install.sh tests/p0-p4/installer-contracts.sh
git commit -m "fix: escape Codex routing title guidance"
```

### Task 2: Define route selection and evidence semantics

**Files:**
- Modify: `skills/assistant-workflow/references/subagent-dispatch.md`
- Modify: `skills/assistant-workflow/references/subagent-roles.md`
- Modify: `skills/assistant-workflow/contracts/handoffs.yaml`
- Modify: `skills/assistant-workflow/contracts/phase-gates.yaml`
- Modify: `skills/assistant-workflow/contracts/output.yaml`
- Modify: `skills/assistant-workflow/references/task-journal-template.md`
- Test: `skills/assistant-workflow/evals/cases.json`

**Interfaces:**
- Consumes: TRIAGE task type, risk, uncertainty, validation evidence, selected workflow role.
- Produces: one `agent_routing_plan` with `route_id`, selected native `agent_name`, requested model/reasoning, strategy, effective status/source, and fallback.

- [ ] **Step 1: Add eval cases before changing instructions**

Add cases that require the following outcomes:

```text
bounded mapping -> code-mapper-fast -> gpt-5.6-luna / low
standard implementation -> code-writer -> gpt-5.6-terra / medium
critical investigation -> explorer-frontier -> gpt-5.6-sol / high
runtime override unavailable -> static_profile fallback + effective_configuration=unavailable
max reasoning -> rejected without critical risk plus unresolved high-impact ambiguity or repeated verified failure
```

Run:

```bash
tools/evals/run-skill-evals.sh --validate-fixture
```

Expected: fixture validation passes; behavioral substring cases initially fail until the routing material is added.

- [ ] **Step 2: Add one route table as the policy source**

Document these route IDs and objective promotion triggers in `subagent-dispatch.md`:

```text
map_fast, discover_balanced, discover_frontier,
implement_balanced, implement_frontier,
verify_balanced, verify_frontier,
design_frontier, review_frontier, qa_frontier
```

Require a promotion only for evidence such as coupled modules, security/migration impact, conflicting evidence, non-deterministic validation failures, or repeated verified failure. Keep Luna mapping-only.

- [ ] **Step 3: Make the contract record route intent and reality separately**

Define the required shape in the routing-plan guidance:

```yaml
requested_configuration:
  route_id: implement_balanced
  agent_name: code-writer
  model: gpt-5.6-terra
  reasoning_effort: medium
  strategy: static_profile
effective_configuration:
  status: pending_runtime_confirmation
  agent_name: code-writer
  model: null
  reasoning_effort: null
  evidence_source: pending
runtime_fallback:
  strategy: static_profile
  reason: runtime override not requested
```

After dispatch, permit `status: confirmed` only with runtime evidence; otherwise use `unavailable` or retain pending until completion is blocked.

- [ ] **Step 4: Verify contract and eval consistency**

Run:

```bash
tools/skills/validate-skills.sh --skill assistant-workflow
tools/evals/run-skill-evals.sh --validate-fixture
```

Expected: both commands exit `0`.

- [ ] **Step 5: Commit**

```bash
git add skills/assistant-workflow
git commit -m "feat: define adaptive dispatch routes"
```

### Task 3: Add selectable static Codex routing profiles

**Files:**
- Create: `agents/codex/code-mapper-fast.toml`
- Create: `agents/codex/explorer-frontier.toml`
- Create: `agents/codex/code-writer-frontier.toml`
- Create: `agents/codex/builder-tester-frontier.toml`
- Modify: `tests/p0-p4/adaptive-routing-contracts.sh`

**Interfaces:**
- Consumes: a route's `agent_name`.
- Produces: a native Codex agent definition whose role instructions and sandbox match its base role and whose model/reasoning match the route table.

- [ ] **Step 1: Add failing catalog assertions**

Extend `adaptive-routing-contracts.sh` to require:

```text
code-mapper-fast:gpt-5.6-luna:low:read-only
explorer-frontier:gpt-5.6-sol:high:read-only
code-writer-frontier:gpt-5.6-sol:high:workspace-write
builder-tester-frontier:gpt-5.6-sol:high:workspace-write
```

Run:

```bash
P0P4_DIRECT_RUN_GUARD=1 bash tests/p0-p4/adaptive-routing-contracts.sh
```

Expected: failure because the four files do not yet exist.

- [ ] **Step 2: Create role-preserving variants**

Copy the behavioral responsibilities, output contract, and `sandbox_mode` from each base role. Change only `name`, `description`, `model`, `model_reasoning_effort`, and escalation guidance. The profile mappings are:

```toml
# code-mapper-fast
model = "gpt-5.6-luna"
model_reasoning_effort = "low"

# explorer-frontier, code-writer-frontier, builder-tester-frontier
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
```

- [ ] **Step 3: Verify catalog and installer propagation**

Run:

```bash
P0P4_DIRECT_RUN_GUARD=1 bash tests/p0-p4/adaptive-routing-contracts.sh
P0P4_DIRECT_RUN_GUARD=1 bash tests/p0-p4/installer-contracts.sh
```

Expected: both exit `0`; an install places all declared routing profiles under `~/.codex/agents`.

- [ ] **Step 4: Commit**

```bash
git add agents/codex tests/p0-p4/adaptive-routing-contracts.sh
git commit -m "feat: add adaptive Codex agent profiles"
```

### Task 4: Capture runtime evidence without fabricating it

**Files:**
- Modify: `hooks/scripts/codex-workflow-hooks.py`
- Modify: `tests/p0-p4/codex-workflow-hooks-contracts.sh`
- Modify: `skills/assistant-workflow/references/task-journal-template.md`

**Interfaces:**
- Consumes: optional hook payload keys `model` and `model_reasoning_effort`.
- Produces: optional event fields written to `.codex/subagent-events.jsonl`; the task journal references them as evidence only when present.

- [ ] **Step 1: Add a failing hook contract**

Pass this payload to the existing start/stop hook fixture and assert that the JSONL start event preserves both fields:

```json
{"hook_event_name":"SubagentStart","agent_type":"code-writer","model":"gpt-5.6-terra","model_reasoning_effort":"medium"}
```

Run:

```bash
P0P4_DIRECT_RUN_GUARD=1 bash tests/p0-p4/codex-workflow-hooks-contracts.sh
```

Expected: failure because the event logger currently records only IDs, role and timestamp.

- [ ] **Step 2: Record optional fields exactly as supplied**

Extend the event record with optional `model` and `model_reasoning_effort` values from the payload. Do not resolve values from a TOML file and do not add a stop-gate dependency on their presence.

- [ ] **Step 3: Verify absence stays unknown**

Keep the existing payload without model fields and assert that it produces empty/omitted evidence rather than a guessed model. Update the journal template to require an evidence source for a confirmed effective configuration.

- [ ] **Step 4: Commit**

```bash
git add hooks/scripts/codex-workflow-hooks.py tests/p0-p4/codex-workflow-hooks-contracts.sh skills/assistant-workflow/references/task-journal-template.md
git commit -m "feat: record runtime routing evidence"
```

### Task 5: Synchronize release artifacts, integrate and verify

**Files:**
- Modify: `README.md` only if its routing or hook statements no longer match behavior.
- Modify: `plugins/assistant-dev/skills/assistant-workflow/**` only through the synchronization script.
- Preserve: existing user changes and unrelated plan/plugin deletions unless their owner explicitly included them in this integration.

- [ ] **Step 1: Sync generated plugin skill copies**

Run:

```bash
tools/plugins/sync-plugin-skills.sh --apply
tools/plugins/sync-plugin-skills.sh --check
```

Expected: `--check` reports no stale generated assistant-dev copies.

- [ ] **Step 2: Run all repository verification**

Run:

```bash
tools/skills/validate-skills.sh
tools/evals/run-skill-evals.sh --validate-fixture
P0P4_DIRECT_RUN_GUARD=1 bash tests/test-p0-p4-contracts.sh
bash tests/test-p0-p4-contracts.sh
```

Expected: every command exits `0`; if the direct-run guard exposes an environment-only tool gap, record it separately and do not call the full suite green.

- [ ] **Step 3: Independently review the complete branch**

Generate a branch diff package, dispatch a read-only reviewer, fix Critical or Important findings, and re-run its relevant verification.

- [ ] **Step 4: Commit generated artifacts and documentation**

```bash
git add README.md plugins/assistant-dev/skills/assistant-workflow
git commit -m "docs: document adaptive routing profiles"
```

- [ ] **Step 5: Merge after final verification**

Merge `codex/adaptive-routing-integration` into `main`, re-run the full contract suite on the merge result, then push only after merge verification succeeds.
