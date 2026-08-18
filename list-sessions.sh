#!/bin/bash
#
# Every Claude Code session on this machine, including background ones, with a verdict on whether it
# is something you started or Claude Code's own plumbing.
#
# Cross-checks the registry against live process argv, because the registry alone is misleading: a
# pooled background spare keeps the *name* of the last job it ran after that job has finished, so a
# completed task can look like an idle background session indefinitely. Same distinction as
# `Session.isPooledSpare`.
#
set -uo pipefail

registry="$HOME/.claude/sessions"

command -v jq >/dev/null 2>&1 || { echo "list-sessions: jq is required (brew install jq)" >&2; exit 1; }

if [ ! -d "$registry" ]; then
  echo "no session registry at $registry — is Claude Code installed?"
  exit 0
fi

shopt -s nullglob
files=("$registry"/*.json)
if [ ${#files[@]} -eq 0 ]; then
  echo "no Claude sessions running"
  exit 0
fi

printf '%-30s %-12s %-7s %-7s %-9s %s\n' NAME KIND PID TTY STATUS WHAT
printf '%-30s %-12s %-7s %-7s %-9s %s\n' '------------------------------' '------------' '-------' '-------' '---------' '----'

shown=0
hidden=0

for file in "${files[@]}"; do
  read -r pid kind status name < <(
    jq -r '[.pid, (.kind // "?"), (.status // "?"), (.name // "?")] | @tsv' "$file" 2>/dev/null | tr '\t' ' '
  ) || continue
  [ -n "${pid:-}" ] || continue

  if ! kill -0 "$pid" 2>/dev/null; then
    printf '%-30s %-12s %-7s %-7s %-9s %s\n' "$name" "$kind" "$pid" '-' "$status" 'DEAD — stale registry file'
    hidden=$((hidden + 1))
    continue
  fi

  command=$(ps -o command= -p "$pid" 2>/dev/null)
  tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')

  case "$command" in
    *bg-spare*)     what='pooled spare — hidden by the widget' ; hidden=$((hidden + 1)) ;;
    *bg-pty-host*)  what='pty host — hidden by the widget'     ; hidden=$((hidden + 1)) ;;
    *--session-id*) what='background agent'                    ; shown=$((shown + 1))  ;;
    *)              what='interactive session'                 ; shown=$((shown + 1))  ;;
  esac

  printf '%-30s %-12s %-7s %-7s %-9s %s\n' "$name" "$kind" "$pid" "${tty:-none}" "$status" "$what"
done

printf '\n%d real session(s), %d hidden as plumbing\n' "$shown" "$hidden"

daemon=$(pgrep -f 'claude daemon run' | head -1)
[ -n "$daemon" ] && printf 'background pool supervised by `claude daemon` (pid %s)\n' "$daemon"

exit 0
