ROOT="$BATS_TEST_DIRNAME/../plugins/nightshift/skills"
REF="$ROOT/nightshift/references"

# The skills that touch state directly carry the map inline. Hunt and Quality read it from
# execution-modes.md, which they are told to open before composing.
@test "active workflow skills carry the same state map" {
  for skill in setup start status archive import-issues doctor; do
    file="$ROOT/$skill/SKILL.md"
    grep -qF 'punch-list.md` → owner-approved work active in this shift' "$file"
    grep -qF 'drafting-table.md` → known work staged for a later shift' "$file"
    grep -qF 'parking-lot.md` → unresolved owner' "$file"
    grep -qF 'work-orders.md` → timed catalog work composed' "$file"
    grep -qF 'only through Hunt' "$file"
  done
  tr '\n' ' ' <"$REF/execution-modes.md" \
    | grep -qF 'punch-list.md` is owner-approved work active in this shift'
  tr '\n' ' ' <"$REF/execution-modes.md" \
    | grep -qF 'drafting-table.md` is known work staged for a later shift'
  for skill in hunt quality; do
    grep -qF 'references/compose/execution-modes.md' "$ROOT/$skill/SKILL.md" \
      || { echo "does not read the state map: $skill"; return 1; }
  done
}

@test "state templates say what belongs and what does not" {
  grep -qF 'Owner-approved active work belongs here' "$REF/punch-list-template.md"
  grep -qF 'known later work' "$REF/drafting-table-template.md"
  grep -qF 'Known tasks and follow-ups do not belong here' "$REF/parking-lot-template.md"
  grep -qF 'composed only through Nightshift: Hunt' "$REF/work-orders-template.md"
}

@test "setup scaffolds the explicit work-order template" {
  grep -qF 'work-orders-template.md' "$ROOT/setup/SKILL.md"
  if grep -qF 'work-orders.md` with a one-line header' "$ROOT/setup/SKILL.md"; then
    return 1
  fi
}

@test "ordinary workflow guidance does not call later work parked" {
  if grep -RqiE 'park(ed|ing)? (known |ordinary )?(work|task|plan)|park(ed|ing)? for later' \
    "$ROOT/nightshift/SKILL.md" "$ROOT/setup/SKILL.md" "$ROOT/start/SKILL.md" \
    "$ROOT/status/SKILL.md" "$ROOT/archive/SKILL.md" "$REF/punch-list-template.md" \
    "$REF/drafting-table-template.md" "$REF/parking-lot-template.md" "$REF/work-orders-template.md"; then
    return 1
  fi
}

@test "routing is described as model guidance, not hook enforcement" {
  grep -qF 'Never route an ordinary plan through Hunt' "$ROOT/nightshift/SKILL.md"
  if grep -RqiE 'hooks? (enforces?|forces?) (the )?(state|routing|classification)' \
    "$ROOT" "$REF"; then
    return 1
  fi
}
