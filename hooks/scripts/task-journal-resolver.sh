#!/usr/bin/env bash
# Shared resolver for the Codex-only workflow hooks.

assistant_resolve_project_dir() {
    local candidate="${1:-$(pwd)}"
    if command -v git >/dev/null 2>&1; then
        git -C "$candidate" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$candidate"
    else
        printf '%s\n' "$candidate"
    fi
}

assistant_find_task_journal() {
    local project_dir="$1"
    local current_dir="${2:-$project_dir}"
    local candidate

    while [[ "$current_dir" == "$project_dir" || "$current_dir" == "$project_dir"/* ]]; do
        candidate="$current_dir/.codex/task.md"
        [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
        [[ "$current_dir" == "$project_dir" ]] && break
        current_dir="$(dirname "$current_dir")"
    done

    candidate="$project_dir/.codex/task.md"
    [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    return 1
}

assistant_task_journal_completed() {
    local task_file="$1"
    grep -qiE '^(Status|Phase):[[:space:]]*(COMPLETE|COMPLETED|DONE|CLOSED)' "$task_file" 2>/dev/null
}
