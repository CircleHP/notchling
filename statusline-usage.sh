#!/bin/bash
#
# Claude Code status line that also feeds Notchling's usage bars.
#
# `rate_limits.*` and the per-session context/cost numbers are handed to the status line and to
# nothing else — no hook payload carries them and nothing under ~/.claude caches them — so this
# script is the only way for an outside process to see them.
#
# It prints a useful line rather than nothing, because configuring a status line at all suppresses
# some of Claude Code's footer hints; if a row is going to be spent, it should earn it.
#
# Wire up with:  ./install-hooks.sh statusline <path-to-this-script>
#
set -uo pipefail

input=$(cat)

out_dir="$HOME/.notchling"
out_file="$out_dir/usage.json"
session_dir="$out_dir/sessions"
mkdir -p "$session_dir" 2>/dev/null || true

if command -v jq >/dev/null 2>&1; then
  # Only touch usage.json when this payload actually carries rate limits. Print-mode (`claude -p`)
  # and other headless runs report them as null, and writing that would clobber the last good numbers
  # with nulls — the panel would show nothing at all rather than something marked stale.
  if printf '%s' "$input" \
     | jq -e '(.rate_limits.five_hour.used_percentage // .rate_limits.seven_day.used_percentage) != null' \
       >/dev/null 2>&1; then
    # Write tmp-then-rename so the reader never sees a partial file.
    tmp="$out_file.$$.tmp"
    if printf '%s' "$input" | jq -c '{
          v: 1,
          ts: (now | floor),
          fiveHourUsedPercent: .rate_limits.five_hour.used_percentage,
          fiveHourResetsAt: .rate_limits.five_hour.resets_at,
          sevenDayUsedPercent: .rate_limits.seven_day.used_percentage,
          sevenDayResetsAt: .rate_limits.seven_day.resets_at
        }' > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$out_file" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi

  # --- Per-session metrics ------------------------------------------------------------------
  #
  # One file per session id rather than a shared one, so concurrent sessions cannot race each other.
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
  case "$session_id" in
    # Only ever write a filename made of id-safe characters.
    *[!A-Za-z0-9._-]* | '') ;;
    *)
      stmp="$session_dir/$session_id.json.$$.tmp"
      if printf '%s' "$input" | jq -c '{
            v: 1,
            ts: (now | floor),
            sessionId: .session_id,
            contextUsedPercent: .context_window.used_percentage,
            contextWindowSize: .context_window.context_window_size,
            model: .model.display_name,
            effort: .effort.level,
            linesAdded: .cost.total_lines_added,
            linesRemoved: .cost.total_lines_removed
          }' > "$stmp" 2>/dev/null; then
        mv -f "$stmp" "$session_dir/$session_id.json" 2>/dev/null || rm -f "$stmp"
      else
        rm -f "$stmp"
      fi
      ;;
  esac

  # --- The visible status line -------------------------------------------------------------
  printf '%s' "$input" | jq -r '
    def pct($v): if $v == null then null else ($v | floor) end;
    def bar($used; $width):
      if $used == null then "" else
        (($used / 100 * $width) | floor) as $on
        | "[" + ("█" * $on) + ("·" * ($width - $on)) + "]"
      end;
    def togo($at):
      if $at == null then "" else
        (($at - now) | floor) as $s
        | if $s <= 0 then " now"
          elif $s < 3600 then " \(($s/60)|floor)m"
          else " \(($s/3600)|floor)h\((($s%3600)/60)|floor)m"
          end
      end;

    [ "\(.model.display_name)",
      "\(.workspace.current_dir | split("/") | last)",
      (if .context_window.used_percentage == null then empty
       else "ctx \(.context_window.used_percentage | floor)%" end),
      (if .rate_limits.five_hour.used_percentage == null then empty
       else "5h \(bar(.rate_limits.five_hour.used_percentage; 10)) \(100 - pct(.rate_limits.five_hour.used_percentage))% left ⟳\(togo(.rate_limits.five_hour.resets_at))" end),
      (if .rate_limits.seven_day.used_percentage == null then empty
       else "7d \(100 - pct(.rate_limits.seven_day.used_percentage))%" end)
    ] | join("  ")
  ' 2>/dev/null
else
  printf 'notchling: jq not found'
fi
