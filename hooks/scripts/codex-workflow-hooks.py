#!/usr/bin/env python3
"""Portable implementation for the Codex workflow hook entrypoints."""

import json
import os
import re
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path


def project_root(cwd):
    path = Path(cwd or os.getcwd()).resolve()
    try:
        result = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        )
        return Path(result.stdout.strip())
    except (OSError, subprocess.CalledProcessError):
        return path


def task_file(project):
    candidate = project / ".codex" / "task.md"
    return candidate if candidate.is_file() else None


def task_identity(project):
    journal = task_file(project)
    return scalar(journal.read_text(encoding="utf-8"), "Created") if journal else ""


def scalar(text, name):
    prefix = name.lower() + ":"
    for line in text.splitlines():
        normalized = line.lstrip("# -*\t ")
        if normalized.lower().startswith(prefix):
            return normalized.split(":", 1)[1].strip()
    return ""


def roles(text):
    found, in_list = [], False
    for line in text.splitlines():
        lowered = line.lower().strip()
        if lowered == "required agents:":
            in_list = True
            continue
        if lowered.startswith("required agents:"):
            found.extend(part.strip() for part in line.split(":", 1)[1].split(","))
            continue
        if in_list and line.lstrip().startswith("-"):
            found.append(line.lstrip()[1:].strip())
            continue
        if in_list and line and not line.startswith((" ", "\t", "-")):
            in_list = False
    return [role for role in found if any(key in role.lower() for key in ("mapper", "explorer", "architect", "writer", "builder", "reviewer"))]


def requires_gates(text):
    return scalar(text, "Controller intensity").lower() in {"standard", "strict"}


def review_complete(text):
    accepted = {"clean", "pass", "issues_fixed", "complete"}
    return scalar(text, "Review result").lower() in accepted or scalar(text, "Final result").lower() in accepted


def requested_model(text):
    """Return the most recent requested model/reasoning pair recorded in a routing plan."""
    matches = re.findall(
        r'"requested_configuration"\s*:\s*\{[^{}]*"model"\s*:\s*"([^"]+)"[^{}]*"(?:reasoning_effort|reasoning)"\s*:\s*"([^"]+)"[^{}]*\}',
        text,
        flags=re.IGNORECASE,
    )
    if not matches:
        return "not defined"
    model, reasoning = matches[-1]
    return f"{model}/{reasoning}"


def lifecycle_complete(project, required):
    events_path = project / ".codex" / "subagent-events.jsonl"
    if not events_path.is_file():
        return False
    events = [json.loads(line) for line in events_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    current_identity = task_identity(project)
    if not current_identity:
        return False
    events = [event for event in events if event.get("task_created") == current_identity]
    for role in required:
        token = role.lower().replace(" ", "-").replace("/", "-")
        role_events = [event for event in events if token in str(event.get("agent_type", "")).lower()]
        started_ids = {event.get("agent_id") for event in role_events if event.get("event") == "SubagentStart" and event.get("agent_id")}
        stopped_ids = {event.get("agent_id") for event in role_events if event.get("event") == "SubagentStop" and event.get("agent_id")}
        if not started_ids.intersection(stopped_ids):
            return False
    return True


def agent_gate(project, text):
    mode = scalar(text, "Subagent execution mode").lower()
    required = roles(text)
    if not required:
        return True, ""
    if mode == "delegated":
        return lifecycle_complete(project, required), "missing native lifecycle evidence"
    if mode == "direct_fallback":
        for role in required:
            if f"{role.lower()} direct evidence:" not in text.lower():
                return False, f"missing direct fallback evidence for {role}"
        return True, ""
    return False, "missing resolved subagent execution mode"


def emit_context(event, context):
    context = context.replace("Fase:", "Phase:").replace("Agentes:", "Agents:").replace(
        "Pr\u00f3ximo gate:", "Next gate:"
    )
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": context}}))


def prompt(payload):
    if not payload.get("prompt"):
        return
    project = project_root(payload.get("cwd"))
    journal = task_file(project)
    phase, agents, model, gate = "TRIAGE", "not required", "not defined", "triage"
    if journal:
        text = journal.read_text(encoding="utf-8")
        model = requested_model(text)
        if scalar(text, "Status").lower() not in {"complete", "completed", "done", "closed"}:
            phase = scalar(text, "Status") or phase
            if requires_gates(text):
                passed, _ = agent_gate(project, text)
                agents = "evidence complete" if passed else "evidence pending"
                gate = "complete" if passed and review_complete(text) else "agents and review"
    agents = f"{agents} | Modelo solicitado: {model}"
    emit_context("UserPromptSubmit", f"WORKFLOW STATUS (mandatory every prompt): Start your next user-visible reply with exactly: Fase: {phase} | Agentes: {agents} | Next gate: {gate}\nDo not claim that a standard or strict workflow is complete while its native agent evidence or review gate is pending. Keep native dispatch under the orchestrator; this hook only reports and validates evidence.")


def subagent(payload):
    event = payload.get("hook_event_name")
    agent = payload.get("agent_type") or payload.get("agent_name")
    if event not in {"SubagentStart", "SubagentStop"} or not agent:
        return
    project = project_root(payload.get("cwd"))
    state_dir = project / ".codex"
    state_dir.mkdir(parents=True, exist_ok=True)
    record = {key: payload.get(key, "") for key in ("agent_id", "turn_id", "session_id")}
    if identity := task_identity(project):
        record["task_created"] = identity
    record.update({"event": event, "agent_type": agent, "agent_name": agent, "timestamp": datetime.now(UTC).isoformat()})
    for key in ("model", "model_reasoning_effort"):
        if payload.get(key) not in (None, ""):
            record[key] = payload[key]
    with (state_dir / "subagent-events.jsonl").open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(record) + "\n")
    if event == "SubagentStart":
        constraints = {
            "reviewer": "You are a reviewer. Report findings only; do not edit files.",
            "architect": "You are an architect. Design only; do not write implementation code.",
            "explorer": "You are read-only. Inspect and report; do not modify files.",
            "code-mapper": "You are read-only. Inspect and report; do not modify files.",
            "code-writer": "You implement assigned code. Do not run builds or tests.",
            "builder-tester": "You validate and maintain tests. Do not change production code.",
        }
        emit_context("SubagentStart", "SUBAGENT ROLE: " + constraints.get(agent, "Respect the assigned role and return the required evidence."))


def stop(payload):
    project = project_root(payload.get("cwd"))
    journal = task_file(project)
    if not journal:
        return
    text = journal.read_text(encoding="utf-8")
    if not requires_gates(text):
        return
    agents_ok, reason = agent_gate(project, text)
    if not agents_ok:
        print(json.dumps({"decision": "block", "reason": "Workflow agents gate incomplete: " + reason}))
    elif not review_complete(text):
        print(json.dumps({"decision": "block", "reason": "Workflow review gate incomplete: record a CLEAN, PASS, ISSUES_FIXED, or COMPLETE review result before stopping."}))


if __name__ == "__main__":
    payload = json.load(sys.stdin)
    {"prompt": prompt, "subagent": subagent, "stop": stop}[sys.argv[1]](payload)
