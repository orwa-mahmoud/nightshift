#!/usr/bin/env bats
# A skill that names a helper which no longer ships is worse than a skill that says nothing: the
# model looks for the file, fails, and improvises. Every backticked path in the composition and
# housekeeping skills must resolve inside the shipped plugin.

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
SKILLS="$PLUGIN/skills"

# Files under .nightshift/ that the owner's workspace holds, not the plugin.
STATE_FILES="punch-list.md drafting-table.md parking-lot.md work-orders.md snag-log.md
shift-log.md shift-report.md product-research.md opportunity-map.md shipped.md"

# Names the references quote in order to forbid them: the model is told these are not Nightshift
# commands and must not look for them. A name here must never become a shipped helper.
NOT_COMMANDS="source-policy-evidence.sh defect-cycle.sh history-context.sh coverage-risk.sh
quality-workflow.sh quality-scan.sh shift-planner.sh shift-preview.sh plan-learning.sh"

# Every path-shaped word inside a backtick span, unquoted and unpunctuated.
backticked_paths() {
  grep -o '`[^`]*`' "$1" \
    | tr -d '`' \
    | tr ' \t' '\n\n' \
    | sed -e 's/^[("'"'"'&]*//' -e 's/[)",;:'"'"']*$//' -e 's/\.$//' \
    | grep -E '\.(sh|ps1|jq|psm1|py|md)$' || true
}

# 0 when the reference resolves (or is not the plugin's to resolve), 1 when it is a dead pointer.
resolves() {
  local ref="$1" rel base n
  for n in $NOT_COMMANDS; do
    [ "$ref" = "$n" ] && return 0
  done
  case "$ref" in
    # A glob, a dated template name, or a bare extension is a shape, not a path.
    *'*'* | *'<'* | .[a-z]*) return 0 ;;
  esac
  ref="$(printf '%s' "$ref" | tr '\\' '/')"
  case "$ref" in
    *'$NIGHTSHIFT_PLUGIN_ROOT'*)
      rel="${ref#*NIGHTSHIFT_PLUGIN_ROOT}"
      [ -e "$PLUGIN/${rel#/}" ] && return 0
      return 1
      ;;
    skills/*|runtime/*|lib/*|hooks/*)
      [ -e "$PLUGIN/$ref" ] && return 0
      return 1
      ;;
    */*|*'$'*)
      # a workspace path, or an expression this test does not own
      return 0
      ;;
  esac

  base="$ref"
  case "$base" in
    *.md)
      for s in $STATE_FILES; do
        [ "$base" = "$s" ] && return 0
      done
      [ -n "$(find "$SKILLS" -name "$base" -print -quit)" ] && return 0
      return 1
      ;;
    *)
      [ -n "$(find "$PLUGIN" -name "$base" -print -quit)" ] && return 0
      return 1
      ;;
  esac
}

# Every skill the plugin ships, plus every reference under it — the 30 shifts included.
# A dead pointer costs the same wherever it is written.
owned_skills() {
  local d
  for d in "$SKILLS"/*/SKILL.md; do
    printf '%s\n' "$d"
  done
  find "$SKILLS/nightshift/references" -name '*.md' -print | LC_ALL=C sort
}

@test "every backticked path in a shipped skill or reference exists" {
  local dead=""
  while read -r f; do
    [ -f "$f" ] || { echo "missing skill file: $f"; return 1; }
    while read -r ref; do
      [ -n "$ref" ] || continue
      resolves "$ref" || dead="$dead
  $(basename "$(dirname "$f")")/$(basename "$f"): $ref"
    done < <(backticked_paths "$f")
  done < <(owned_skills)

  [ -z "$dead" ] || { echo "dead references:$dead"; return 1; }
}

# The removed planners, previews, and pipeline wrappers must not come back as prose.
@test "no shipped skill or reference names a removed helper" {
  local removed="shift-planner.ps1 shift-planner.py shift-preview.ps1 shift-preview.py
plan-learning.py quality-workflow.py compose-discovery history-context.py evidence.py
evidence-baseline.sh evidence-baseline.ps1 evidence-checkpoint.sh evidence-checkpoint.ps1
provision-preflight.sh provision-preflight.ps1"
  while read -r f; do
    for helper in $removed; do
      ! grep -qF "$helper" "$f" \
        || { echo "$f still names $helper"; return 1; }
    done
  done < <(owned_skills)
}

# A name the references forbid must stay unshipped, and must never reappear as an instruction.
@test "a name the references call out as no command ships as nothing" {
  for helper in $NOT_COMMANDS; do
    [ -z "$(find "$PLUGIN" -name "$helper" -print -quit)" ] \
      || { echo "$helper now ships; take it out of NOT_COMMANDS"; return 1; }
    for f in "$SKILLS"/*/SKILL.md; do
      ! grep -qF "$helper" "$f" || { echo "$f names $helper as if it ran"; return 1; }
    done
  done
}

# The reference is loaded by name from both composition skills; a rename there is silent.
@test "the shared execution-modes reference is reachable from both composition skills" {
  for s in hunt quality; do
    grep -qF 'skills/nightshift/references/execution-modes.md' "$SKILLS/$s/SKILL.md" \
      || { echo "$s does not name the shared reference"; return 1; }
  done
  [ -f "$SKILLS/nightshift/references/execution-modes.md" ]
}

# ---------------------------------------------------------------------------
# A documented invocation must be one the helper's own parser accepts. Skills,
# references and public docs are read as instructions: a subcommand or flag the
# parser rejects sends the model looking for a verb that does not exist.

# script_labels FILE — every case label the script's parser accepts.
script_labels() {
  grep -oE '^[[:space:]]*[a-z-][a-zA-Z0-9|_ -]*\)' "$1" | tr -d ' )' | tr '|' '\n' | sort -u
}

# script_flags FILE — every long flag the script's parser accepts.
script_flags() {
  grep -oE '^[[:space:]]*(--[a-zA-Z0-9-]+[[:space:]]*\|[[:space:]]*)*--[a-zA-Z0-9-]+\)' "$1" \
    | tr -d ' )' | tr '|' '\n' | sort -u
}

# named_script TOKEN — the shipped runtime script a token points at, if any.
named_script() {
  local t="$1" base hit
  t="${t%\"}"
  t="${t#\"}"
  base="${t##*/}"
  case "$base" in *.sh) ;; *) return 1 ;; esac
  hit="$(find "$PLUGIN/runtime" -name "$base" -print -quit)"
  [ -n "$hit" ] || return 1
  printf '%s' "$hit"
}

documented_pages() {
  find "$SKILLS" -name '*.md' -print
  find "$ROOT/docs" -name '*.md' -print
  printf '%s\n' "$ROOT/README.md"
}

@test "every helper subcommand and flag named in a skill, reference or doc is one the parser takes" {
  local bad="" f span tok script labels flags skip taken one
  while read -r f; do
    while IFS= read -r span; do
      # shellcheck disable=SC2086
      set -- $span
      script=""
      skip=0
      taken=0
      while [ $# -gt 0 ]; do
        tok="$1"
        shift
        tok="${tok%[]),.]}"
        tok="${tok#[[(]}"
        [ -n "$tok" ] || continue
        if [ -z "$script" ]; then
          script="$(named_script "$tok")" || script=""
          continue
        fi
        case "$tok" in
          --*)
            skip=1
            flags="$(script_flags "$script")"
            [ -z "$flags" ] || printf '%s\n' "$flags" | grep -qxF -e "${tok%%=*}" \
              || bad="$bad
  ${f#"$ROOT/"}: $(basename "$script") ${tok%%=*}"
            continue
            ;;
        esac
        [ "$taken" -eq 0 ] || break
        case "$tok" in
          -*) continue ;;
          \{*\})
            labels="$(script_labels "$script")"
            for one in $(printf '%s' "${tok#\{}" | tr -d '}' | tr '|' ' '); do
              printf '%s\n' "$labels" | grep -qxF "$one" || bad="$bad
  ${f#"$ROOT/"}: $(basename "$script") $one"
            done
            taken=1
            continue
            ;;
        esac
        if [ "$skip" -eq 1 ]; then
          skip=0
          continue
        fi
        case "$tok" in
          [a-z][a-z0-9-][a-z0-9-]*) ;;
          *) continue ;;
        esac
        case "$tok" in *.sh | *.ps1 | *.md | *.json | *.jq) continue ;; esac
        taken=1
        labels="$(script_labels "$script")"
        [ -n "$labels" ] || continue
        printf '%s\n' "$labels" | grep -qxF "$tok" || bad="$bad
  ${f#"$ROOT/"}: $(basename "$script") $tok"
      done
    done < <(grep -o '`[^`]*`' "$f" | tr -d '`' | grep -F '.sh')
  done < <(documented_pages)

  [ -z "$bad" ] || { echo "unknown subcommands or flags:$bad"; return 1; }
}

# One spelling per command.
#
# A skill used to carry each command two or three times — POSIX, native Windows, and a Codex
# variant — and the model read all of them on every host. The dispatcher resolves the host, so a
# second spelling is dead weight the moment it appears. These hold that.

@test "no skill names a helper file: every command is one ns verb" {
  for f in "$SKILLS"/*/SKILL.md; do
    if grep -nE '\$NIGHTSHIFT_PLUGIN_ROOT/runtime/[a-z0-9/-]+\.sh' "$f"; then
      echo "raw POSIX helper path in $f"
      return 1
    fi
    if grep -nE 'runtime.windows.[a-z0-9-]+\.ps1' "$f" | grep -v 'ns\.ps1'; then
      echo "raw Windows helper path in $f"
      return 1
    fi
  done
}

@test "no skill passes --project: the dispatcher resolves the workspace" {
  for f in "$SKILLS"/*/SKILL.md; do
    # Two commands take a path as their subject rather than their location: Setup links a
    # different workspace, and Purge targets the task root so the host link goes with it.
    case "$f" in */setup/SKILL.md | */purge/SKILL.md) continue ;; esac
    if grep -n -- '--project\|-Project ' "$f"; then
      echo "$f still passes the project"
      return 1
    fi
  done
}

@test "the old bind prose is gone from every skill" {
  for f in "$SKILLS"/*/SKILL.md; do
    for phrase in 'Bind once, then never search' \
      'Bind the Nightshift directory once' \
      'capture `pwd -P` before any other shell call' \
      'helpers taking `--project`'; do
      if grep -qF "$phrase" "$f"; then
        echo "$f still carries: $phrase"
        return 1
      fi
    done
  done
}

@test "every ns verb a skill names resolves to a helper that ships" {
  runtime="$PLUGIN/runtime"
  for f in "$SKILLS"/*/SKILL.md; do
    # `ns <verb>` in a command line or in prose, but not the two built-ins.
    for verb in $(grep -oE '(runtime/ns"|`ns) [a-z][a-z0-9-]+' "$f" | awk '{print $2}' | sort -u); do
      case "$verb" in
        bind | help) continue ;;
      esac
      found=no
      for candidate in "$runtime/$verb.sh" "$runtime"/*/"$verb.sh" "$runtime/windows/$verb.ps1"; do
        [ -f "$candidate" ] && found=yes && break
      done
      if [ "$found" = no ]; then
        echo "$f names 'ns $verb', which resolves to no helper"
        return 1
      fi
    done
  done
}

# The explanation lives on the verdict, not in the skill.
#
# Start used to explain every preflight topic in prose, and the model read all of it on every
# Start. The helper explains itself now, so what the skill may still say about a verdict is how to
# read one — and the two rules that are policy rather than mechanics.

@test "Start explains no verdict it did not receive" {
  start="$SKILLS/start/SKILL.md"
  table="$PLUGIN/lib/preflight-explain.txt"

  # Every topic the table explains must be explained THERE, not in the skill. A sentence fragment
  # distinctive to each explanation is enough to catch a copy left behind.
  for phrase in 'Liveness is process evidence' \
    'does not get a silent new budget' \
    'the cross-host handoff fence refused' \
    'the helper clears the leftovers itself' \
    'The work-mode verdicts decide where the work happens' \
    'this host has no reader for it at all'; do
    if grep -qF "$phrase" "$start"; then
      echo "Start still explains a verdict: $phrase"
      return 1
    fi
  done

  # And the table is where they went.
  grep -qF 'Liveness is process evidence' "$table"
  grep -qF 'does not get a silent new budget' "$table"
  grep -qF 'cross-host handoff fence refused' "$table"

  # What stays: how to read a verdict, and the two policy rules.
  grep -qF 'one verdict, and it explains itself' "$start"
  grep -qF 'never invent an explanation the helper did not print' "$start"
  grep -qF 'never kill a live watchman' "$start"
  grep -qF 'never clear `STOP`' "$start"
}
