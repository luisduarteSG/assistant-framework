#!/usr/bin/env python3
"""Merge the Assistant Framework Codex hooks without touching user hooks."""

import json
import os
import re
import sys
import tempfile


def as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def is_managed(command, names):
    if not isinstance(command, str):
        return False
    token = re.sub(r"\s+", " ", command.strip()).split(" ", 1)[0]
    return any(token.endswith("/" + name) for name in names)


def main(settings_file, source_settings, hooks_target):
    managed = {"workflow-enforcer.sh", "subagent-monitor.sh", "stop-review.sh"}
    if os.path.exists(settings_file):
        with open(settings_file, encoding="utf-8") as stream:
            existing = json.load(stream)
        if not isinstance(existing, dict) or not isinstance(existing.get("hooks", {}), dict):
            raise ValueError("hooks.json must contain an object with a hooks object")
    else:
        existing = {}

    with open(source_settings, encoding="utf-8") as stream:
        desired = json.load(stream)["hooks"]

    cleaned = {}
    for event, groups in existing.get("hooks", {}).items():
        kept_groups = []
        for group in as_list(groups):
            if not isinstance(group, dict):
                kept_groups.append(group)
                continue
            kept_hooks = [
                hook for hook in as_list(group.get("hooks"))
                if not (isinstance(hook, dict) and is_managed(hook.get("command"), managed))
            ]
            if kept_hooks:
                updated_group = dict(group)
                updated_group["hooks"] = kept_hooks
                kept_groups.append(updated_group)
        if kept_groups:
            cleaned[event] = kept_groups

    for event, groups in desired.items():
        rewritten = []
        for group in groups:
            updated_group = dict(group)
            updated_group["hooks"] = [
                dict(hook, command=hook["command"].replace("$HOME/.codex/hooks/assistant", hooks_target))
                for hook in group["hooks"]
            ]
            rewritten.append(updated_group)
        cleaned[event] = as_list(cleaned.get(event)) + rewritten

    output = dict(existing)
    output["hooks"] = cleaned
    os.makedirs(os.path.dirname(settings_file), exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".assistant-framework-hooks.", dir=os.path.dirname(settings_file), text=True)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(output, stream, indent=2)
        stream.write("\n")
    os.replace(temporary, settings_file)


if __name__ == "__main__":
    main(*sys.argv[1:])
