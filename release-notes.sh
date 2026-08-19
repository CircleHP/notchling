#!/bin/bash
#
# Turns the commits between two tags into the body of a GitHub release, grouped by Conventional
# Commit type. Squash merges are what make this work: one commit per pull request, and the pull
# request title — already written as a Conventional Commit — is the subject.
#
# Lenient by design. A subject that does not parse is listed under Other rather than dropped or
# treated as an error: a release must never be held up by a commit message, and a change that
# reached users is worth listing however it was worded.
#
# Called by the release workflow, which needs the full history for it (fetch-depth: 0). Prints to
# stdout, so it can also be run by hand against any pair of tags.
#
# Usage: ./release-notes.sh v1.0.4 [v1.0.3]
set -euo pipefail

TAG="${1:?tag required}"
PREVIOUS="${2:-}"

# GITHUB_REPOSITORY in CI, the remote everywhere else, so the links are right when run by hand.
#
# Validated rather than trusted: an SSH host alias, a mirror or a non-GitHub remote all produce
# something that is not `owner/name`, and a link built from it would be wrong in a way nobody checks.
# Without one the notes still read correctly, they just carry plain numbers instead of links.
REPO="${GITHUB_REPOSITORY:-$(git config --get remote.origin.url | sed -E 's#^.*github\.com[:/]##; s#\.git$##')}"
case "$REPO" in
  */*/*)              REPO="" ;;  # more than one slash: not owner/name
  *[!A-Za-z0-9._/-]*) REPO="" ;;  # a character no owner or repository name contains
  ?*/?*)                       ;;
  *)                  REPO="" ;;
esac

# The tag before this one, and failing that the whole history — which is what the first release
# after adding this wants anyway.
if [ -z "$PREVIOUS" ]; then
  PREVIOUS=$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)
fi
if [ -n "$PREVIOUS" ]; then range="$PREVIOUS..$TAG"; else range="$TAG"; fi

breaking=() added=() fixed=() changed=() other=()

# Held in variables because bash 3.2 — the one macOS ships — cannot parse these inline in `[[ =~ ]]`.
squashed='\(#([0-9]+)\)$'
conventional='^([a-z]+)(\(([^)]+)\))?(!)?:[[:space:]]+(.+)$'

while IFS= read -r subject; do
  # GitHub appends the pull request number when it squashes. Taken off the subject and put back as
  # a link, so the line reads as a sentence.
  pr=""
  if [[ $subject =~ $squashed ]]; then
    pr="${BASH_REMATCH[1]}"
    subject="${subject% (#$pr)}"
  fi

  if [[ $subject =~ $conventional ]]; then
    type="${BASH_REMATCH[1]}"
    scope="${BASH_REMATCH[3]}"
    bang="${BASH_REMATCH[4]}"
    text="${BASH_REMATCH[5]}"
  else
    type=""
    scope=""
    bang=""
    text="$subject"
  fi

  line="- "
  if [ -n "$scope" ]; then line+="**$scope** — "; fi
  line+="$text"
  if [ -n "$pr" ]; then
    if [ -n "$REPO" ]; then
      line+=" ([#$pr](https://github.com/$REPO/pull/$pr))"
    else
      line+=" (#$pr)"
    fi
  fi

  # `feat!:` — the marker for a change that can break an existing install. Listed first and on its
  # own, whatever kind of change it otherwise is, because it is the one thing an upgrade needs read.
  if [ -n "$bang" ]; then
    breaking+=("$line")
    continue
  fi

  case "$type" in
    feat)          added+=("$line") ;;
    fix)           fixed+=("$line") ;;
    perf|refactor) changed+=("$line") ;;
    # Internal work, including the `chore: <version>` bump this release is built on. Nothing here
    # changes what an installed copy does, and listing it buries what does.
    docs|test|build|ci|chore|style) ;;
    *)             other+=("$line") ;;
  esac
done < <(git log --no-merges --format=%s "$range")

# `${a[@]+…}` because an empty array is an unbound variable under `set -u` in bash 3.2, which is
# the bash macOS ships.
section() {
  local title="$1"
  shift
  [ "$#" -gt 0 ] || return 0
  printf '### %s\n\n' "$title"
  printf '%s\n' "$@"
  printf '\n'
}

section "Breaking" ${breaking[@]+"${breaking[@]}"}
section "Added"    ${added[@]+"${added[@]}"}
section "Fixed"    ${fixed[@]+"${fixed[@]}"}
section "Changed"  ${changed[@]+"${changed[@]}"}
section "Other"    ${other[@]+"${other[@]}"}

total=$(( ${#breaking[@]} + ${#added[@]} + ${#fixed[@]} + ${#changed[@]} + ${#other[@]} ))
if [ "$total" -eq 0 ]; then
  printf 'Maintenance only — no change to what the app does.\n\n'
fi

if [ -n "$PREVIOUS" ] && [ -n "$REPO" ]; then
  printf '**Full changelog**: https://github.com/%s/compare/%s...%s\n' "$REPO" "$PREVIOUS" "$TAG"
fi
