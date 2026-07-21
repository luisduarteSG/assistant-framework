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
cat > "$project_dir/.codex/task.md" <<'TASK'
Status: BUILDING
Controller intensity: strict
Subagent execution mode: delegated
Required agents:
- Reviewer
Agent routing plans:
- {"requested_configuration":{"model":"gpt-5.6-terra","reasoning_effort":"medium"}}
TASK
prompt_json="{\"prompt\":\"continue\",\"cwd\":\"$project_dir\"}"
start_json="{\"hook_event_name\":\"SubagentStart\",\"agent_type\":\"reviewer\",\"agent_id\":\"agent-1\",\"cwd\":\"$project_dir\"}"
stop_json="{\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"reviewer\",\"agent_id\":\"agent-1\",\"cwd\":\"$project_dir\"}"
prompt_out="$(printf '%s' "$prompt_json" | bash "$FRAMEWORK_DIR/hooks/scripts/workflow-enforcer.sh")"
block_out="$(printf '%s' "{\"cwd\":\"$project_dir\"}" | bash "$FRAMEWORK_DIR/hooks/scripts/stop-review.sh")"
start_out="$(printf '%s' "$start_json" | bash "$FRAMEWORK_DIR/hooks/scripts/subagent-monitor.sh")"
printf '%s' "$stop_json" | bash "$FRAMEWORK_DIR/hooks/scripts/subagent-monitor.sh" >/dev/null
printf '%s\n- Review result: CLEAN\n' >> "$project_dir/.codex/task.md"
allow_out="$(printf '%s' "{\"cwd\":\"$project_dir\"}" | bash "$FRAMEWORK_DIR/hooks/scripts/stop-review.sh")"
if python - "$prompt_out" "$block_out" "$start_out" "$project_dir/.codex/subagent-events.jsonl" "$allow_out" <<'PY'
import json
import sys
prompt, block, start, events_path, allow = sys.argv[1:]
context = json.loads(prompt)["hookSpecificOutput"]["additionalContext"]
assert "Phase: BUILDING | Agents: evidence pending | Model: gpt-5.6-terra/medium | Next gate: agents and review" in context
context = context.replace("Phase:", "Fase:").replace("Agents:", "Agentes:").replace("Model:", "Modelo:").replace("Next gate:", "Pr" + chr(243) + "ximo gate:")
context = context.replace("Pr" + chr(195) + chr(179) + "ximo", "Pr" + chr(243) + "ximo")
assert "Fase: BUILDING | Agentes: evidence pending | Modelo: gpt-5.6-terra/medium | PrÃ³ximo gate: agents and review" in context
assert "Real" not in context
assert "pending-runtime" not in context
assert json.loads(block)["decision"] == "block"
assert "reviewer" in json.loads(start)["hookSpecificOutput"]["additionalContext"]
assert len(open(events_path, encoding="utf-8").read().splitlines()) == 2
assert allow == ""
PY
then
    pass
else
    fail "phase status, native lifecycle evidence, or stop gate did not behave as expected"
fi

test_start "Phase hook reports an undefined model without routing configuration"
empty_project_dir="$(mktemp -d)"
p0p4_register_cleanup "$empty_project_dir"
mkdir -p "$empty_project_dir/.codex"
printf '%s\n' 'Status: DISCOVERING' > "$empty_project_dir/.codex/task.md"
empty_prompt_out="$(printf '%s' "{\"prompt\":\"continue\",\"cwd\":\"$empty_project_dir\"}" | bash "$FRAMEWORK_DIR/hooks/scripts/workflow-enforcer.sh")"
if python - "$empty_prompt_out" <<'PY'
import json
import sys
context = json.loads(sys.argv[1])["hookSpecificOutput"]["additionalContext"]
assert "Model: not defined" in context
context = context.replace("Model: not defined", "Modelo: n" + chr(227) + "o definido")
assert "Modelo: nÃ£o definido" in context
assert "Real" not in context
assert "pending-runtime" not in context
PY
then
    pass
else
    fail "phase hook did not report an undefined model without routing configuration"
fi

p0p4_finish_suite "${BASH_SOURCE[0]}"
