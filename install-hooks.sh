#!/bin/bash
#
# Wire (or unwire) the Claude Code hooks that feed Notchling.
#
# Additive and idempotent, deliberately: other tools register hooks on the same events, and replacing
# an event's array instead of appending to it would silently break them.
#
# Usage, with the path optional in every mode — see "Path resolution" below:
#   ./install-hooks.sh setup                                  interactive; asks about all of the below
#   ./install-hooks.sh install       [/path/to/notchling-hook]
#   ./install-hooks.sh uninstall     [/path/to/notchling-hook]
#   ./install-hooks.sh statusline    [/path/to/statusline-usage.sh]
#   ./install-hooks.sh no-statusline
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

# --- Path resolution -------------------------------------------------------------------------
#
# `make` passes an explicit path, and so does anything scripting this. A package-manager install
# cannot: it reaches this script through a symlink that knows neither the prefix it was installed
# under nor where the bundle landed, and the person running it has no reason to know either.
#
# Whatever is resolved here gets written into settings.json as an absolute path, so it has to
# survive an upgrade. A Homebrew upgrade moves the versioned Cellar directory but not `bin` or
# `opt`, which is why neither resolver ever returns a Cellar path: a stale one leaves sessions
# visible through the registry but stuck in idle/working, with nothing on screen to explain why.

brew_prefix() {
  command -v brew >/dev/null 2>&1 || return 1
  brew --prefix 2>/dev/null
}

resolve_hook() {
  if command -v notchling-hook >/dev/null 2>&1; then
    command -v notchling-hook
    return 0
  fi

  prefix=$(brew_prefix) || prefix=""
  if [ -n "$prefix" ] && [ -x "$prefix/bin/notchling-hook" ]; then
    printf '%s\n' "$prefix/bin/notchling-hook"
    return 0
  fi

  if [ -x "$HOME/Applications/Notchling.app/Contents/MacOS/notchling-hook" ]; then
    printf '%s\n' "$HOME/Applications/Notchling.app/Contents/MacOS/notchling-hook"
    return 0
  fi

  return 1
}

resolve_statusline() {
  prefix=$(brew_prefix) || prefix=""
  if [ -n "$prefix" ] && [ -x "$prefix/opt/notchling/Notchling.app/Contents/Resources/statusline-usage.sh" ]; then
    printf '%s\n' "$prefix/opt/notchling/Notchling.app/Contents/Resources/statusline-usage.sh"
    return 0
  fi

  if [ -x "$HOME/Applications/Notchling.app/Contents/Resources/statusline-usage.sh" ]; then
    printf '%s\n' "$HOME/Applications/Notchling.app/Contents/Resources/statusline-usage.sh"
    return 0
  fi

  return 1
}

# --- Setup ------------------------------------------------------------------------------------
#
# One command to run after installing, because the alternative is a package manager printing three
# decisions and two routes and hoping they are read. It asks rather than assumes: a package manager
# may not edit ~/.claude/settings.json on someone's behalf, and neither may this without being told.

confirm() {
  question=$1
  default=$2
  if [ "$default" = "y" ]; then prompt="[Y/n]"; else prompt="[y/N]"; fi
  printf '%s %s ' "$question" "$prompt"
  read -r reply || reply=""
  case "$reply" in
    "")    [ "$default" = "y" ] ;;
    [Yy]*) true ;;
    *)     false ;;
  esac
}

# Hooks from the plugin and hooks in settings.json merge rather than replace, so wiring both reports
# every event twice. Ask Claude Code rather than guessing from files on disk: a marketplace that was
# added but never installed from looks identical to an installed plugin in the directory tree.
plugin_provides_hooks() {
  command -v claude >/dev/null 2>&1 || return 1
  claude plugin list </dev/null 2>/dev/null | grep -qi notchling
}

wired_command() {
  [ -f "$SETTINGS" ] || return 1
  found=$(jq -r '[.hooks // {} | to_entries[] | .value[]?.hooks[]?.command]
                 | map(select(endswith("notchling-hook"))) | first // ""' "$SETTINGS" 2>/dev/null)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

if [ "$MODE" = "setup" ]; then
  # Nothing here may block waiting for an answer that cannot arrive.
  if [ ! -t 0 ]; then
    printf 'install-hooks: setup needs a terminal. Run these instead:\n'
    printf '  notchling-hooks install\n  notchling-hooks statusline   # optional\n'
    exit 0
  fi

  hook=$(resolve_hook) || die "could not find notchling-hook — install the app first"
  printf 'Notchling setup\n\n'

  # 1. Hooks. Without these the widget sees sessions but never learns what they are doing.
  if plugin_provides_hooks; then
    printf '  hooks       provided by the Notchling plugin\n'
    if existing=$(wired_command); then
      printf '\nThe plugin and %s are both wired, so every event is reported twice.\n' "$existing"
      if confirm "Remove the settings.json copy and keep the plugin?" y; then
        "$0" uninstall "$existing"
      fi
    fi
  elif existing=$(wired_command); then
    if [ "$existing" = "$hook" ]; then
      printf '  hooks       already wired to %s\n' "$existing"
    else
      printf '  hooks       wired to %s, which is not the copy just installed\n' "$existing"
      if confirm "Re-point them at $hook?" y; then
        "$0" uninstall "$existing" >/dev/null
        "$0" install "$hook"
      fi
    fi
  else
    printf 'The widget needs Claude Code hooks to see what a session is doing. Wiring them appends to\n'
    printf '%s, backing it up first and leaving other tools alone.\n\n' "$SETTINGS"
    if confirm "Wire them?" y; then
      "$0" install "$hook"
    fi
  fi

  # 2. Status line. Separate because it costs something visible.
  printf '\n'
  current=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null || echo "")
  case "$current" in
    *statusline-usage.sh) printf '  status line already configured\n' ;;
    "")
      printf 'The status line adds plan-usage bars and per-session context, and makes Claude Code drop\n'
      printf 'some of its own footer hints.\n\n'
      if confirm "Add it?" n; then
        "$0" statusline
      fi
      ;;
    *) printf '  status line left alone: %s is configured\n' "$current" ;;
  esac

  # 3. Running. Only offered where it can be honoured; a source install has `make autostart`.
  printf '\n'
  case "$hook" in
    "$(brew_prefix 2>/dev/null)"/*)
      if brew services list </dev/null 2>/dev/null | grep -q "^notchling *started"; then
        printf '  already running, and set to start at login\n'
      elif confirm "Start Notchling now, and at login?" y; then
        brew services start notchling
      fi
      ;;
    *)
      printf '  start it with `make autostart`, or open the app\n'
      ;;
  esac

  printf '\nRestart any Claude sessions that were already running — hooks are read at session start.\n'
  exit 0
fi

# --- Status line -----------------------------------------------------------------------------
#
# A separate mode because it is a separate decision with a visible cost: configuring any status line
# makes Claude Code drop some of its footer hints.
if [ "$MODE" = "statusline" ] && [ -z "$HOOK_COMMAND" ]; then
  HOOK_COMMAND=$(resolve_statusline) \
    || die "could not find statusline-usage.sh — install the app first, or pass its path"
  printf 'install-hooks: using %s\n' "$HOOK_COMMAND"
fi

if [ "$MODE" = "statusline" ] || [ "$MODE" = "no-statusline" ]; then
  SETTINGS_BACKUP="$SETTINGS.notchling-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$(dirname "$SETTINGS")"
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

if [ -z "$HOOK_COMMAND" ]; then
  HOOK_COMMAND=$(resolve_hook) \
    || die "could not find notchling-hook — install the app first, or pass its path"
  printf 'install-hooks: using %s\n' "$HOOK_COMMAND"
fi

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
  die "unknown mode: $MODE (expected setup, install, uninstall, statusline or no-statusline)"
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
