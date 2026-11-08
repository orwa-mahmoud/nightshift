#!/usr/bin/env bats
# The evidence catalog is one file per kind. This file globs the directory, so a new kind is
# covered the moment it lands — nothing here is a second registry.

bats_require_minimum_version 1.5.0

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
INDEX="$PLUGIN/runtime/catalog-index.sh"
INDEX_PS1="$PLUGIN/runtime/windows/catalog-index.ps1"
KINDS="$PLUGIN/skills/nightshift/references/evidence/kinds"
TEMPLATE="$PLUGIN/skills/nightshift/references/templates/evidence-kind.md"
CATALOG="$PLUGIN/skills/nightshift/references/evidence/catalog.md"
RECIPE="$PLUGIN/skills/nightshift/references/evidence/recipe.md"
MENU="$PLUGIN/skills/nightshift/references/plan/menu.md"
README="$PLUGIN/skills/nightshift/references/README.md"

# Drop HTML comments so a commented example is not a live block.
strip_comments() {
  awk '
    BEGIN { c = 0 }
    {
      line = $0
      out = ""
      while (length(line) > 0) {
        if (c) {
          i = index(line, "-->")
          if (i == 0) { line = ""; break }
          line = substr(line, i + 3)
          c = 0
          continue
        }
        i = index(line, "<!--")
        if (i == 0) { out = out line; line = ""; break }
        out = out substr(line, 1, i - 1)
        line = substr(line, i + 4)
        c = 1
      }
      if (!c) print out
    }
  ' "$1"
}

# A live evidence-check block uses files, min and type, and nothing else.
# No block is valid. Prints the reason on failure.
check_evidence_blocks() {
  strip_comments "$1" | awk '
    function fail(msg) { printf "%s\n", msg; exit 1 }
    BEGIN { in_block = 0; blocks = 0 }
    /^```evidence-check[[:space:]]*$/ {
      if (in_block) fail("nested evidence-check")
      in_block = 1
      blocks++
      delete seen
      next
    }
    in_block && /^```[[:space:]]*$/ {
      if (!("files" in seen) || !("min" in seen) || !("type" in seen)) fail("missing key")
      if (seen["files"] == "") fail("empty files")
      if (seen["min"] !~ /^[1-9][0-9]*$/) fail("invalid min")
      if (seen["type"] !~ /^(image|text|json|any)$/) fail("invalid type")
      in_block = 0
      next
    }
    in_block {
      if ($0 !~ /^[a-z]+:[[:space:]]*[^[:space:]].*$/) fail("unknown key")
      key = $0
      sub(/:.*/, "", key)
      if (key != "files" && key != "min" && key != "type") fail("unknown key")
      if (key in seen) fail("duplicate key")
      val = $0
      sub(/^[^:]+:[[:space:]]*/, "", val)
      seen[key] = val
      next
    }
    END {
      if (in_block) fail("unclosed evidence-check")
    }
  '
}

@test "every kind file and the template have the evidence shape" {
  [ -d "$KINDS" ] || { echo "no kinds directory"; return 1; }
  [ -f "$TEMPLATE" ] || { echo "no evidence-kind template"; return 1; }
  sections='When it applies|Evidence lines|How to generate|How to verify|Never'
  for f in "$KINDS"/*.md "$TEMPLATE"; do
    [ -f "$f" ] || { echo "missing $f"; return 1; }
    [ -L "$f" ] && continue
    head -n1 "$f" | grep -qE '^# .+ — .+' \
      || { echo "H1 shape: $f"; return 1; }
    got="$(awk '/^## / { print substr($0, 4) }' "$f" | paste -sd'|' -)"
    [ "$got" = "$sections" ] || { echo "sections ($got): $f"; return 1; }
    awk '
      /^## Evidence lines/ { on = 1; next }
      /^## / { on = 0 }
      on && /^- / { found = 1 }
      END { exit found ? 0 : 1 }
    ' "$f" || { echo "no evidence line: $f"; return 1; }
    reason="$(check_evidence_blocks "$f")" || { echo "evidence-check ($reason): $f"; return 1; }
  done
}

@test "an unknown key or an invalid type fails, and a kind with no block passes" {
  bad="$BATS_TEST_TMPDIR/bad-key.md"
  cat >"$bad" <<'EOF'
```evidence-check
files: *.png
min: 1
colour: red
```
EOF
  run check_evidence_blocks "$bad"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'unknown key'

  bad="$BATS_TEST_TMPDIR/bad-type.md"
  cat >"$bad" <<'EOF'
```evidence-check
files: *.png
min: 1
type: video
```
EOF
  run check_evidence_blocks "$bad"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'invalid type'

  plain="$BATS_TEST_TMPDIR/no-block.md"
  printf '# Plain — nothing mechanical\n' >"$plain"
  run check_evidence_blocks "$plain"
  [ "$status" -eq 0 ]

  [ -f "$KINDS/refactor.md" ]
  if strip_comments "$KINDS/refactor.md" | grep -qF '```evidence-check'; then
    echo "refactor carries a mechanical block"
    return 1
  fi
  run check_evidence_blocks "$KINDS/refactor.md"
  [ "$status" -eq 0 ]
}

@test "every shipped evidence line survived the split" {
  while IFS='|' read -r key sentence; do
    [ -f "$KINDS/$key.md" ] || { echo "missing $key"; return 1; }
    grep -qF "$sentence" "$KINDS/$key.md" || { echo "dropped line: $key"; return 1; }
  done <<'LINES'
ui|Before/after screenshots at named widths (for example 375 and 1280 px), light and dark. A short recording for a flow of more than one step.
performance|The exact command, the machine and its load, before/after figures with units, and the run count behind each figure.
tests|The tests added, the behaviour each one covers, and the coverage change for the touched files.
api-or-contract|A sample request and response, and the schema diff. For a breaking change, the old and new shape side by side.
docs|The rendered page, or a screenshot of it, and the link check output.
data-or-migration|Row or record counts before and after, the migration's own output, and the rollback command.
security|The scan command and its output, and each finding's disposition: fixed, accepted with a reason, or not applicable.
refactor|What moved where, what stayed behaviour-identical, and how that was shown: the unchanged tests, a before/after output diff, or both.
cli-or-tooling|The command run and its output before and after, including the error a user sees.
configuration-or-infrastructure|The resolved config diff, the plan or dry-run output, and how the change is undone.
LINES
}

@test "the template carries a commented evidence-check example" {
  grep -qF '<!--' "$TEMPLATE"
  grep -qF '```evidence-check' "$TEMPLATE"
  grep -qF 'files:' "$TEMPLATE"
  grep -qF 'min:' "$TEMPLATE"
  grep -qF 'type:' "$TEMPLATE"
  # The example is not a live block.
  ! strip_comments "$TEMPLATE" | grep -qF '```evidence-check'
}

@test "the evidence index lists every kind, and both runtimes agree" {
  run bash "$INDEX" --catalog evidence
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" \
    -eq "$(find "$KINDS" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')" ]
  while IFS= read -r line; do
    [ "$(printf '%s' "$line" | awk -F'\t' '{print NF}')" -eq 3 ] \
      || { echo "not three cells: $line"; return 1; }
    printf '%s' "$line" | awk -F'\t' '$1 == "" || $2 == "" || $3 == "" { exit 1 }' \
      || { echo "an empty cell: $line"; return 1; }
  done < <(printf '%s\n' "$output")
  for key in ui performance tests api-or-contract docs data-or-migration security refactor \
    cli-or-tooling configuration-or-infrastructure; do
    printf '%s\n' "$output" | cut -f1 | grep -qx "$key" \
      || { echo "index lacks $key"; return 1; }
  done

  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  run bash -c 'diff <(bash "$1" --catalog evidence) <(pwsh -NoProfile -File "$2" --catalog evidence)' _ "$INDEX" "$INDEX_PS1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "a kind added today is listed today, and a symlink is not" {
  extra="$KINDS/zz-temporary-evidence-kind.md"
  link="$KINDS/zz-symlink-evidence-kind.md"
  rm -f "$extra" "$link"
  cat >"$extra" <<'ENTRY'
# Temporary evidence kind — proves a new kind is listed without a registry edit
ENTRY
  ln -s "ui.md" "$link"
  run bash "$INDEX" --catalog evidence
  rm -f "$extra" "$link"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'zz-temporary-evidence-kind' \
    || { echo "a new kind was not listed"; return 1; }
  if printf '%s\n' "$output" | grep -qF 'zz-symlink-evidence-kind'; then
    echo "a symlinked kind was listed"
    return 1
  fi

  run bash "$INDEX" --catalog evidence
  [ "$status" -eq 0 ]
  if printf '%s\n' "$output" | grep -qF 'zz-temporary-evidence-kind'; then
    echo "a removed kind is still listed"
    return 1
  fi
}

@test "the shift index is still the default, byte for byte with --catalog shifts" {
  run bash "$INDEX"
  [ "$status" -eq 0 ]
  default="$output"
  run bash "$INDEX" --catalog shifts
  [ "$status" -eq 0 ]
  [ "$output" = "$default" ]
  first="$(printf '%s\n' "$default" | head -n1)"
  [ "$(printf '%s' "$first" | awk -F'\t' '{print NF}')" -eq 4 ]
}

@test "the entry page, the menu and the references index describe the two-step read" {
  flat() { tr '\n' ' ' <"$1" | tr -s ' '; }
  grep -qF 'Read this only after the owner says yes' "$CATALOG"
  grep -qF 'ns catalog-index --catalog evidence' "$CATALOG"
  flat "$CATALOG" | grep -qF 'read in full only the kinds that fit'
  ! grep -qF '| Kind of item |' "$CATALOG"
  flat "$MENU" | grep -qF 'Read `evidence/catalog.md` and suggest one `Evidence:` line per item'
  flat "$MENU" | grep -qF 'ns catalog-index --catalog evidence'
  flat "$MENU" | grep -qF 'read in full only the kinds that fit'
  grep -qF 'ns catalog-index --catalog evidence' "$README"
  grep -qF 'only the kinds that fit' "$README"
}

@test "adding a kind is one file, and the docs point at the recipe" {
  [ -f "$RECIPE" ]
  grep -qF 'templates/evidence-kind.md' "$RECIPE"
  grep -qF 'evidence-check' "$RECIPE"
  for word in 'files:' 'min:' 'type:' image text json any; do
    grep -qF "$word" "$RECIPE" || { echo "recipe lacks $word"; return 1; }
  done
  grep -qF 'references/evidence/recipe.md' "$ROOT/docs/evidence-capabilities.md"
  grep -qF 'references/evidence/recipe.md' "$ROOT/docs/contribution-map.md"
}
