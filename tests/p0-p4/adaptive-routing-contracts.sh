#!/usr/bin/env bash

if [[ -z "${P0P4_HARNESS_LOADED:-}" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/p0p4-harness.sh"
fi
p0p4_bootstrap_suite "${BASH_SOURCE[0]}"

toml_has_single_exact_value() {
    local toml_file="$1"
    local key="$2"
    local expected_value="$3"

    awk -v key="$key" -v expected_value="$expected_value" '
        /^[[:space:]]*#/ { next }
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            value = $0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            sub(/[[:space:]]*#.*/, "", value)
            sub(/[[:space:]]+$/, "", value)

            if (value == "\"" expected_value "\"") {
                matching_keys++
            } else {
                invalid_key_value = 1
            }
        }
        END { exit !(matching_keys == 1 && !invalid_key_value) }
    ' "$toml_file"
}

test_start "adaptive Codex install applies routing defaults, preserves unrelated content, and remains idempotent"
ADAPTIVE_ROUTING_HOME="$(mktemp -d)"
p0p4_register_cleanup "$ADAPTIVE_ROUTING_HOME"
mkdir -p "$ADAPTIVE_ROUTING_HOME/.codex"
cat > "$ADAPTIVE_ROUTING_HOME/.codex/config.toml" <<'CONFIG'
model = "gpt-5.6-sol"
model_reasoning_effort = "high"

[mcp_servers.keep]
command = "/tmp/keep"
CONFIG
cat > "$ADAPTIVE_ROUTING_HOME/.codex/AGENTS.md" <<'AGENTS'
# Global Codex Guidance

Complete tasks correctly with the lowest reasonable cost, latency, and context usage.

Use the cheapest agent likely to complete the task reliably.

Use the lowest sufficient reasoning effort:

Keep this user-owned instruction exactly.
AGENTS

if HOME="$ADAPTIVE_ROUTING_HOME" bash "$FRAMEWORK_DIR/install.sh" --agent codex --skill assistant-workflow --adaptive-routing >/tmp/p0p4-adaptive-routing-1.out 2>/tmp/p0p4-adaptive-routing-1.err; then
    stale_installed_file="$ADAPTIVE_ROUTING_HOME/.codex/skills/assistant-workflow/stale-installed-file.txt"
    touch "$stale_installed_file"
    if ! HOME="$ADAPTIVE_ROUTING_HOME" bash "$FRAMEWORK_DIR/install.sh" --agent codex --skill assistant-workflow --adaptive-routing >/tmp/p0p4-adaptive-routing-2.out 2>/tmp/p0p4-adaptive-routing-2.err; then
        fail "second adaptive Codex install failed; see /tmp/p0p4-adaptive-routing-2.err"
    else
    config_file="$ADAPTIVE_ROUTING_HOME/.codex/config.toml"
    agents_file="$ADAPTIVE_ROUTING_HOME/.codex/AGENTS.md"
    if ! grep -Fq 'model = "gpt-5.6-terra"' "$config_file" \
        || ! grep -Fq 'model_reasoning_effort = "medium"' "$config_file" \
        || ! grep -Fq '[mcp_servers.keep]' "$config_file" \
        || ! grep -Fq 'Keep this user-owned instruction exactly.' "$agents_file" \
        || grep -Fq 'lowest reasonable cost' "$agents_file" \
        || grep -Fq 'Use the cheapest agent' "$agents_file" \
        || [[ ! -f "${config_file}.assistant-framework-adaptive-routing.bak" ]] \
        || [[ ! -f "${agents_file}.assistant-framework-adaptive-routing.bak" ]] \
        || [[ -e "$stale_installed_file" ]] \
        || [[ "$(grep -c 'ASSISTANT_FRAMEWORK_AGENTS_MD_START' "$agents_file")" != "1" ]]; then
        fail "adaptive Codex install did not safely apply or preserve the expected routing migration"
    else
        pass
    fi
    fi
else
    fail "first adaptive Codex install failed; see /tmp/p0p4-adaptive-routing-1.err"
fi

test_start "Codex agent baselines select the declared model and reasoning defaults"
adaptive_agent_failures=()
for expectation in \
    'luna:gpt-5.6-luna:medium' \
    'terra:gpt-5.6-terra:medium' \
    'sol:gpt-5.6-sol:high' \
    'code-mapper:gpt-5.6-luna:medium' \
    'explorer:gpt-5.6-terra:high' \
    'architect:gpt-5.6-sol:high' \
    'code-writer:gpt-5.6-terra:medium' \
    'builder-tester:gpt-5.6-terra:medium' \
    'code-reviewer:gpt-5.6-sol:high' \
    'reviewer:gpt-5.6-sol:high' \
    'qa-evaluator:gpt-5.6-sol:high'; do
    IFS=':' read -r role model reasoning <<< "$expectation"
    file="$FRAMEWORK_DIR/agents/codex/$role.toml"
    if [[ ! -f "$file" ]] || ! grep -Fq "model = \"$model\"" "$file" || ! grep -Fq "model_reasoning_effort = \"$reasoning\"" "$file"; then
        adaptive_agent_failures+=("$role baseline")
    fi
done
if [[ "${#adaptive_agent_failures[@]}" -eq 0 ]]; then
    pass
else
    fail "missing adaptive agent baselines: ${adaptive_agent_failures[*]}"
fi

test_start "Codex adaptive routing profiles match declared maps, sandbox contracts, and installed aliases"
adaptive_profile_failures=()
for expectation in \
    'code-mapper-fast:gpt-5.6-luna:low:read-only' \
    'explorer-frontier:gpt-5.6-sol:high:read-only' \
    'code-writer-frontier:gpt-5.6-sol:high:workspace-write' \
    'builder-tester-frontier:gpt-5.6-sol:high:workspace-write'; do
    IFS=':' read -r role model reasoning sandbox <<< "$expectation"
    file="$FRAMEWORK_DIR/agents/codex/$role.toml"
    installed_file="$ADAPTIVE_ROUTING_HOME/.codex/agents/$role.toml"
    if [[ ! -f "$file" ]] \
        || ! toml_has_single_exact_value "$file" name "$role" \
        || ! toml_has_single_exact_value "$file" model "$model" \
        || ! toml_has_single_exact_value "$file" model_reasoning_effort "$reasoning" \
        || ! toml_has_single_exact_value "$file" sandbox_mode "$sandbox"; then
        adaptive_profile_failures+=("$role map or sandbox")
    fi
    if [[ ! -f "$installed_file" ]] \
        || ! toml_has_single_exact_value "$installed_file" name "$role" \
        || ! toml_has_single_exact_value "$installed_file" model "$model" \
        || ! toml_has_single_exact_value "$installed_file" model_reasoning_effort "$reasoning" \
        || ! toml_has_single_exact_value "$installed_file" sandbox_mode "$sandbox" \
        || ! cmp -s "$file" "$installed_file"; then
        adaptive_profile_failures+=("$role installed alias")
    fi
done
if [[ "${#adaptive_profile_failures[@]}" -eq 0 ]]; then
    pass
else
    fail "invalid adaptive routing profiles: ${adaptive_profile_failures[*]}"
fi

test_start "canonical Route policy rows match every selected Codex TOML profile"
if python - "$FRAMEWORK_DIR" <<'PY'
import re
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
policy = (root / "skills/assistant-workflow/references/subagent-dispatch.md").read_text(encoding="utf-8")
section = policy.split("### Route policy (canonical)", 1)[1].split("###", 1)[0]
rows = re.findall(
    r"^\| `([^`]+)` \| `([^`]+)` \| `([^`]+)` / `([^`]+)` \|",
    section,
    flags=re.MULTILINE,
)
assert rows, "canonical Route policy table has no parseable rows"
expected_route_ids = {
    "map_fast",
    "discover_balanced",
    "discover_frontier",
    "implement_balanced",
    "implement_frontier",
    "verify_balanced",
    "verify_frontier",
    "design_frontier",
    "review_frontier",
    "qa_frontier",
}
route_ids = [route_id for route_id, _, _, _ in rows]
assert len(route_ids) == len(expected_route_ids), f"expected {len(expected_route_ids)} canonical routes, found {len(route_ids)}"
assert len(set(route_ids)) == len(route_ids), "canonical Route policy contains duplicate route IDs"
assert set(route_ids) == expected_route_ids, f"canonical Route policy route IDs differ: {sorted(set(route_ids) ^ expected_route_ids)}"
for route_id, agent_name, model, reasoning in rows:
    profile_path = root / "agents/codex" / f"{agent_name}.toml"
    assert profile_path.is_file(), f"{route_id}: missing profile {profile_path.name}"
    with profile_path.open("rb") as stream:
        profile = tomllib.load(stream)
    assert profile.get("name") == agent_name, f"{route_id}: profile name mismatch"
    assert profile.get("model") == model, f"{route_id}: model mismatch"
    assert profile.get("model_reasoning_effort") == reasoning, f"{route_id}: reasoning mismatch"
PY
then
    pass
else
    fail "canonical Route policy rows must match every selected Codex TOML profile"
fi

p0p4_finish_suite "${BASH_SOURCE[0]}"
