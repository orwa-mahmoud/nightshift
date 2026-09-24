ROOT="$BATS_TEST_DIRNAME/../plugins/nightshift/skills"
REF="$ROOT/nightshift/references"

# The state map is one reference file. The skills that touch state directly point at it; Hunt and
# Quality read it from execution-modes.md, which they are told to open before composing.
@test "the state map has one copy per audience, and they agree" {
  # The map is one file. A skill that promotes, stages or files these four points at it; a shift
  # reads its own list once from the main skill, and composition reads the file it is told to open.
  map="$REF/shift/state-map.md"
  grep -qF 'punch-list.md` → owner-approved work active in this shift' "$map"
  grep -qF 'drafting-table.md` → known work the owner stages for a later shift' "$map"
  grep -qF 'parking-lot.md` → unresolved owner' "$map"
  grep -qF 'work-orders.md` → timed catalog work composed' "$map"
  grep -qF 'only through Hunt' "$map"
  for skill in setup archive import-issues doctor; do
    file="$ROOT/$skill/SKILL.md"
    grep -qF 'references/shift/state-map.md' "$file" || { echo "$skill does not point at the state map"; return 1; }
    ! grep -qF 'owner-approved work active in this shift' "$file" || { echo "$skill repeats the state map"; return 1; }
  done

  # The one copy a working shift reads names the same four files.
  main="$ROOT/nightshift/SKILL.md"
  grep -qF 'What the owner reads in the morning' "$main"
  for f in punch-list drafting-table parking-lot work-orders; do
    grep -qF "$f.md" "$main" || { echo "the main skill's list omits $f.md"; return 1; }
  done

  # Start and Status render what the runtime tells them; neither repeats the map.
  for skill in start status; do
    if grep -qF 'owner-approved work active in this shift' "$ROOT/$skill/SKILL.md"; then
      echo "$skill repeats the state map"
      return 1
    fi
  done
  tr '\n' ' ' <"$REF/compose/execution-modes.md" \
    | grep -qF 'punch-list.md` is owner-approved work active in this shift'
  tr '\n' ' ' <"$REF/compose/execution-modes.md" \
    | grep -qF 'drafting-table.md` is known work staged for a later shift'
  for skill in hunt quality; do
    grep -qF 'references/compose/execution-modes.md' "$ROOT/$skill/SKILL.md" \
      || { echo "does not read the state map: $skill"; return 1; }
  done
}

@test "state templates say what belongs and what does not" {
  grep -qF 'Owner-approved active work belongs here' "$REF/templates/punch-list.md"
  grep -qF 'known later work' "$REF/templates/drafting-table.md"
  grep -qF 'Known tasks do not belong here' "$REF/templates/parking-lot.md"
  grep -qF 'composed only through Nightshift: Hunt' "$REF/templates/work-orders.md"
}

@test "the work-order file is scaffolded from its template, not written by hand" {
  # Hunt runs the scaffold for it the first time it stages an order.
  grep -qE 'ns"? scaffold' "$ROOT/setup/SKILL.md"
  grep -qF 'ns" scaffold work-orders' "$ROOT/hunt/SKILL.md"
  [ -f "$REF/templates/work-orders.md" ]
  if grep -qF 'work-orders.md` with a one-line header' "$ROOT/setup/SKILL.md"; then
    return 1
  fi
}

@test "only the owner puts work on the drafting table, and a bug is fixed on the shift that found it" {
  grep -qF "The drafting
table is the owner's: write it only when the owner asks for it" "$ROOT/nightshift/SKILL.md"
  grep -qF 'record it in
`$NS/inbox/snag-log.md` with the fix as its disposition' "$ROOT/nightshift/SKILL.md"
  grep -qF '| `staging/drafting-table.md` | The owner; the agent only when the owner asks' "$REF/shift/state-map.md"
  if grep -qF 'Owner, the agent, Import issues' "$REF/shift/state-map.md"; then return 1; fi
  for t in punch-list drafting-table snag-log parking-lot; do
    tr '\n' ' ' <"$REF/templates/$t.md" | tr -s ' >' ' ' | grep -qF 'fixed on' \
      || { echo "$t.md does not say a bug is fixed on the shift that found it"; return 1; }
  done
  # No skill or catalog shift sends a finding or a follow-up to the drafting table on its own.
  if grep -RniE '(stage|park|append|record|put|move)[^.]*drafting-table\.md' \
    "$REF/compose/shifts" "$ROOT/nightshift/SKILL.md" "$ROOT/hunt/SKILL.md" "$ROOT/start/SKILL.md"; then
    return 1
  fi
  # The owner's own requests still write it.
  grep -qF 'draft for later' "$ROOT/quality/SKILL.md"
  grep -qF 'drafting-table.md' "$ROOT/import-issues/SKILL.md"
}

@test "ordinary workflow guidance does not call later work parked" {
  if grep -RqiE 'park(ed|ing)? (known |ordinary )?(work|task|plan)|park(ed|ing)? for later' \
    "$ROOT/nightshift/SKILL.md" "$ROOT/setup/SKILL.md" "$ROOT/start/SKILL.md" \
    "$ROOT/status/SKILL.md" "$ROOT/archive/SKILL.md" "$REF/templates/punch-list.md" \
    "$REF/templates/drafting-table.md" "$REF/templates/parking-lot.md" "$REF/templates/work-orders.md"; then
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
