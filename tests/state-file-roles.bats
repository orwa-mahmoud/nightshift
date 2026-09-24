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

@test "the inbox templates name exactly the dispositions Archive files, and both runtimes file one list" {
  plugin="$BATS_TEST_DIRNAME/../plugins/nightshift"
  list="$(bash -c '. "$1"; printf %s "$NS_REVIEW_DISPOSITIONS"' _ "$plugin/lib/lib.sh")"
  [ -n "$list" ]
  [ "$(sed -n "s/^\$script:NSReviewDispositions = '\(.*\)'\$/\1/p" "$plugin/lib/Nightshift.psm1")" = "$list" ]
  want="$(printf '%s\n' "$list" | tr '|' '\n' | sort)"
  for t in parking-lot snag-log; do
    got="$(grep '^\*\*Dispositions:\*\*' "$REF/templates/$t.md" | grep -o '`[^`]*`' | tr -d '`' | sort)"
    [ "$got" = "$want" ] || { printf '%s.md names:\n%s\n' "$t" "$got"; return 1; }
  done
  for d in $(printf '%s' "$list" | tr '|' ' '); do
    grep -qF "\`$d\`" "$ROOT/nightshift/SKILL.md"
    grep -qF "\`$d\`" "$ROOT/archive/SKILL.md"
  done
  # The list is written once per runtime; every reader takes it from there.
  run grep -rlF 'rejected-because|accepted-tradeoff' "$plugin"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sort)" = "$(printf '%s\n' "$plugin/lib/Nightshift.psm1" "$plugin/lib/state.sh")" ]
  [ "$(grep -cF 'rejected-because|accepted-tradeoff' "$plugin/lib/state.sh")" -eq 1 ]
  [ "$(grep -cF 'rejected-because|accepted-tradeoff' "$plugin/lib/Nightshift.psm1")" -eq 1 ]
}

@test "an inbox entry is a bullet, an open one waits for the owner, and an answer is appended, never deleted" {
  for t in parking-lot snag-log; do
    grep -qF '**Each entry** is one `- ` bullet below the rule' "$REF/templates/$t.md"
    grep -qF 'Archive files only' "$REF/templates/$t.md"
    grep -qF 'Doctor names it' "$REF/templates/$t.md"
    tr '\n' ' ' <"$REF/templates/$t.md" | grep -qF 'An entry with no disposition is open and waits for the owner'
  done
  tr '\n' ' ' <"$REF/templates/parking-lot.md" | grep -qF 'The owner answers by appending ` · answered: <decision>` to the entry, and Archive files it.'
  tr '\n' ' ' <"$REF/templates/parking-lot.md" | grep -qF 'Never delete an answered entry'
  if grep -qiE 'deletes? entries|once decided' "$REF/templates/parking-lot.md"; then return 1; fi
  tr '\n' ' ' <"$ROOT/nightshift/SKILL.md" | grep -qF 'the owner answers it by appending ` · answered: <decision>`'
  tr '\n' ' ' <"$ROOT/archive/SKILL.md" | tr -s ' ' | grep -qF 'The owner answers an entry by appending ` · answered: <decision>`; an answered entry is filed, never deleted.'
  tr '\n' ' ' <"$ROOT/doctor/SKILL.md" | grep -qF 'each parking-lot or snag-log paragraph Archive can never file, by file and line'
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
