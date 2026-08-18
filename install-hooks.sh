#!/bin/bash
#
# Wire (or unwire) the Claude Code hooks that feed Notchling.
#
# Additive and idempotent, deliberately: other tools register hooks on the same events, and replacing
# an event's array instead of appending to it would silently break them.
#
# Usage:
#   ./install-hooks.sh install       /path/to/notchling-hook
#   ./install-hooks.sh uninstall     /path/to/notchling-hook
#   ./install-hooks.sh statusline    /path/to/statusline-usage.sh
#   ./install-hooks.sh no-statusline ""
#
set -euo pipefail

MODE="${1:-install}"
HOOK_COMMAND="${2:-}"
SETTINGS="$HOME/.claude/settings.json"

# PostToolUse is deliberately absent: its payload carries `tool_output`, which can be megabytes,
# and PreToolUse already tells the widget which tool is running.
EVENTS=(
  SessionStart
  UserPromptSubmit
  PreToolUse
  Notification
  SubagentStart
  SubagentStop
  Stop
  StopFailure
  PostToolUseFailure
  SessionEnd
)

die() { printf 'install-hooks: %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

# --- Status line -----------------------------------------------------------------------------
#
# A separate mode because it is a separate decision with a visible cost: configuring any status line
# makes Claude Code drop some of its footer hints.
if [ "$MODE" = "statusline" ] || [ "$MODE" = "no-statusline" ]; then
  SETTINGS_BACKUP="$SETTINGS.notchling-backup-$(date +%Y%m%d%H%M%S)"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON — not touching it"
  cp "$SETTINGS" "$SETTINGS_BACKUP"
  TMP=$(mktemp "$SETTINGS.notchling.XXXXXX")

  if [ "$MODE" = "statusline" ]; then
    [ -n "$HOOK_COMMAND" ] || die "no status line script given"
    [ -x "$HOOK_COMMAND" ] || die "status line script is not executable: $HOOK_COMMAND"
    existing=$(jq -r '.statusLine.command // ""' "$SETTINGS")
    case "$existing" in
      ""|*statusline-usage.sh) ;;
      *) die "a different status line is already configured:
    $existing
  Refusing to replace it. Merge the two by hand, or move yours aside first." ;;
    esac
    # refreshInterval keeps the reset countdown and the freshness stamp moving while a session sits
    # idle; without it the line only re-runs on events.
    jq --arg cmd "$HOOK_COMMAND" \
      '.statusLine = {"type": "command", "command": $cmd, "refreshInterval": 60}' \
      "$SETTINGS" > "$TMP"
  else
    # Remove only a status line we installed, so `make uninstall` cannot throw away someone else's.
    existing=$(jq -r '.statusLine.command // ""' "$SETTINGS")
    case "$existing" in
      *statusline-usage.sh) jq 'del(.statusLine)' "$SETTINGS" > "$TMP" ;;
      "")                   cp "$SETTINGS" "$TMP" ;;
      *)                    rm -f "$TMP"
                            printf 'install-hooks: leaving a status line we did not install:\n    %s\n' "$existing"
                            exit 0 ;;
    esac
  fi

  jq empty "$TMP" 2>/dev/null || { rm -f "$TMP"; die "produced invalid JSON (backup: $SETTINGS_BACKUP)"; }
  mv "$TMP" "$SETTINGS"
  if [ "$MODE" = "statusline" ]; then
    printf 'install-hooks: status line installed in %s\n' "$SETTINGS"
  else
    printf 'install-hooks: status line removed from %s\n' "$SETTINGS"
  fi
  printf 'install-hooks: backup at %s\n' "$SETTINGS_BACKUP"
  exit 0
fi

[ -n "$HOOK_COMMAND" ] || die "no hook command given"

if [ "$MODE" = "install" ] && [ ! -x "$HOOK_COMMAND" ]; then
  die "hook binary is not executable: $HOOK_COMMAND"
fi

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Refuse to touch a settings file we cannot parse, rather than replacing it with our idea of it.
jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON — not touching it"

BACKUP="$SETTINGS.notchling-backup-$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"

EVENTS_JSON=$(printf '%s\n' "${EVENTS[@]}" | jq -R . | jq -s .)

if [ "$MODE" = "install" ]; then
  PROGRAM='
    .hooks //= {}
    | reduce $events[] as $event (.;
        .hooks[$event] //= []
        | if any(.hooks[$event][]?; any(.hooks[]?; .command == $cmd))
          then .
          else .hooks[$event] += [{"hooks": [{"type": "command", "command": $cmd}]}]
          end
      )
  '
elif [ "$MODE" = "uninstall" ]; then
  # Drop only our own entries, and only the groups that become empty as a result.
  PROGRAM='
    if .hooks == null then . else
      reduce $events[] as $event (.;
        if .hooks[$event] == null then . else
          .hooks[$event] = [
            .hooks[$event][]
            | .hooks = [.hooks[]? | select(.command != $cmd)]
            | select((.hooks | length) > 0)
          ]
          | if (.hooks[$event] | length) == 0 then del(.hooks[$event]) else . end
        end
      )
    end
  '
else
  die "unknown mode: $MODE (expected install, uninstall, statusline or no-statusline)"
fi

TMP=$(mktemp "$SETTINGS.notchling.XXXXXX")
trap 'rm -f "$TMP"' EXIT

jq --arg cmd "$HOOK_COMMAND" --argjson events "$EVENTS_JSON" "$PROGRAM" "$SETTINGS" > "$TMP"

# Sanity-check the result before it replaces a file that controls how every session behaves.
jq empty "$TMP" 2>/dev/null || die "produced invalid JSON — left $SETTINGS untouched (backup: $BACKUP)"

if [ "$MODE" = "install" ]; then
  for event in "${EVENTS[@]}"; do
    found=$(jq --arg cmd "$HOOK_COMMAND" --arg event "$event" \
      '[.hooks[$event][]? | .hooks[]? | select(.command == $cmd)] | length' "$TMP")
    [ "$found" = "1" ] || die "expected exactly 1 entry for $event, got $found (backup: $BACKUP)"
  done
fi

mv "$TMP" "$SETTINGS"
trap - EXIT

printf 'install-hooks: %sed %d events in %s\n' "$MODE" "${#EVENTS[@]}" "$SETTINGS"
printf 'install-hooks: backup at %s\n' "$BACKUP"
printf 'install-hooks: restart any running Claude sessions to pick up the change\n'
