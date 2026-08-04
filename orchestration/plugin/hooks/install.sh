#!/bin/bash
# === OpenFlows Hook Harness Installer (shared by all role templates) ===
#
# Usage: install.sh <role>   (e.g. "forge-1" — the base role is derived)
#
# Installs the role's hooks from the mounted orchestration volume into
# /home/coder/.openflows/hooks and wires them into the Claude Code agent
# loop via ~/.claude/settings.json. Only events whose scripts exist are
# registered, so this works for every role.
#
# This script is the SINGLE source of truth for hook wiring — role
# workspace templates call it instead of embedding their own copy.
# Failures are non-fatal: a workspace without hooks is degraded, not dead.

set -u

ROLE="${1:-}"
ROLE_BASE="${ROLE%-*}"   # forge-1 -> forge
ORCHESTRATION_DIR="/home/coder/.openflows/orchestration"
HOOKS_SRC="$ORCHESTRATION_DIR/plugin/hooks/$ROLE_BASE"
HOOKS_DIR="/home/coder/.openflows/hooks"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }

if [ -z "$ROLE" ]; then
  log "WARNING: install.sh called without a role — hooks not installed"
  exit 0
fi

if [ -d "$HOOKS_SRC" ]; then
  mkdir -p "$HOOKS_DIR"
  cp -r "$HOOKS_SRC/." "$HOOKS_DIR/"
  chmod +x "$HOOKS_DIR"/*.sh 2>/dev/null || true
  log "Installed $ROLE_BASE hooks from orchestration volume"
else
  log "WARNING: no hooks found for role $ROLE_BASE at $HOOKS_SRC"
fi

if ! command -v python3 >/dev/null 2>&1; then
  log "WARNING: python3 missing — hooks installed but not wired into settings.json"
  exit 0
fi

mkdir -p /home/coder/.claude
python3 - "$HOOKS_DIR" /home/coder/.claude/settings.json <<'PYEOF'
import json, os, sys
hooks_dir, settings_path = sys.argv[1], sys.argv[2]
def cmd(name):
    path = os.path.join(hooks_dir, name)
    return path if os.path.isfile(path) else None
event_map = {
    "SessionStart": [(None, "session_start.sh")],
    "PreToolUse": [("Bash", "pre_bash_guard.sh"),
                    ("Bash", "pre_bash_readonly_guard.sh"),
                    ("Write|Edit|MultiEdit", "pre_write_check.sh")],
    "PostToolUse": [("Write|Edit|MultiEdit", "post_write_lint.sh"),
                     ("Write|Edit|MultiEdit", "post_write_validate.sh")],
    "PreCompact": [(None, "pre_compact_handoff.sh")],
    "Stop": [(None, "stop_require_artifact.sh"),
              (None, "stop_require_eval.sh")],
    "SubagentStop": [(None, "subagent_stop.sh")],
}
hooks = {}
for event, entries in event_map.items():
    matchers = []
    for matcher, script in entries:
        path = cmd(script)
        if not path:
            continue
        entry = {"hooks": [{"type": "command", "command": path}]}
        if matcher:
            entry["matcher"] = matcher
        matchers.append(entry)
    if matchers:
        hooks[event] = matchers
settings = {}
if os.path.exists(settings_path):
    try:
        settings = json.load(open(settings_path))
    except Exception:
        settings = {}
settings["hooks"] = hooks
json.dump(settings, open(settings_path, "w"), indent=2)
print(f"wrote {settings_path} with {len(hooks)} hook events", file=sys.stderr)
PYEOF
