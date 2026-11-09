SHIFTS="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/compose/shifts"

# Every assertion globs the directory, so a contributed shift is covered the moment its file lands.
# The ending and the pasteable item are checked for every entry in catalog-index.bats.

@test "the catalog directory has entries" {
  [ -d "$SHIFTS" ]
  n="$(find "$SHIFTS" -name '*.md' | wc -l | tr -d ' ')"
  [ "$n" -gt 0 ]
}

@test "every open-ended entry carries its ending into the pasted item" {
  for f in "$SHIFTS"/*.md; do
    if head -n1 "$f" | grep -q '— open-ended —'; then
      grep -qi 'Ending: open-ended' "$f" \
        || { echo "open-ended marker is not carried into item: $f"; return 1; }
    fi
  done
}
