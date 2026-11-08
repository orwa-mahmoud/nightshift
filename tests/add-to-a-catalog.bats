#!/usr/bin/env bats
# One page explains how to add to any catalog; each catalog's own page keeps only its rules.

ROOT="$BATS_TEST_DIRNAME/.."
PAGE="$ROOT/docs/add-to-a-catalog.md"
REFS="$ROOT/plugins/nightshift/skills/nightshift/references"
REGISTRY="$ROOT/plugins/nightshift/lib/catalogs.tsv"
RECIPES="$REFS/compose/catalog-recipe.md $REFS/evidence/recipe.md $REFS/compose/gates-catalog.md $REFS/plan/edge-cases.md"

@test "the page covers every catalog in the registry, with its folder, template and an example" {
  [ -f "$PAGE" ]
  while IFS=$'\t' read -r name shipped template _; do
    grep -qF "${shipped#skills/nightshift/references/}/" "$PAGE" || { echo "no folder for $name"; return 1; }
    grep -qF "${template##*/}" "$PAGE" || { echo "no template for $name"; return 1; }
  done < <(awk -F '\t' '!/^#/ && NF >= 9' "$REGISTRY")
  grep -qF '## Three steps' "$PAGE"
  grep -qF -- '--check-draft' "$PAGE"
  grep -qF 'ns catalog-new --catalog <catalog> --key <key>' "$PAGE"
  grep -qF '## What a reviewer looks for' "$PAGE"
}

@test "each catalog page keeps its rules and drops the copied setup commands" {
  for f in $RECIPES; do
    grep -qF 'add-to-a-catalog.md' "$f" || { echo "$f does not point at the page"; return 1; }
    if grep -qE 'mkdir -p|New-Item -ItemType Directory|Copy-Item' "$f"; then
      echo "$f still carries copy commands"
      return 1
    fi
  done
  # A code fence never opens inside another one.
  for f in $RECIPES; do
    awk '/^```/ { if (open && $0 != "```") { bad = 1 } open = !open } END { exit bad ? 1 : 0 }' "$f" \
      || { echo "$f nests a fence"; return 1; }
  done
}

@test "every contributor entry point names the page" {
  for f in "$ROOT/CONTRIBUTING.md" "$ROOT/README.md" "$ROOT/docs/contribution-map.md" \
    "$ROOT/docs/README.md" "$ROOT/.github/ISSUE_TEMPLATE/catalog_shift.yml"; do
    grep -qF 'add-to-a-catalog.md' "$f" || { echo "$f does not name the page"; return 1; }
  done
  if grep -qF 'two new files' "$ROOT/docs/contribution-map.md" "$ROOT/.github/ISSUE_TEMPLATE/catalog_shift.yml" "$REFS/compose/catalog-recipe.md"; then
    return 1
  fi
}
