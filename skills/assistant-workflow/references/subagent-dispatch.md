# Subagent Dispatch — Roles and Rules

Use specialized agents when the active tool policy and user authorization allow delegation. Each role has constrained access: code-reviewer, qa-evaluator, and reviewer cannot edit files, and code-writer does not run tests. When subagents are unavailable, denied, or policy-disallowed, keep the same role responsibilities as direct fallback evidence instead of pretending delegation happened.

For full role prompts, read `references/subagent-roles.md`.

## Agent Routing Plan

Before every native dispatch, create the public `agent_routing_plan` defined in
`contracts/handoffs.yaml`; select it through `contracts/index.yaml` under
`selected_handoff` before the role-specific handoff. It is required even if the active runtime cannot
honor model overrides. `model` and `model_reasoning_effort` are optional native
subtask arguments: request them only when the runtime supports an override.
The route's static profile remains requested intent, never proof of effective
runtime configuration. Record:

| Field | Allowed values / requirement |
|---|---|
| `role` | Selected workflow role |
| `difficulty` | `bounded`, `standard`, `complex`, or `critical` |
| `capability_tier` | `fast`, `balanced`, or `frontier` |
| `reasoning_effort` | `low`, `medium`, `high`, `xhigh`, or exceptional `max` |
| `selection_factors` | Concrete scope, risk, uncertainty, verification, and tool-access reasons |
| `escalation_trigger` | Observable condition that requires a stronger route or re-triage |
| `route_id` | One route from the policy table below |
| `agent_name` | Selected native agent name from the route |
| `requested_configuration` | What the orchestrator asked the runtime to use |
| `effective_configuration` | What the runtime/tool result confirms it used; never assume it equals requested |
| `runtime_fallback` | Default/direct/alternate route and evidence when requested configuration is unavailable |

Use `max` only when **critical risk** is paired with **unresolved high-impact
ambiguity** or **repeated verified failure** after lower adequate efforts.
Selection means efficient verified outcomes, not a blanket cheapest-model rule.

### Route policy (canonical)

This table is the policy source for route selection. `model` and
`reasoning_effort` are the static profile recorded under
`requested_configuration`; they become effective only when runtime evidence
confirms them.

The selected `route_id`, `agent_name`, and their copies in
`requested_configuration` are one binding: validate all four values against
this row before dispatch. This validates the recorded request, not runtime
enforcement or effective configuration.

| `route_id` | Native `agent_name` | Static profile | Use |
|---|---|---|---|
| `map_fast` | `code-mapper-fast` | `gpt-5.6-luna` / `low` | Bounded, read-only structural mapping only |
| `discover_balanced` | `explorer` | `gpt-5.6-terra` / `medium` | Ordinary bounded discovery with meaningful tracing |
| `discover_frontier` | `explorer-frontier` | `gpt-5.6-sol` / `high` | Critical or conflicting-evidence investigation |
| `implement_balanced` | `code-writer` | `gpt-5.6-terra` / `medium` | Approved standard implementation slice |
| `implement_frontier` | `code-writer-frontier` | `gpt-5.6-sol` / `high` | High-impact implementation needing deeper reasoning |
| `verify_balanced` | `builder-tester` | `gpt-5.6-terra` / `medium` | Ordinary build, test, and validation work |
| `verify_frontier` | `builder-tester-frontier` | `gpt-5.6-sol` / `high` | High-impact or repeatedly failing verification |
| `design_frontier` | `architect` | `gpt-5.6-sol` / `high` | Architecture or design with critical impact |
| `review_frontier` | `code-reviewer` | `gpt-5.6-sol` / `high` | High-risk security, migration, or architecture review |
| `qa_frontier` | `qa-evaluator` | `gpt-5.6-sol` / `high` | High-impact acceptance evaluation |

Luna remains mapping-only: do not route `code-mapper-fast` to design,
implementation, verification, review, or QA work. Promote a route only when
evidence shows coupled modules, security or migration impact, conflicting
evidence, non-deterministic validation failures, or repeated verified failure.
Record the observed trigger in `selection_factors` and `escalation_trigger`;
do not promote based on size, importance, or preference alone.

### Intent, runtime reality, and fallback

Use this shape before dispatch; `model` and `reasoning_effort` are requested
profile values, while `model_reasoning_effort` is the optional native subtask
argument that carries the same requested effort when the runtime exposes it:

```yaml
route_id: implement_balanced
agent_name: code-writer
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

After dispatch, set `effective_configuration.status: confirmed` only when a
runtime/tool result identifies the applied configuration. If that result does
not expose or rejects the override, use `status: unavailable`, preserve the
requested values as intent, and cite the returned evidence. A pending record
may remain only while runtime confirmation is still possible; it blocks
completion if it is still pending at the relevant completion gate.

## Native Task Title

Before a top-level Codex task starts work, set its task title through the
native title API using this exact compact shape:

`Req: <requested model>/<requested reasoning> | Real: <effective model>/<effective reasoning|pending-runtime> | <task>`

Use `pending-runtime` until the runtime/tool result confirms the effective
configuration. Update the title after that confirmation. The current native
hook and subagent surfaces do not expose a child-task title mutation API, so
record this same string as `title_metadata` in every subagent dispatch log.
Never substitute the requested configuration for the effective one.

Record title metadata as evidence, not as a success claim:

```yaml
title_metadata:
  requested_title: "Req: gpt-5.6-terra/medium | Real: pending-runtime/pending-runtime | approved slice"
  effective_title: "Req: gpt-5.6-terra/medium | Real: pending-runtime/pending-runtime | approved slice"
  status: pending_runtime_confirmation
  evidence_source: pending
```

Set `status: confirmed` only with native title API or runtime/tool evidence.
When that surface cannot report or mutate the title, use `status: unavailable`
and record the limitation in `evidence_source`.

## Delegation Policy State

Before spawning any subagent, resolve:

| Field | Values | Meaning |
|---|---|---|
| `subagent_policy_state` | `not_required`, `authorization_required`, `delegation_authorized`, `authorization_denied`, `subagents_unavailable`, `policy_disallowed` | Whether spawning subagents is allowed for this task and adapter |
| `subagent_execution_mode` | `delegated`, `direct_fallback`, `not_applicable` | Whether work is executed by subagents, by direct fallback with equivalent evidence, or without any subagent role |
| `subagent_authorization_scope` | list of roles/phases/actions | What the user explicitly authorized, when authorization was required |

Light small low-risk localized work uses `subagent_policy_state=not_required`
and `subagent_execution_mode=not_applicable`; it does not ask for delegation and
instead records direct implementation, relevant automated validation/tests, and
a fresh self-review. For standard/strict development/code-work roles, Assistant
Framework policy requires explicit user authorization before spawning subagents.
Ask once for the required scope before the first spawn unless the current
user prompt already explicitly authorizes subagents for this task. If authorization
is granted, set `subagent_policy_state=delegation_authorized`, set
`subagent_execution_mode=delegated`, and spawn the configured role agents. If
authorization has not been granted or denied yet, keep
`subagent_policy_state=authorization_required`, ask the authorization question,
and wait; do not continue through phases that require subagents. For Codex,
current CLI/app releases support native subagent workflows by default; custom
agents live in `~/.codex/agents/` or project `.codex/agents/` and are spawned by
explicitly asking Codex to spawn an agent by name. Do not mark
`subagents_unavailable` merely because the visible tool list lacks a tool named
`Task`, `delegate`, or `subagent`; only use `subagents_unavailable` after a real
spawn attempt fails or the adapter documentation/configuration proves no subagent
mechanism exists. If the user declines or policy disallows spawning for
standard/strict work, use `direct_fallback` and preserve the same phase gates,
role separation, verification evidence, and review evidence.

## Roles

| Role | Claude (agent name) | Codex (agent name) | Access | Phase |
|---|---|---|---|---|
| **Code Mapper** | `code-mapper` | `code-mapper` | Read-only | Discover |
| **Explorer** | `explorer` | `explorer` | Read-only | Discover |
| **Architect** | `architect` | `architect` | Read-only | Decompose, Plan, Design |
| **Code Writer** | `code-writer` | `code-writer` | Write | Build |
| **Builder/Tester** | `builder-tester` | `builder-tester` | Write | Build |
| **Code Reviewer** | `code-reviewer` | `code-reviewer` | Read-only | Review |
| **Reviewer** | `reviewer` | `reviewer` | Read-only | Review compatibility |
| **QA Evaluator** | `qa-evaluator` | `qa-evaluator` | Read-only | Review QA |

## What each role does

- **Code Mapper** — Lightweight structural map: file paths, entry points, interfaces, conventions. Output is compact enough to paste into other agents' prompts. Runs first on medium+ tasks.
- **Explorer** — Deep analysis: traces execution paths, analyzes design decisions, finds hidden dependencies and coupling. Understands WHY, not just WHERE.
- **Architect** — Designs implementation blueprints: files to create/modify, interfaces, data flows, build sequence, test plan. Does not write code.
- **Code Writer** — Implements code following the plan. Does not run builds or tests. Does not review. Focuses purely on clean, convention-matching implementation.
- **Builder/Tester** — Builds the project, writes tests, runs tests, absorbs noisy output. Returns concise results ("build passed, 2 tests failed: X, Y") not full logs.
- **Code Reviewer** — Canonical independent code review with confidence-based filtering. Finds bugs, security issues, architecture violations, test coverage gaps, and structural code issues. Does not edit files.
- **Reviewer** — Compatibility route for existing handoffs that still say `Reviewer`; use only when `code-reviewer` is unavailable or a legacy prompt/handoff requires the old name.
- **QA Evaluator** — Independent QA acceptance evaluation after build/test and code-review evidence. Checks acceptance criteria, Done Contract, verification evidence, scoped UI/visual/product/UX/docs/DX/domain quality, score progression, and final result. Does not replace Code Reviewer.

## Phase-to-subagent requirements

Standard/strict phases have declared role responsibilities. Phases without a
subagent role are handled directly by the Orchestrator with explicit
justification. Phases with a subagent role dispatch only when
`subagent_execution_mode=delegated`; otherwise standard/strict direct fallback
records equivalent evidence. The light lane is direct/not_applicable and uses
its compact validation plus fresh-review evidence instead.

| Phase | Subagent(s) | Condition | Justification |
|---|---|---|---|
| **TRIAGE** | — (Orchestrator direct) | All sizes | Too lightweight for dispatch — single classification decision |
| **DISCOVER** | Code Mapper | Medium+ | Produces context map for downstream agents |
| **DISCOVER** | Explorer | Large+ | Traces execution paths and hidden dependencies |
| **DECOMPOSE** | Architect | Medium+ | Analyzes problem boundaries and proposes strict slice manifest |
| **PLAN** | Architect | Large+ | Designs full implementation blueprint from slice manifest |
| **DESIGN** | Architect | UI tasks | Proposes design direction; Orchestrator creates mockup |
| **BUILD** | Code Writer | Standard/strict | Implements code following the plan |
| **BUILD** | Builder/Tester | Standard/strict | Builds, runs tests, returns concise results |
| **REVIEW** | Code Reviewer, or Reviewer compatibility | Standard/strict | Independent code review via `assistant-review` skill |
| **REVIEW** | QA Evaluator | `qa_evaluation_mode=required` only | Independent acceptance QA via `assistant-review` QA loop |
| **DOCUMENT** | — (Orchestrator direct) | All sizes | Documentation generation is orchestrator's synthesis work |

**Rule:** If `subagent_execution_mode=delegated` and a phase's subagent column shows a dispatch, you MUST dispatch that role. If `subagent_execution_mode=direct_fallback`, you MUST NOT spawn subagents; instead record which role responsibility was handled directly and what equivalent evidence proves it.

**Native dispatch rule:** Validate the selected handoff and its
`agent_routing_plan` before invoking the runtime. After it returns, update
`effective_configuration` and `runtime_fallback` from runtime evidence before
the next dispatch or completion gate.

## Dispatch rules by task size

| Size | Agents used | Flow |
|---|---|---|
| **Small light** | None | Direct implementation, relevant automated validation/tests, and fresh self-review; promote out of light when risk/harness/QA criteria apply |
| **Small standard/strict** | Code Writer → Builder/Tester → Code Reviewer | Sequential, minimal (no Decompose); Reviewer may be used only as compatibility; QA only when required |
| **Medium** | Code Mapper → Architect (decompose) → Code Writer → Builder/Tester → Code Reviewer → QA Evaluator when required | Mapper feeds Architect, slices feed Writer; Reviewer may be used only as compatibility |
| **Large** | Code Mapper → Explorer → Architect (decompose + plan) → Code Writer → Builder/Tester → Code Reviewer → QA Evaluator when required | Full pipeline with slice verification; Reviewer may be used only as compatibility |
| **Mega** | All roles, parallel Code Writers per slice | Mapper → Explorer → Architect → parallel Writers → Builder/Tester, Code Reviewer, and QA Evaluator when required at integration |

## Dispatch guidelines

- **Light lane**: small low-risk localized work may keep `required_agents`
  empty and use direct implementation, relevant automated validation/tests, and
  fresh self-review evidence. `subagent_execution_mode=not_applicable` is valid
  for this lane. Security, high-risk, harness-capable, required-QA, or otherwise
  promoted work cannot use this exception.
- **Standard/strict minimum**: Code Writer → Builder/Tester → Code Reviewer
  responsibilities. `reviewer` remains valid compatibility routing for existing
  handoffs, but new dispatches should use `code-reviewer` for code defects,
  security, architecture, test coverage, and structural code issues. In
  delegated mode these are subagents; in direct fallback they are explicitly
  recorded role-equivalent steps. Standard/strict source-changing work infers
  these roles; `not_applicable` is invalid for its Build tasks.
- **Strict evidence gate for standard/strict work**: delegated mode is not complete until the
  task journal Agent Dispatch Log records Code Writer dispatch/result,
  Builder/Tester dispatch/result, and Code Reviewer dispatch/result evidence,
  or Reviewer dispatch/result evidence when compatibility routing is used.
  Medium+ delegated slice work also records per-slice dispatch evidence before
  each slice is marked verified. Delegated evidence must correspond to a real
  native dispatch/thread and result. Reference the agent id, task name, thread,
  or tool result when the runtime exposes one; task-journal claims without a
  matching native result do not satisfy delegated evidence. Direct fallback is
  allowed only for explicit `authorization_denied`,
  `subagents_unavailable`, or `policy_disallowed` reasons, and must record
  equivalent role, phase, verification, and review evidence; silent fallback
  fails the completion gates.
- **QA evidence gate**: when QA is required, delegated mode is not complete until the task journal Agent Dispatch Log records QA Evaluator dispatch/result evidence after Builder/Tester and Code Reviewer evidence. Direct fallback must record fresh QA Evaluator direct evidence separately from Code Reviewer direct evidence. QA required positive triggers: explicit QA/acceptance evaluation request, accepted Done Contract, harness-capable acceptance scope, domain-scored scope, or scoped UI/visual/product/UX/docs/DX acceptance. QA non-triggers: template labels/placeholders, generic acceptance criteria labels, optional/not_required reasons, delegation/source-changing work alone, and ordinary medium+ code-review-only/source-changing work.
- **Every medium+ task gets Architect decomposition responsibility**: In delegated mode the Architect proposes smallest iterable slice boundaries; in direct fallback the same criteria and evidence are recorded directly.
- **Launch in parallel** when agents are independent (e.g., Code Mapper + Explorer on different modules)
- **Code Mapper runs first** on medium+ tasks — its output feeds into Architect and Code Writer
- **Code Reviewer gets a fresh dispatch each round** during the quality review loop when delegated mode is authorized; `reviewer` is the compatibility route for older handoffs. Direct fallback must reset review context and record how stale-context risk was controlled.
- **QA Evaluator gets a fresh dispatch each QA round** when QA is required and delegated mode is authorized. Direct fallback must reset acceptance-evaluation context and record how stale-context risk was controlled.
- **Main session stays Orchestrator**: owns user communication, final integration, handoffs
- **Do not dispatch agents for small inline tasks** within a larger workflow (e.g., a one-line fix during review doesn't need a Code Writer agent)
