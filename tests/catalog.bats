SHIFTS="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/compose/shifts"
CAT="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/compose/shift-catalog.md"
RECIPE="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/compose/catalog-recipe.md"

# Structural rules only. Every assertion here globs the directory, so a contributed shift is
# covered the moment its file lands — nobody edits this file to add an entry, which is the whole
# reason entries are one per file.

@test "the catalog directory has entries" {
  [ -d "$SHIFTS" ]
  n="$(find "$SHIFTS" -name '*.md' | wc -l | tr -d ' ')"
  [ "$n" -gt 0 ]
}

# The ending decides whether hunt asks for hours at all, so every entry states it in its title
# line where both a reader and the skill see it without parsing the body.
@test "every entry declares its ending in its title" {
  for f in "$SHIFTS"/*.md; do
    head -n1 "$f" | grep -qE '^# .+ — (finite|open-ended) — ' \
      || { echo "entry does not declare its ending: $f"; return 1; }
  done
}

@test "every entry ships a pasteable punch-list item" {
  for f in "$SHIFTS"/*.md; do
    grep -q '^```text$' "$f" || { echo "no fenced item block: $f"; return 1; }
    grep -qE '^- \[ \] \*\*.+\*\*$' "$f" || { echo "no punch-list item: $f"; return 1; }
  done
}

# An item with no Verify line cannot prove its work, and the gate has nothing to be green about.
@test "every entry ends with a Verify line" {
  for f in "$SHIFTS"/*.md; do
    grep -qE '^[[:space:]]*- Verify: ' "$f" || { echo "no Verify line: $f"; return 1; }
  done
}

# The definition of done is the lever the whole product rests on. An entry that never says what
# ends it is a shift that ends whenever the model feels finished.
@test "every entry states what ends it" {
  for f in "$SHIFTS"/*.md; do
    grep -qiE 'ends when|stop (only )?at|quitting time|converge' "$f" \
      || { echo "entry does not state its ending condition: $f"; return 1; }
  done
}

@test "every open-ended entry carries its ending into the pasted item" {
  for f in "$SHIFTS"/*.md; do
    if head -n1 "$f" | grep -q '— open-ended —'; then
      grep -qi 'Ending: open-ended' "$f" \
        || { echo "open-ended marker is not carried into item: $f"; return 1; }
    fi
  done
}

# One file per entry is what keeps two contributors out of the same diff. An index that listed
# them would put everyone back in it.
@test "the catalog index points at the directory and lists no entries" {
  grep -qF 'shifts/' "$CAT"
  grep -qi 'this page never lists' "$CAT"
  if grep -qE '^## .+ — (finite|open-ended) — ' "$CAT"; then
    return 1
  fi
}

# The maintainer preset is an order over existing entries. It must name the four it composes,
# name them in that order, and stay a preset — a fifth card would put every contributor back in
# the same diff.
@test "the maintainer night preset composes four existing entries in order" {
  grep -qF '## Maintainer night' "$CAT"
  order=""
  for entry in developer-onboarding documentation-drift ci-warning-cleanup release-readiness; do
    [ -f "$SHIFTS/$entry.md" ] || { echo "preset names a missing entry: $entry"; return 1; }
    grep -qF "shifts/$entry.md" "$CAT" || { echo "preset does not name: $entry"; return 1; }
    order="$order$(grep -n "shifts/$entry.md" "$CAT" | head -1 | cut -d: -f1)
"
  done
  [ "$order" = "$(printf '%s' "$order" | sort -n)
" ] || { echo "preset names the entries out of order"; return 1; }
  grep -qi 'one time budget' "$CAT"
  grep -qi 'not a card' "$CAT"
  # A preset under one budget has to say what the budget is for, or the owner is guessing.
  grep -qi 'cap rather than a requirement' "$CAT"
  grep -qi 'the owner names the number' "$CAT"
  [ ! -f "$SHIFTS/maintainer-night.md" ]
  HUNT="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/hunt/SKILL.md"
  grep -qF 'carries the Maintainer night preset' "$HUNT"
  grep -qF 'plus one line for any' "$HUNT"
}

# A contributed shift is a contract handed to an unattended agent on a stranger's repo. The six
# declarations are what makes such a PR reviewable at all.
@test "the catalog recipe demands every declaration a reviewer needs" {
  [ -f "$RECIPE" ]
  for d in 'finite or open-ended' 'Discovery' 'Definition of done' 'never do' 'Verification' 'Supported stacks'; do
    grep -qi "$d" "$RECIPE" || { echo "recipe does not demand: $d"; return 1; }
  done
  grep -qi 'read by a human before merge' "$RECIPE"
  grep -qi "stranger's workspace" "$RECIPE"
  grep -qF '$NS/receipts/' "$RECIPE"
}

@test "the recipe tells a contributor to add a file, not edit a shared one" {
  grep -qF 'shifts/' "$RECIPE"
  grep -qi 'tests/shifts/' "$RECIPE"
}

@test "the recipe points at the proposal form without replacing the two-file contract" {
  grep -qF 'issues/new?template=catalog_shift.yml' "$RECIPE"
  grep -qF 'orwa-mahmoud/nightshift/issues/21' "$RECIPE"
  grep -qi 'does not replace' "$RECIPE"
}
