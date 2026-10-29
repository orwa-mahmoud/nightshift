#!/usr/bin/env bats
# Planning depth the owner opts into: the plan room and Hunt ask one planning-menu question, once,
# run only what the owner picks, and keep each option's method in a reference rather than in the
# skill text.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
SKILLS="$ROOT/plugins/nightshift/skills"
PLAN="$SKILLS/plan/SKILL.md"
HUNT="$SKILLS/hunt/SKILL.md"
MENU="$SKILLS/nightshift/references/plan/menu.md"
CATALOG="$SKILLS/nightshift/references/plan/edge-cases.md"

# Prose wraps, so read each file as one line.
flat() { tr '\n' ' ' <"$1" | tr -s ' '; }

QUESTION='Before I write these, want any of: evidence lines, an edge-case pass, a pre-mortem, an ordering and risk check, or research? The default is none.'

@test "the plan room asks one menu question, once, before capture, and runs only what is picked" {
  flat "$PLAN" | grep -qF "$QUESTION"
  flat "$PLAN" | grep -qF 'before the capture question, ask one question'
  flat "$PLAN" | grep -qF 'Take one answer and do not follow up.'
  # Picking nothing captures the plan exactly as before the menu existed.
  flat "$PLAN" | grep -qF 'With none picked, the plan is captured exactly as it would be without the menu.'
  # Picking some runs those and nothing else.
  flat "$PLAN" | grep -qF 'For the options picked, read `$NIGHTSHIFT_PLUGIN_ROOT/skills/nightshift/references/plan/menu.md` and run only those'
  flat "$MENU" | grep -qF 'run only the options picked'
  # Each choice and its outcome is recorded, and the menu is not offered twice.
  flat "$PLAN" | grep -qF 'Record each choice and its outcome in the plan record (`Decided: planning menu — none`, or one `Decided:` line per option with what was kept)'
  flat "$PLAN" | grep -qF 'do not offer the menu again for that plan'
  # The separate offers are gone: one question, one answer.
  ! flat "$PLAN" | grep -qF 'Want evidence lines suggested' || false
  ! flat "$PLAN" | grep -qF 'Want an edge-case pass on these items' || false
}

@test "Hunt asks the same question for the items it composes, never in run directly" {
  flat "$HUNT" | grep -qF "$QUESTION"
  flat "$HUNT" | grep -qF 'Ask once per compose, never in run directly, and take one answer.'
  flat "$HUNT" | grep -qF 'references/plan/menu.md'
  flat "$HUNT" | grep -qF "goes into tonight's policy under \`receipts.evidence\`"
}

@test "the menu holds each option's method, and the ordering check changes nothing without a yes" {
  for section in Recording 'Evidence lines and shift-wide evidence' 'Edge-case pass' Pre-mortem 'Ordering and risk check' Research; do
    grep -qx "## $section" "$MENU" || { echo "menu lacks $section"; return 1; }
  done
  flat "$MENU" | grep -qF 'Ask: "This shipped and failed a week later: why?"'
  flat "$MENU" | grep -qF 'a WHEN/THEN line on the item it would break'
  flat "$MENU" | grep -qF 'a new item, when no drafted item owns the fix'
  flat "$MENU" | grep -qF 'a non-goal in the plan, when the owner accepts the risk'
  flat "$MENU" | grep -qF 'Name the item whose failure would break the most others'
  flat "$MENU" | grep -qF 'move it first'
  flat "$MENU" | grep -qF 'add a checkpoint item right after it'
  flat "$MENU" | grep -qF "Change the order or add the item only on the owner's yes."
  flat "$MENU" | grep -qF 'Follow `shift/cited-research.md`'
  flat "$MENU" | grep -qF 'in its `Design notes:` line'
  # Every reference the menu names exists.
  for ref in evidence/catalog.md plan/edge-cases.md shift/cited-research.md; do
    flat "$MENU" | grep -qF "\`$ref\`" || { echo "menu does not name $ref"; return 1; }
    [ -f "$SKILLS/nightshift/references/$ref" ] || { echo "missing $ref"; return 1; }
  done
}

@test "the edge-case catalog holds every kind of case, and the skills carry only the question" {
  for kind in Input State Concurrency Environment Failure Security; do
    grep -qx "## $kind" "$CATALOG" || { echo "catalog lacks $kind"; return 1; }
  done
  for c in Empty Huge Malformed Unicode 'Paths with spaces' 'First run' 'Upgrade from the previous version' \
    'Interrupted halfway' 'Run twice' 'Two sessions' 'A file changed underneath' 'Windows paths' 'No network' \
    'Missing tool' 'Read-only folder' 'Partial failure' Rollback 'The error the user sees' 'Untrusted input' 'Secrets in logs'; do
    grep -qF -- "- **$c**" "$CATALOG" || { echo "catalog lacks $c"; return 1; }
  done
  flat "$MENU" | grep -qF 'Read `plan/edge-cases.md` and propose WHEN/THEN lines for the cases each item can meet.'
  flat "$CATALOG" | grep -qF 'never every case for every item'
  for f in "$PLAN" "$HUNT"; do
    ! grep -qF 'Paths with spaces' "$f" || { echo "$f carries the catalog"; return 1; }
    ! grep -qF 'failed a week later' "$f" || { echo "$f carries the pre-mortem method"; return 1; }
  done
}

@test "every reference the plan and hunt skills cite exists" {
  for f in "$PLAN" "$HUNT"; do
    for ref in $(grep -o 'references/[A-Za-z0-9_./-]*\.md' "$f" | sort -u); do
      [ -f "$SKILLS/nightshift/$ref" ] || { echo "$f cites missing $ref"; return 1; }
    done
  done
  grep -qF -- '- `plan/`' "$SKILLS/nightshift/references/README.md"
}

@test "the skill size budgets still hold" {
  run bash "$ROOT/evals/validate.sh"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20; return 1; }
}
