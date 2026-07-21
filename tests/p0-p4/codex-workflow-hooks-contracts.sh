#!/usr/bin/env bash

set -euo pipefail

if [[ -z "${P0P4_HARNESS_LOADED:-}" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/p0p4-harness.sh"
fi
p0p4_bootstrap_suite "${BASH_SOURCE[0]}"

validate_install() {
    python - "$1" <<'PY'
import json
import sys
home = sys.argv[1]
with open(home + "/.codex/hooks.json", encoding="utf-8") as stream:
    hooks = json.load(stream)["hooks"]
root = home + "/.codex/hooks/assistant/"
commands = [hook["command"] for groups in hooks.values() for group in groups for hook in group["hooks"]]
assert root + "workflow-enforcer.sh" in commands
assert root + "subagent-monitor.sh" in commands
assert root + "stop-review.sh" in commands
assert "/tmp/custom-stop.sh" in commands
assert commands.count(root + "workflow-enforcer.sh") == 1
PY
}

test_start "Codex workflow hooks install idempotently and preserve custom commands"
home_dir="$(mktemp -d)"
p0p4_register_cleanup "$home_dir"
mkdir -p "$home_dir/.codex"
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/tmp/custom-stop.sh"}]}]}}' > "$home_dir/.codex/hooks.json"
if HOME="$home_dir" bash "$FRAMEWORK_DIR/install.sh" --agent codex --skill assistant-workflow >/dev/null 2>&1 \
    && python "$FRAMEWORK_DIR/tools/install-codex-hooks.py" "$home_dir/.codex/hooks.json" "$FRAMEWORK_DIR/hooks/codex-settings.json" "$home_dir/.codex/hooks/assistant" \
    && validate_install "$home_dir" \
    && rg -q '^hooks = true$' "$home_dir/.codex/config.toml"; then
    pass
else
    fail "mandatory Codex hooks were not installed idempotently"
fi

test_start "Phase and native-agent hooks emit expected status and gate evidence"
project_dir="$(mktemp -d)"
p0p4_register_cleanup "$project_dir"
mkdir -p "$project_dir/.codex"
hook_project_cwd="$project_dir"
if command -v cygpath >/dev/null 2>&1; then
    hook_project_cwd="$(cygpath -m "$project_dir")"
fi
cat > "$project_dir/.codex/task.md" <<'TASK'
Status: BUILDING
Created: task-current
Controller intensity: strict
Subagent execution mode: delegated
Required agents:
- Reviewer
Agent routing plans:
- {"requested_configuration":{"model":"gpt-5.6-terra","reasoning_effort":"medium"}}
TASK
prompt_json="{\"prompt\":\"continue\",\"cwd\":\"$hook_project_cwd\"}"
start_json="{\"hook_event_name\":\"SubagentStart\",\"agent_type\":\"reviewer\",\"agent_id\":\"agent-1\",\"model\":\"gpt-5.6-terra\",\"model_reasoning_effort\":\"medium\",\"cwd\":\"$hook_project_cwd\"}"
mismatched_stop_json="{\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"reviewer\",\"agent_id\":\"agent-2\",\"model\":\"gpt-5.6-terra\",\"model_reasoning_effort\":\"medium\",\"cwd\":\"$hook_project_cwd\"}"
correct_stop_json="{\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"reviewer\",\"agent_id\":\"agent-1\",\"model\":\"gpt-5.6-terra\",\"model_reasoning_effort\":\"medium\",\"cwd\":\"$hook_project_cwd\"}"
runtime_unknown_start_json="{\"hook_event_name\":\"SubagentStart\",\"agent_type\":\"code-writer\",\"agent_id\":\"agent-unknown\",\"cwd\":\"$hook_project_cwd\"}"
prompt_out="$(printf '%s' "$prompt_json" | bash "$FRAMEWORK_DIR/hooks/scripts/workflow-enforcer.sh")"
block_out="$(printf '%s' "{\"cwd\":\"$hook_project_cwd\"}" | bash "$FRAMEWORK_DIR/hooks/scripts/stop-review.sh")"
start_out="$(printf '%s' "$start_json" | bash "$FRAMEWORK_DIR/hooks/scripts/subagent-monitor.sh")"
printf '%s\n' '{"event":"SubagentStart","agent_type":"reviewer","agent_id":"stale-agent","task_created":"task-stale"}' '{"event":"SubagentStop","agent_type":"reviewer","agent_id":"stale-agent","task_created":"task-stale"}' >> "$project_dir/.codex/subagent-events.jsonl"
printf '%s' "$mismatched_stop_json" | bash "$FRAMEWORK_DIR/hooks/scripts/subagent-monitor.sh" >/dev/null
printf '%s' "$runtime_unknown_start_json" | bash "$FRAMEWORK_DIR/hooks/scripts/subagent-monitor.sh" >/dev/null
printf '%s\n- Review result: CLEAN\n' >> "$project_dir/.codex/task.md"
stale_or_mismatched_out="$(printf '%s' "{\"cwd\":\"$hook_project_cwd\"}" | bash "$FRAMEWORK_DIR/hooks/scripts/stop-review.sh")"
printf '%s' "$correct_stop_json" | bash "$FRAMEWORK_DIR/hooks/scripts/subagent-monitor.sh" >/dev/null
allow_out="$(printf '%s' "{\"cwd\":\"$hook_project_cwd\"}" | bash "$FRAMEWORK_DIR/hooks/scripts/stop-review.sh")"
if python - "$prompt_out" "$block_out" "$start_out" "$project_dir/.codex/subagent-events.jsonl" "$stale_or_mismatched_out" "$allow_out" <<'PY'
import json
import sys
prompt, block, start, events_path, stale_or_mismatched, allow = sys.argv[1:]
context = json.loads(prompt)["hookSpecificOutput"]["additionalContext"]
assert "Phase: BUILDING | Agents: evidence pending | Modelo solicitado: gpt-5.6-terra/medium | Next gate: agents and review" in context
assert "Real" not in context
assert "Effective" not in context
assert "pending-runtime" not in context
assert json.loads(block)["decision"] == "block"
assert "reviewer" in json.loads(start)["hookSpecificOutput"]["additionalContext"]
events = [json.loads(line) for line in open(events_path, encoding="utf-8") if line.strip()]
assert len(events) == 6
for event in (events[0], events[3], events[5]):
    assert event["model"] == "gpt-5.6-terra"
    assert event["model_reasoning_effort"] == "medium"
    assert event["task_created"] == "task-current"
assert events[1]["task_created"] == "task-stale"
assert events[2]["task_created"] == "task-stale"
assert events[3]["agent_id"] == "agent-2"
assert "model" not in events[4]
assert "model_reasoning_effort" not in events[4]
assert events[4]["task_created"] == "task-current"
assert json.loads(stale_or_mismatched)["decision"] == "block"
assert "missing native lifecycle evidence" in json.loads(stale_or_mismatched)["reason"]
assert allow == ""
PY
then
    pass
else
    fail "phase status, native lifecycle evidence, or stop gate did not behave as expected"
fi

test_start "Stop gate fails closed when a delegated strict journal has no Created identity"
missing_created_project_dir="$(mktemp -d)"
p0p4_register_cleanup "$missing_created_project_dir"
mkdir -p "$missing_created_project_dir/.codex"
missing_created_hook_project_cwd="$missing_created_project_dir"
if command -v cygpath >/dev/null 2>&1; then
    missing_created_hook_project_cwd="$(cygpath -m "$missing_created_project_dir")"
fi
cat > "$missing_created_project_dir/.codex/task.md" <<'TASK'
Status: BUILDING
Controller intensity: strict
Subagent execution mode: delegated
Required agents:
- Reviewer
Review result: CLEAN
TASK
missing_created_start_json="{\"hook_event_name\":\"SubagentStart\",\"agent_type\":\"reviewer\",\"agent_id\":\"agent-1\",\"cwd\":\"$missing_created_hook_project_cwd\"}"
missing_created_stop_json="{\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"reviewer\",\"agent_id\":\"agent-1\",\"cwd\":\"$missing_created_hook_project_cwd\"}"
printf '%s' "$missing_created_start_json" | bash "$FRAMEWORK_DIR/hooks/scripts/subagent-monitor.sh" >/dev/null
printf '%s' "$missing_created_stop_json" | bash "$FRAMEWORK_DIR/hooks/scripts/subagent-monitor.sh" >/dev/null
missing_created_stop_out="$(printf '%s' "{\"cwd\":\"$missing_created_hook_project_cwd\"}" | bash "$FRAMEWORK_DIR/hooks/scripts/stop-review.sh")"
if python - "$missing_created_project_dir/.codex/subagent-events.jsonl" "$missing_created_stop_out" <<'PY'
import json
import sys
events_path, stop_out = sys.argv[1:]
events = [json.loads(line) for line in open(events_path, encoding="utf-8") if line.strip()]
assert [event["event"] for event in events] == ["SubagentStart", "SubagentStop"]
assert {event["agent_id"] for event in events} == {"agent-1"}
assert all("task_created" not in event for event in events)
result = json.loads(stop_out)
assert result["decision"] == "block"
assert "missing native lifecycle evidence" in result["reason"]
PY
then
    pass
else
    fail "stop gate allowed delegated lifecycle evidence without a Created task identity"
fi

test_start "Phase hook reports an undefined model without routing configuration"
empty_project_dir="$(mktemp -d)"
p0p4_register_cleanup "$empty_project_dir"
mkdir -p "$empty_project_dir/.codex"
empty_hook_project_cwd="$empty_project_dir"
if command -v cygpath >/dev/null 2>&1; then
    empty_hook_project_cwd="$(cygpath -m "$empty_project_dir")"
fi
printf '%s\n' 'Status: DISCOVERING' > "$empty_project_dir/.codex/task.md"
empty_prompt_out="$(printf '%s' "{\"prompt\":\"continue\",\"cwd\":\"$empty_hook_project_cwd\"}" | bash "$FRAMEWORK_DIR/hooks/scripts/workflow-enforcer.sh")"
if python - "$empty_prompt_out" <<'PY'
import json
import sys
context = json.loads(sys.argv[1])["hookSpecificOutput"]["additionalContext"]
assert "Modelo solicitado: not defined" in context
assert "Real" not in context
assert "Effective" not in context
assert "pending-runtime" not in context
PY
then
    pass
else
    fail "phase hook did not report an undefined model without routing configuration"
fi

p0p4_finish_suite "${BASH_SOURCE[0]}"
