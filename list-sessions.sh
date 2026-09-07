#!/bin/bash
#
# Every agent session on this machine, with a verdict on whether it is something you started or the
# agent's own plumbing — and, where the widget cannot know about a session, what is missing.
#
# The two agents are asked in different ways, because they leave different evidence.
#
# Claude Code keeps a registry, and this cross-checks it against live process argv: the registry alone
# is misleading, because a pooled background spare keeps the *name* of the last job it ran after that
# job has finished, so a completed task can look like an idle background session indefinitely. Same
# distinction as `Session.isPooledSpare`.
#
# Codex keeps no registry at all. There is nothing to enumerate, so this lists the processes and says
# what would have to be true for the widget to see them — which is the question anyone reaching for
# this script about Codex actually has.
#
set -uo pipefail

registry="$HOME/.claude/sessions"
codex_hooks="${CODEX_HOME:-$HOME/.codex}/hooks.json"

command -v jq >/dev/null 2>&1 || { echo "list-sessions: jq is required (brew install jq)" >&2; exit 1; }

claude_sessions() {
if [ ! -d "$registry" ]; then
  echo "no session registry at $registry — is Claude Code installed?"
  return 0
fi

shopt -s nullglob
files=("$registry"/*.json)
if [ ${#files[@]} -eq 0 ]; then
  echo "no Claude sessions running"
  return 0
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
return 0
}

# Codex has no registry, so nothing here is a list of what the widget knows about. It is a list of
# what is running, beside the two facts that decide whether the widget could know: whether our hook
# is in the file, and whether Codex has been told to trust it.
codex_sessions() {
  wired=""
  if [ -f "$codex_hooks" ]; then
    wired=$(jq -r '[.hooks // {} | to_entries[] | .value[]?.hooks[]?.command]
                   | map(select(test("notchling-hook"))) | first // ""' "$codex_hooks" 2>/dev/null)
  fi

  if [ -n "$wired" ]; then
    printf 'hooks wired in %s\n' "$codex_hooks"
    printf 'trust is not visible from here — run /hooks inside Codex to see it\n'
  elif [ -f "$codex_hooks" ]; then
    printf 'hooks NOT wired in %s — no Codex session can appear\n' "$codex_hooks"
    printf 'wire them with `notchling-hooks install --provider codex`\n'
  else
    printf 'no %s — is Codex installed?\n' "$codex_hooks"
  fi

  pids=$(pgrep -x codex 2>/dev/null || true)
  if [ -z "$pids" ]; then
    printf '\nno codex processes running\n'
    return 0
  fi

  printf '\n%-7s %-7s %s\n' PID TTY CWD
  printf '%-7s %-7s %s\n' '-------' '-------' '---'
  count=0
  for pid in $pids; do
    tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    # The widget names a Codex row after its cwd, so this is the name to expect on the panel.
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    printf '%-7s %-7s %s\n' "$pid" "${tty:-none}" "${cwd:-unknown}"
    count=$((count + 1))
  done

  # The distinction that matters, and the one the panel cannot make up for: a session that started
  # before its hooks were trusted emits nothing, so it is invisible however alive it is.
  printf '\n%d codex process(es). Each appears on the panel only from its first trusted hook event,\n' "$count"
  printf 'so one started before the hooks were wired or trusted stays invisible until it is restarted.\n'
  return 0
}

printf 'Claude Code\n'
printf -- '-----------\n'
claude_sessions

printf '\nCodex\n'
printf -- '-----\n'
codex_sessions

exit 0
