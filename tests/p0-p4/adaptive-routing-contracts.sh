#!/usr/bin/env bash

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
