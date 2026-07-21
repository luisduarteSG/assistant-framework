#!/usr/bin/env bash
set -euo pipefail
PYTHON_BIN="$(command -v python 2>/dev/null || command -v python3 2>/dev/null || true)"
[[ -n "$PYTHON_BIN" ]] || exit 0
exec "$PYTHON_BIN" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codex-workflow-hooks.py" stop
