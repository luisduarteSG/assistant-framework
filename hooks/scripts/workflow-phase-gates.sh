#!/usr/bin/env bash
# Minimal Codex workflow state and native-subagent evidence helpers.

assistant_phase_scalar_field() {
    local file="$1" label="$2"
    awk -v label="$label" '
        $0 ~ "^(#+[[:space:]]*)?" label ":[[:space:]]*" {
            sub("^(#+[[:space:]]*)?" label ":[[:space:]]*", "", $0)
            print; exit
        }
    ' "$file" 2>/dev/null
}

assistant_phase_status() { assistant_phase_scalar_field "$1" "Status"; }

assistant_phase_intensity() { assistant_phase_scalar_field "$1" "Controller intensity"; }

assistant_phase_execution_mode() { assistant_phase_scalar_field "$1" "Subagent execution mode"; }

assistant_phase_events_file() { printf '%s/subagent-events.jsonl\n' "$(dirname "$1")"; }

assistant_phase_requires_gates() {
    local intensity
    intensity="$(assistant_phase_intensity "$1" | tr '[:upper:]' '[:lower:]')"
    [[ "$intensity" == "standard" || "$intensity" == "strict" ]]
}

assistant_phase_required_roles() {
    local file="$1"
    awk '
        /^Required agents:[[:space:]]*$/ { in_list = 1; next }
        /^Required agents:[[:space:]]*[^[:space:]]/ { print; next }
        in_list && /^[[:space:]]*-[[:space:]]+/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); print; next }
        in_list && /^[^[:space:]-]/ { in_list = 0 }
    ' "$file" 2>/dev/null | while IFS= read -r role; do
        case "$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')" in
            *code*mapper*|*explorer*|*architect*|*code*writer*|*builder*tester*|*reviewer*) printf '%s\n' "$role" ;;
        esac
    done
}

assistant_phase_role_token() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' /' '--'
}

assistant_phase_has_lifecycle_pair() {
    local file="$1" role="$2" token events
    token="$(assistant_phase_role_token "$role")"
    events="$(assistant_phase_events_file "$file")"
    [[ -f "$events" ]] || return 1
    grep -Eiq '"event":"SubagentStart".*"agent_(type|name)":"[^"]*'"$token" "$events" \
        && grep -Eiq '"event":"SubagentStop".*"agent_(type|name)":"[^"]*'"$token" "$events"
}

assistant_phase_has_direct_evidence() {
    local file="$1" role="$2"
    grep -qiE "^[[:space:]]*[-*]?[[:space:]]*${role}[[:space:]]+direct evidence:[[:space:]]*[^[:space:]]" "$file" 2>/dev/null
}

assistant_phase_agents_gate() {
    local file="$1" mode role
    mode="$(assistant_phase_execution_mode "$file" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r role; do
        [[ -n "$role" ]] || continue
        case "$mode" in
            delegated) assistant_phase_has_lifecycle_pair "$file" "$role" || { printf 'missing native lifecycle evidence for %s\n' "$role"; return 1; } ;;
            direct_fallback) assistant_phase_has_direct_evidence "$file" "$role" || { printf 'missing direct fallback evidence for %s\n' "$role"; return 1; } ;;
            *) printf 'missing resolved subagent execution mode\n'; return 1 ;;
        esac
    done < <(assistant_phase_required_roles "$file")
    return 0
}

assistant_phase_review_complete() {
    local file="$1"
    grep -qiE '^[[:space:]]*[-*]?[[:space:]]*(Review result|Final result):[[:space:]]*(CLEAN|PASS|ISSUES_FIXED|COMPLETE)' "$file" 2>/dev/null
}
