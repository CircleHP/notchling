#!/bin/bash
#
# Wire (or unwire) the agent hooks that feed Notchling.
#
# Additive and idempotent, deliberately: other tools register hooks on the same events, and replacing
# an event's array instead of appending to it would silently break them. Entries are always *appended*,
# which matters more under Codex than under Claude Code: Codex keys a hook's trust decision by its
# position in the file (`hooks.json:<event>:<group>:<hook>`), so inserting anywhere but the end
# renumbers other tools' groups and silently invalidates the hashes they were trusted under.
#
# Usage, with the path optional in every mode — see "Path resolution" below:
#   ./install-hooks.sh setup                                  interactive; asks about all of the below
#   ./install-hooks.sh install       [/path/to/notchling-hook] [--provider claude|codex]
#   ./install-hooks.sh uninstall     [/path/to/notchling-hook] [--provider claude|codex]
#   ./install-hooks.sh statusline    [/path/to/statusline-usage.sh] [--chain|--force]
#   ./install-hooks.sh no-statusline
#   ./install-hooks.sh status        [--json]
#
set -euo pipefail

MODE="${1:-}"
HOOK_COMMAND=""
CHAIN_REQUESTED=""
FORCE=""
JSON=""
PROVIDER="claude"
SETTINGS="$HOME/.claude/settings.json"

usage() {
  cat <<'USAGE'
notchling-hooks — wire the Claude Code hooks that feed the Notchling widget

  setup                       ask about hooks, the status line and starting at login
  install       [PATH]        wire the hooks, appending to any already configured
  uninstall     [PATH]        remove only the entries this installed

Both take --provider claude (the default) or --provider codex. Codex keeps its hooks
in $CODEX_HOME/hooks.json, and will not run a newly wired hook until it has been
reviewed and trusted with /hooks inside Codex.
  statusline    [PATH]        add the plan-usage status line
  no-statusline               remove it again, if this installed it
  status        [--json]      what is wired right now, changing nothing

Claude Code has one status line slot. Where another tool already holds it:

  statusline --chain          keep it, and run Notchling in front of it
  statusline --force          replace it

PATH is optional: without one, the hook binary and the status line script are found
through PATH, the Homebrew prefix, or ~/Applications.
USAGE
}

# No mode used to mean `install`, so a bare invocation silently edited settings.json.
case "$MODE" in
  ""|-h|--help|help) usage; exit 0 ;;
esac

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

# Everything after the mode, in any order: one path, and the flags the modes below read.
if [ $# -gt 0 ]; then shift; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --chain) CHAIN_REQUESTED=1 ;;
    --force) FORCE=1 ;;
    --json)  JSON=1 ;;
    --provider)
      [ $# -ge 2 ] || die "--provider needs a value: claude or codex"
      PROVIDER=$2
      shift
      ;;
    --provider=*) PROVIDER=${1#--provider=} ;;
    -*)      die "unknown option: $1" ;;
    *)
      [ -z "$HOOK_COMMAND" ] || die "unexpected argument: $1"
      HOOK_COMMAND=$1
      ;;
  esac
  shift
done

# Swallowing them elsewhere would make `install --force` look like it did something it did not.
if [ "$MODE" != "statusline" ] && [ -n "$CHAIN_REQUESTED$FORCE" ]; then
  die "--chain and --force apply to \`statusline\` only"
fi
case "$PROVIDER" in
  claude|codex) ;;
  *) die "unknown provider: $PROVIDER (expected claude or codex)" ;;
esac

# Claude Code's status line is Claude Code's: no other agent has the slot, and nothing else carries the
# plan limits that reach it.
if [ "$PROVIDER" != "claude" ] && case "$MODE" in statusline|no-statusline) true ;; *) false ;; esac; then
  die "the status line is Claude Code's; --provider does not apply to \`$MODE\`"
fi

if [ "$MODE" != "status" ] && [ -n "$JSON" ]; then
  die "--json applies to \`status\` only"
fi
if [ -n "$CHAIN_REQUESTED" ] && [ -n "$FORCE" ]; then
  die "--chain keeps the status line that is there and --force replaces it; pick one"
fi

# --- What each agent's wiring looks like ------------------------------------------------------
#
# Both files hold the same shape — `{"<Event>": [{"hooks": [{"type": "command", "command": …}]}]}` —
# so the two paths differ by a target, an event list, and a timeout.

HOOK_TIMEOUT=""
HOOK_ARGUMENTS=""

if [ "$PROVIDER" = "codex" ]; then
  # `CODEX_HOME` relocates the whole directory. Read here rather than assumed, because a GUI launched
  # at login does not inherit a terminal's environment and would look somewhere else entirely.
  SETTINGS="${CODEX_HOME:-$HOME/.codex}/hooks.json"

  # Every event the widget consumes. `PostToolUse` is here and deliberately absent from Claude's list:
  # under Codex it is the only signal that a tool finished, and so the only thing that can release a
  # permission prompt — approving one produces no event of its own.
  EVENTS=(
    SessionStart
    UserPromptSubmit
    PreToolUse
    PostToolUse
    PermissionRequest
    SubagentStart
    SubagentStop
    Stop
    Interrupt
    PreCompact
    PostCompact
    SessionEnd
  )

  # Stated rather than left out, and it has to be low. Codex caps `SessionEnd` and `Interrupt` at
  # three seconds and prints a warning on every session start if a hook asks for more — while every
  # other event defaults to *six hundred*, which would let a wedged hook hold a tool call for ten
  # minutes. The hook reads stdin, writes one file and exits.
  HOOK_TIMEOUT=2

  # Nothing in a payload tells the agents apart: Codex names every event they share exactly as Claude
  # Code does, PascalCase and all, and its field names match too. So the hook is told.
  HOOK_ARGUMENTS=" --provider codex"
fi

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

# --- The status line slot --------------------------------------------------------------------
#
# Claude Code has one, and the plan limits reach it and nothing else — no hook payload carries them.
# So a machine that already has a status line has to run both, or go without the bars. That is what
# the chain is for: one small script that reads the payload once, hands a copy to Notchling, and then
# runs whatever was configured before, unchanged and owning the output.

CHAIN="$HOME/.notchling/statusline.sh"
WRAPPED="$HOME/.notchling/statusline-wrapped.sh"
CHAIN_MARKER="notchling-statusline-chain v1"

# `.statusLine.command`, or nothing at all.
#
# Guarded rather than trusted: `.statusLine` is an object where Claude Code wrote it, and a hand-edited
# file where somebody put a bare string there instead would otherwise leave `jq` to fail with its own
# error and no sign of which tool produced it.
statusline_command() {
  jq -r 'if (.statusLine | type) == "object" then (.statusLine.command // "") else "" end' \
    "$SETTINGS" 2>/dev/null || printf ''
}

# What holds the slot: none, ours, a chain of ours, or somebody else's.
#
# Decided by what the command is rather than by where it sits, because two of the four are not paths
# at all. A third-party line is as likely to be a bare name resolved from PATH — `ccstatusline`, an
# nvm shim, is what prompted all of this — as a file, and a chain is wherever it was moved to.
classify_statusline() {
  current=$(statusline_command)
  if [ -z "$current" ]; then
    printf 'none\n'
    return 0
  fi

  # By path first, before any word-splitting, and without asking whether the file is still there.
  # A chain whose files have been deleted is still a chain, and so is one under a `$HOME` with a
  # space in it — and mistaking either for a stranger is not a cosmetic error: chaining then wraps
  # the chain in itself, which loses the command it was wrapping and recurses on every render.
  if [ "$current" = "$CHAIN" ]; then
    printf 'chain\n'
    return 0
  fi

  # Only the first word can name a file, and it does not have to.
  first=${current%% *}
  if [ -f "$first" ] && grep -q "$CHAIN_MARKER" "$first" 2>/dev/null; then
    printf 'chain\n'
    return 0
  fi

  case "$current" in
    *statusline-usage.sh|*statusline-usage.sh\ *) printf 'ours\n' ;;
    *)                                            printf 'foreign\n' ;;
  esac
}

# A chain that has been moved keeps working, because it finds its partner beside itself — so
# everything that reads or rewrites one has to look where it actually is, not where it was written.
adopt_chain_paths() {
  found=$1
  if [ ! -f "$found" ]; then
    # Only split on a space when the first word is itself a chain. The whole string is the intended
    # path far more often — including when it names a file that has simply been deleted — and these
    # two variables are what `remove_chain` deletes: an earlier version split `$HOME/my home/…` and
    # removed two files outside the home directory.
    first=${1%% *}
    if [ -f "$first" ] && grep -q "$CHAIN_MARKER" "$first" 2>/dev/null; then
      found=$first
    else
      return 0
    fi
  fi
  CHAIN=$found
  WRAPPED="${found%/*}/statusline-wrapped.sh"
}

# Deletes the pair, and only when what is there is recognisably ours.
remove_chain() {
  if [ -f "$CHAIN" ] && ! grep -q "$CHAIN_MARKER" "$CHAIN" 2>/dev/null; then
    return 0
  fi
  rm -f "$CHAIN"
  [ ! -f "$WRAPPED" ] || rm -f "$WRAPPED"
}

# The wrapper, and the command it wraps in the file beside it.
#
# Two files rather than one because the command is kept verbatim, and a command embedded in a script
# has to be parsed back out of it to be given back. A file has nothing to parse: whatever is in it is
# what was configured — quotes, `$HOME`, newlines and all.
write_chain() {
  ours=$1
  original=$2

  [ -n "$original" ] || die "there is no status line command to wrap"
  # The one thing that must never happen. A chain wrapping itself loses the command it was written
  # to protect, and recurses until the machine runs out of processes.
  [ "$original" != "$CHAIN" ] || die "refusing to wrap the chain in itself: $CHAIN"
  case "$ours" in
    *"'"*) die "cannot chain from a path containing a quote: $ours" ;;
  esac

  mkdir -p "$(dirname "$CHAIN")"
  printf '%s' "$original" > "$WRAPPED"
  chmod 0755 "$WRAPPED"

  cat > "$CHAIN" <<CHAIN_SCRIPT
#!/bin/bash
# $CHAIN_MARKER
#
# Written by \`notchling-hooks statusline\`. The status line configured before it is in
# statusline-wrapped.sh beside this file, byte for byte as it was, and still prints exactly what it
# printed before; Notchling reads the same payload first and prints nothing at all.
#
# To change your own status line, edit that file. To undo all of this, run
# \`notchling-hooks no-statusline\`, which puts the command back in settings.json and removes both.
#
# Deliberately not \`pipefail\`: a status line that ignores its stdin makes the write below fail, and
# Notchling must not turn a working status line into a failing one.
set -u

payload=\$(cat)

# Guarded, so uninstalling Notchling costs this status line nothing but the bars.
notchling='$ours'
if [ -x "\$notchling" ]; then
  printf '%s' "\$payload" | "\$notchling" >/dev/null 2>&1
fi

# Beside this script rather than by absolute path, so moving the pair together keeps working.
printf '%s' "\$payload" | /bin/bash "\${BASH_SOURCE[0]%/*}/statusline-wrapped.sh"
CHAIN_SCRIPT
  chmod 0755 "$CHAIN"
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
  case "$(classify_statusline)" in
    ours)  printf '  status line already configured\n' ;;
    chain) printf '  status line chained, in front of %s\n' "$(cat "$WRAPPED" 2>/dev/null || printf 'your own')" ;;
    none)
      printf 'The status line adds plan-usage bars and per-session context, and makes Claude Code drop\n'
      printf 'some of its own footer hints.\n\n'
      if confirm "Add it?" n; then
        "$0" statusline
      fi
      ;;
    *)
      printf 'A status line is already configured:\n\n    %s\n\n' "$current"
      printf 'Notchling can run in front of it rather than replace it: it reads the same payload, prints\n'
      printf 'nothing, and yours prints exactly what it prints now. This is what the plan-usage bars and\n'
      printf 'per-session context need, and it makes Claude Code drop some of its own footer hints.\n\n'
      if confirm "Keep it and add Notchling in front?" n; then
        "$0" statusline --chain
      else
        printf '  status line left alone\n'
      fi
      ;;
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

# --- Status ------------------------------------------------------------------------------------
#
# What is wired, changing nothing. `--json` exists because the settings window asks the same question
# and must get the same answer: the rules for what holds the status line slot, and whether the hooks
# are ours, live here and nowhere else. A second copy of them in Swift would drift, and the drift
# would show up as a button that lies about what it is about to do.
if [ "$MODE" = "status" ]; then
  # Nothing is created here, not even an empty settings file. This is the one mode that answers a
  # question rather than changing something, the settings window calls it every time it opens, and
  # every reader below already treats a missing file as an empty one.
  hook=$(resolve_hook 2>/dev/null || printf '')
  wired=$(wired_command || printf '')
  if plugin_provides_hooks; then
    hooks=plugin
  elif [ -z "$wired" ]; then
    hooks=none
  elif [ "$wired" = "$hook" ]; then
    hooks=wired
  else
    # Wired, but to a copy of the hook that is not the one this script resolves — an install that
    # moved, and the case `setup` offers to re-point.
    hooks=elsewhere
  fi

  line=$(classify_statusline)
  current=$(statusline_command)
  [ "$line" != "chain" ] || adopt_chain_paths "$current"
  wrapped=""
  [ "$line" != "chain" ] || wrapped=$(cat "$WRAPPED" 2>/dev/null || printf '')
  script=$(resolve_statusline 2>/dev/null || printf '')

  if [ -n "$JSON" ]; then
    jq -n \
      --arg hooks "$hooks" --arg hookCommand "$wired" --arg hookResolved "$hook" \
      --arg statusLine "$line" --arg statusLineCommand "$current" \
      --arg wrapped "$wrapped" --arg statusLineResolved "$script" \
      '{
        hooks: $hooks, hookCommand: $hookCommand, hookResolved: $hookResolved,
        statusLine: $statusLine, statusLineCommand: $statusLineCommand,
        wrapped: $wrapped, statusLineResolved: $statusLineResolved
      }'
    exit 0
  fi

  case "$hooks" in
    wired)     printf 'hooks         wired to %s\n' "$wired" ;;
    elsewhere) printf 'hooks         wired to %s, which is not the copy found now\n' "$wired" ;;
    plugin)    printf 'hooks         provided by the Notchling plugin\n' ;;
    *)         printf 'hooks         not wired\n' ;;
  esac
  case "$line" in
    ours)    printf 'status line   %s\n' "$current" ;;
    chain)   printf 'status line   Notchling, in front of: %s\n' "$wrapped" ;;
    foreign) printf 'status line   %s — not ours, and not chained\n' "$current" ;;
    *)       printf 'status line   none, so no plan usage or per-session context\n' ;;
  esac
  exit 0
fi

# --- Status line -------------------------------------------------------------------------------
#
# A separate mode because it is a separate decision with a visible cost: configuring any status line
# makes Claude Code drop some of its footer hints.
if [ "$MODE" = "statusline" ] && [ -z "$HOOK_COMMAND" ]; then
  HOOK_COMMAND=$(resolve_statusline) \
    || die "could not find statusline-usage.sh — install the app first, or pass its path"
  printf 'install-hooks: using %s\n' "$HOOK_COMMAND"
fi

if [ "$MODE" = "statusline" ] || [ "$MODE" = "no-statusline" ]; then
  mkdir -p "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON — not touching it"

  # Valid JSON is not the same as a settings file this can reason about. `.statusLine` is an object
  # everywhere Claude Code writes one, and merging into a hand-edited string leaves `jq` to fail with
  # an error naming neither this script nor the file it was reading.
  case "$(jq -r '.statusLine | type' "$SETTINGS" 2>/dev/null || printf 'null')" in
    null|object) ;;
    *) die "$SETTINGS has a .statusLine that is not an object — not touching it" ;;
  esac

  # Everything is decided before anything is written. An earlier version took the backup and the
  # temporary file first, so a run that refused to change a thing still left both of them behind in
  # ~/.claude — the one directory this is supposed to tread carefully in.
  STATE=$(classify_statusline)
  CURRENT=$(statusline_command)
  NEW_COMMAND=""
  SET_INTERVAL=""
  FORCED_OVER=""

  [ "$STATE" != "chain" ] || adopt_chain_paths "$CURRENT"

  if [ "$MODE" = "statusline" ]; then
    [ -n "$HOOK_COMMAND" ] || die "no status line script given"
    [ -x "$HOOK_COMMAND" ] || die "status line script is not executable: $HOOK_COMMAND"

    # `--force` means ours and nothing else, whatever is there — including a chain of our own, which
    # is the one way back out of chaining.
    if [ -n "$FORCE" ] && [ "$STATE" != "ours" ]; then
      NEW_COMMAND=$HOOK_COMMAND
      SET_INTERVAL=1
      FORCED_OVER=$STATE
    else
      case "$STATE" in
        ours)
          # Re-pointed rather than left alone when what is recorded is not what was resolved now.
          # Moving between a clone, ~/Applications and Homebrew otherwise leaves settings.json naming
          # a script that is no longer there, and the bars stop with nothing on screen to say why.
          if [ "$CURRENT" = "$HOOK_COMMAND" ]; then
            printf 'install-hooks: status line already configured\n'
            exit 0
          fi
          printf 'install-hooks: re-pointing from %s\n' "$CURRENT"
          NEW_COMMAND=$HOOK_COMMAND
          SET_INTERVAL=1
          ;;

        # Rewritten rather than left alone: this is what moves an older chain onto a new path to the
        # app, or onto a newer wrapper, and it is why the wrapper carries a version in its marker.
        chain)
          [ -f "$WRAPPED" ] || die "$CURRENT is a Notchling chain, but the status line it was wrapping
  is gone. The newest $SETTINGS.notchling-backup-* still has that command; or run this again with
  --force to keep only Notchling."
          write_chain "$HOOK_COMMAND" "$(cat "$WRAPPED")"
          printf 'install-hooks: chain refreshed at %s\n' "$CHAIN"
          exit 0
          ;;

        foreign)
          if [ -z "$CHAIN_REQUESTED" ]; then
            if [ -t 0 ]; then
              printf 'A status line is already configured:\n\n    %s\n\n' "$CURRENT"
              printf 'There is one slot, and the plan limits reach it and nothing else. Notchling can run in front\n'
              printf 'of yours instead of replacing it: it reads the same payload, prints nothing, and yours prints\n'
              printf 'exactly what it prints now. `notchling-hooks no-statusline` puts it back.\n\n'
              if ! confirm "Keep it and add Notchling in front?" y; then
                printf 'install-hooks: left alone\n'
                exit 0
              fi
            else
              # Refused rather than assumed, because this is somebody else's configuration and nothing
              # here can ask. Both ways out are named, which is what the old message was missing.
              die "a different status line is already configured:
    $CURRENT
  Keep it and run Notchling in front of it with \`notchling-hooks statusline --chain\`, or replace
  it with \`--force\`."
            fi
          fi

          write_chain "$HOOK_COMMAND" "$CURRENT"
          NEW_COMMAND=$CHAIN
          ;;

        none)
          NEW_COMMAND=$HOOK_COMMAND
          SET_INTERVAL=1
          ;;
      esac
    fi
  else
    # Remove only a status line we installed, so `make uninstall` cannot throw away someone else's.
    # Both of the do-nothing answers leave before any file is created, for the same reason the
    # refusal above does.
    case "$STATE" in
      none)
        printf 'install-hooks: no status line configured\n'
        exit 0
        ;;
      foreign)
        printf 'install-hooks: leaving a status line we did not install:\n    %s\n' "$CURRENT"
        exit 0
        ;;
      chain)
        [ -f "$WRAPPED" ] || die "$WRAPPED is gone, so there is nothing to put back.
  The newest $SETTINGS.notchling-backup-* still has the command that was wrapped."
        ;;
    esac
  fi

  SETTINGS_BACKUP="$SETTINGS.notchling-backup-$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$SETTINGS_BACKUP"
  TMP=$(mktemp "$SETTINGS.notchling.XXXXXX")
  trap 'rm -f "$TMP"' EXIT

  if [ "$MODE" = "statusline" ]; then
    # Only `command` is ours to set. Replacing the whole object — which this used to do — takes
    # `padding` and anything else Claude Code learns to keep beside it with it; ccstatusline, the
    # tool that made chaining necessary, merges into what is already there rather than overwriting.
    #
    # `refreshInterval` is set only where there was no status line of somebody else's. It keeps the
    # reset countdown moving while a session sits idle, and imposing it on a line that was already
    # there would change how often that line runs, which is not ours to decide.
    if [ -n "$SET_INTERVAL" ]; then
      jq --arg cmd "$NEW_COMMAND" \
        '.statusLine = ((.statusLine // {}) + {"type": "command", "command": $cmd})
         | (if .statusLine.refreshInterval == null then .statusLine.refreshInterval = 60 else . end)' \
        "$SETTINGS" > "$TMP"
    else
      jq --arg cmd "$NEW_COMMAND" \
        '.statusLine = ((.statusLine // {}) + {"type": "command", "command": $cmd})' \
        "$SETTINGS" > "$TMP"
    fi
  else
    case "$STATE" in
      ours)  jq 'del(.statusLine)' "$SETTINGS" > "$TMP" ;;
      chain) jq --arg cmd "$(cat "$WRAPPED")" '.statusLine.command = $cmd' "$SETTINGS" > "$TMP" ;;
    esac
  fi

  jq empty "$TMP" 2>/dev/null || die "produced invalid JSON (backup: $SETTINGS_BACKUP)"
  mv "$TMP" "$SETTINGS"
  trap - EXIT

  if [ "$MODE" = "statusline" ]; then
    if [ "$NEW_COMMAND" = "$CHAIN" ]; then
      printf 'install-hooks: Notchling now runs in front of your status line\n'
      printf 'install-hooks: yours is kept, unchanged, at %s\n' "$WRAPPED"
    else
      if [ "$FORCED_OVER" = "chain" ]; then
        remove_chain
        printf 'install-hooks: the chain is gone, and with it the status line it was wrapping\n'
      fi
      printf 'install-hooks: status line installed in %s\n' "$SETTINGS"
    fi
  elif [ "$STATE" = "chain" ]; then
    remove_chain
    printf 'install-hooks: your status line is back in %s\n' "$SETTINGS"
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

# Appended after the check, which is about the binary, and before the writes, which are about the
# command. `uninstall` needs the same string to match what `install` wrote.
HOOK_COMMAND="$HOOK_COMMAND$HOOK_ARGUMENTS"

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
          else .hooks[$event] += [{"hooks": [
                 {"type": "command", "command": $cmd}
                 + (if $timeout == null then {} else {"timeout": $timeout} end)
               ]}]
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
  die "unknown mode: $MODE (expected setup, status, install, uninstall, statusline or no-statusline)"
fi

TMP=$(mktemp "$SETTINGS.notchling.XXXXXX")
trap 'rm -f "$TMP"' EXIT

jq --arg cmd "$HOOK_COMMAND" --argjson events "$EVENTS_JSON" \
   --argjson timeout "${HOOK_TIMEOUT:-null}" "$PROGRAM" "$SETTINGS" > "$TMP"

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

if [ "$PROVIDER" = "codex" ]; then
  # Writing the file is not enough and cannot be: Codex will not run a hook until its definition has
  # been reviewed, and the record of that decision is a hash it keeps itself. Writing one here would
  # be forging the answer to a question meant for the person, so it is asked for instead.
  if [ "$MODE" = "install" ]; then
    printf 'install-hooks: run /hooks inside Codex to review and trust these, then start a session\n'
  else
    printf 'install-hooks: start a new Codex session to pick up the change\n'
  fi
else
  printf 'install-hooks: restart any running Claude sessions to pick up the change\n'
fi
