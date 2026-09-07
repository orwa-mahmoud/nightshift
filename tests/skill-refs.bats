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
    grep -qF 'skills/nightshift/references/compose/execution-modes.md' "$SKILLS/$s/SKILL.md" \
      || { echo "$s does not name the shared reference"; return 1; }
  done
  [ -f "$SKILLS/nightshift/references/compose/execution-modes.md" ]
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
# A command spelled two or three times over — POSIX, native Windows, a Codex variant — is read in
# full on every host, and the dispatcher resolves the host anyway, so the second spelling is dead
# weight the moment it appears. These hold that.

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
# Explaining every preflight topic in prose makes the model read all of it on every Start. The
# helper explains itself, so what the skill says about a verdict is how to read one — and the two
# rules that are policy rather than mechanics.

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

# Status renders; it does not count.
#
# Half the Status skill was instructions for deriving facts by hand — count the boxes below a
# heading, count drafting-table boxes only after the first rule, subtract the deadline from the
# clock. Every one of those is mechanics, and mechanics belong in the helper.

@test "the Status skill teaches no counting" {
  status="$SKILLS/status/SKILL.md"
  for phrase in 'counted **below the `## Items`' \
    'Count drafting-table boxes only after the first markdown' \
    'compare with `date +%s`' \
    'Count open `- [ ]` boxes in' \
    'the count and one-line titles of entries in' \
    'report the most recent research entry and the counts of'; do
    if grep -qF "$phrase" "$status"; then
      echo "Status still teaches counting: $phrase"
      return 1
    fi
  done

  # What it keeps: the two commands, the rendering rule, and read-only.
  grep -qE 'ns"? status' "$status"
  grep -qE 'ns"? doctor' "$status"
  grep -qF 'Render, never re-derive' "$status"
  grep -qF 'read-only' "$status"
  grep -qF 'Relay every Warning' "$status"
  grep -qF 'reimplement liveness' "$status"
}

@test "every fact Status renders is one the helper prints" {
  helper="$PLUGIN/runtime/status.sh"
  for label in 'open item' 'parked' 'staged' 'snag' 'opportunities' 'deadline' 'stop' \
    'session' 'lease' 'watch reason' 'work mode' 'work target' 'artifact receipts' 'transition'; do
    grep -qF "fact \"$label\"" "$helper" || grep -qF "fact \"$label " "$helper" \
      || { echo "the helper prints no '$label' fact"; return 1; }
  done
}

# One file answers one question for one moment.
#
# A skill loading text for another skill, a later step, or another host pays for it twice: in
# tokens, and in a model holding guidance it can act on by mistake. These hold the split.

@test "every reference pointer in every skill resolves" {
  for f in "$SKILLS"/*/SKILL.md; do
    for ref in $(grep -o 'references/[A-Za-z0-9_./-]*\.md' "$f" | sort -u); do
      case "$ref" in *'<'* | *'*'*) continue ;; esac
      [ -f "$PLUGIN/skills/nightshift/$ref" ] || { echo "$f points at missing $ref"; return 1; }
    done
  done
}

@test "composition text is read by the skills that compose, and by no other" {
  for f in "$SKILLS"/*/SKILL.md; do
    name="$(basename "$(dirname "$f")")"
    case "$name" in hunt | quality | setup) continue ;; esac
    if grep -qF 'references/compose/' "$f"; then
      echo "$name reads composition text while working a shift"
      return 1
    fi
  done
  # And the composing skills still reach it.
  grep -qF 'references/compose/execution-modes.md' "$SKILLS/hunt/SKILL.md"
  grep -qF 'references/compose/execution-modes.md' "$SKILLS/quality/SKILL.md"
  # The working shift reads only the section that is its own.
  grep -qF 'references/shift/direct-mode-decisions.md' "$SKILLS/nightshift/SKILL.md"
}

@test "a skill opens one receipt kind, not the whole set" {
  # The main skill writes baselines and checkpoints and the cited-research report; it has no reason
  # to hold the morning page, the SEO crawl rules or the evidence ledger while doing it.
  for kind in morning seo-live-crawl evidence-ledger continuity-leftovers; do
    if grep -qF "receipts/$kind.md" "$SKILLS/nightshift/SKILL.md"; then
      echo "the main skill opens receipts/$kind.md"
      return 1
    fi
  done
  # Start needs exactly one, for the page it may have to write by hand.
  grep -qF 'receipts/morning.md' "$SKILLS/start/SKILL.md"
}

@test "no reference file repeats a top-level heading" {
  for f in "$PLUGIN"/skills/nightshift/references/*/*.md "$PLUGIN"/skills/nightshift/references/*.md; do
    [ -f "$f" ] || continue
    dupe="$(awk '
      /^```/ { fenced = !fenced }
      !fenced && /^## / { print }
    ' "$f" | sort | uniq -d)"
    [ -z "$dupe" ] || { echo "$f repeats: $dupe"; return 1; }
  done
}

@test "no skill points at a template it only means to copy" {
  for f in "$SKILLS"/*/SKILL.md; do
    if grep -qF 'references/templates/' "$f"; then
      echo "$(basename "$(dirname "$f")") points at a template instead of copying it"
      return 1
    fi
  done
}

# What every session pays for.
#
# The thirteen descriptions are loaded into every session in every project where the plugin is
# installed, shift or not — the only Nightshift text a conversation about something else ever pays
# for. A description's one job is to let the host pick the right skill.

@test "every skill description is one sentence, and the set stays small" {
  total=0
  for f in "$SKILLS"/*/SKILL.md; do
    name="$(basename "$(dirname "$f")")"

    # Exactly one, in the frontmatter, on one line.
    n="$(grep -c '^description:' "$f")"
    [ "$n" -eq 1 ] || { echo "$name has $n description lines"; return 1; }

    text="$(grep -m1 '^description:' "$f" | sed 's/^description: //')"
    [ -n "$text" ] || { echo "$name has an empty description"; return 1; }

    len="${#text}"
    [ "$len" -lt 160 ] || { echo "$name: $len characters"; return 1; }
    case "$text" in
      *.) ;;
      *) echo "$name does not end its sentence"; return 1 ;;
    esac
    # One sentence: no full stop before the last character.
    case "${text%.}" in
      *.\ *) echo "$name is more than one sentence"; return 1 ;;
    esac
    total=$((total + len))
  done

  # Today's set is about 1,300 characters. A ceiling well above that still catches a slide back
  # towards the 2,300 this replaced.
  [ "$total" -lt 1600 ] || { echo "descriptions total $total characters"; return 1; }
}

@test "the main skill keeps the words a host matches intent against" {
  text="$(grep -m1 '^description:' "$SKILLS/nightshift/SKILL.md")"
  for word in 'punch list' 'autonomously' 'overnight' 'todo list' 'polish' 'receipts'; do
    printf '%s\n' "$text" | grep -qF "$word" \
      || { echo "the main skill lost its trigger word: $word"; return 1; }
  done
}

@test "each skill's description says what that skill does" {
  # A description that could belong to another skill cannot help a host choose between them.
  for pair in "start:punch list" "hunt:catalog" "quality:quality debt" "setup:Scaffold" \
    "status:Read-only" "doctor:diagnosis" "archive:archive" "schedule:fixed time" \
    "import-issues:GitHub issues" "stop:stop-work" "reset:markers" "purge:delete"; do
    name="${pair%%:*}"
    phrase="${pair#*:}"
    grep -m1 '^description:' "$SKILLS/$name/SKILL.md" | grep -qF "$phrase" \
      || { echo "$name does not say '$phrase'"; return 1; }
  done
}
