#!/usr/bin/env bats
# Planning depth the owner opts into: the plan room and Hunt offer an edge-case pass once, run it
# only on a yes, and keep its method in a reference rather than in the skill text.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
SKILLS="$ROOT/plugins/nightshift/skills"
PLAN="$SKILLS/plan/SKILL.md"
HUNT="$SKILLS/hunt/SKILL.md"
CATALOG="$SKILLS/nightshift/references/plan/edge-cases.md"

# Prose wraps, so read each file as one line.
flat() { tr '\n' ' ' <"$1" | tr -s ' '; }

@test "the plan room offers an edge-case pass once, before capture, and runs it only on a yes" {
  flat "$PLAN" | grep -qF 'Want an edge-case pass on these items before I write them? It adds a few minutes.'
  flat "$PLAN" | grep -qF 'before the capture question'
  flat "$PLAN" | grep -qF 'The default is no, and plain planning stays as fast as it was.'
  flat "$PLAN" | grep -qF 'Only on a yes, read `$NIGHTSHIFT_PLUGIN_ROOT/skills/nightshift/references/plan/edge-cases.md`'
  flat "$PLAN" | grep -qF 'never every case for every item'
  flat "$PLAN" | grep -qF 'only the kept lines reach the drafting table'
  # A declined offer is recorded and not repeated.
  flat "$PLAN" | grep -qF 'Decided: edge-case pass — declined'
  flat "$PLAN" | grep -qF 'do not offer again for that plan'
}

@test "Hunt offers the same pass for the items it composes, never in run directly" {
  flat "$HUNT" | grep -qF 'Offer the edge-case pass the same way, once per compose and never in run directly'
  flat "$HUNT" | grep -qF 'Want an edge-case pass on these items before I write them?'
  flat "$HUNT" | grep -qF 'The default is no.'
  flat "$HUNT" | grep -qF 'references/plan/edge-cases.md'
}

@test "the catalog holds the method and every kind of case, and the skills carry only the offer" {
  for kind in Input State Concurrency Environment Failure Security; do
    grep -qx "## $kind" "$CATALOG" || { echo "catalog lacks $kind"; return 1; }
  done
  for c in Empty Huge Malformed Unicode 'Paths with spaces' 'First run' 'Upgrade from the previous version' \
    'Interrupted halfway' 'Run twice' 'Two sessions' 'A file changed underneath' 'Windows paths' 'No network' \
    'Missing tool' 'Read-only folder' 'Partial failure' Rollback 'The error the user sees' 'Untrusted input' 'Secrets in logs'; do
    grep -qF -- "- **$c**" "$CATALOG" || { echo "catalog lacks $c"; return 1; }
  done
  grep -qF 'Read this only after the owner says yes' "$CATALOG"
  # The case list lives in the reference, not in the skills.
  for f in "$PLAN" "$HUNT"; do
    ! grep -qF 'Paths with spaces' "$f" || { echo "$f carries the catalog"; return 1; }
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
