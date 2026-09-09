#!/usr/bin/env bats
# A page that names a file which no longer ships sends the reader looking for it. Every backticked
# path in the public documentation must resolve in the repository, or be a workspace file the
# owner's own .nightshift/ holds.

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"

# Files the owner's workspace holds, not the repository.
STATE_FILES="punch-list.md drafting-table.md parking-lot.md work-orders.md snag-log.md
shift-log.md product-research.md opportunity-map.md shipped.md rules.json shift-policy.json
shift-defaults.json capabilities.json capability-policy.json provision-transaction.json
findings.jsonl hooks.json settings.local.json settings.json"

owned_docs() {
  printf '%s\n' "$ROOT/README.md" "$ROOT/CONTRIBUTING.md" "$ROOT/SECURITY.md" \
    "$PLUGIN/README.md" "$PLUGIN/SECURITY.md"
  find "$ROOT/docs" -name '*.md' | LC_ALL=C sort
}

# Link targets are checked more widely than backticked paths and helper names are. A skill page
# names `defect-cycle.sh` in order to forbid it and `Chart.yaml` as an example of a stack it might
# meet; neither is a path this repository holds. A link, though, is a promise that something is
# there — and one that moved with the P21 split pointed at nothing until this widened.
linked_docs() {
  owned_docs
  find "$PLUGIN/skills" -name '*.md' | LC_ALL=C sort
}

# Every path-shaped word inside a backtick span, unquoted and unpunctuated.
backticked_paths() {
  grep -o '`[^`]*`' "$1" \
    | tr -d '`' \
    | tr ' \t' '\n\n' \
    | sed -e 's/^[("'"'"'&]*//' -e 's/[)",;:'"'"']*$//' -e 's/\.$//' \
    | grep -E '\.(sh|ps1|jq|psm1|py|md|json|awk|yaml|yml)$' || true
}

# 0 when the reference resolves (or is not this repository's to resolve), 1 when it is dead.
resolves() {
  local ref="$1" rel base
  # A bare extension is prose about a file type; a glob is a pattern, not a path.
  case "$ref" in
    .sh | .ps1 | .py | .md | .json | .jq | .awk | .yml | .yaml) return 0 ;;
    *'*'* | *'?'*) return 0 ;;
  esac

  rel="$(printf '%s' "$ref" | tr '\\' '/')"
  case "$rel" in
    *'$NIGHTSHIFT_PLUGIN_ROOT'*)
      rel="${rel#*NIGHTSHIFT_PLUGIN_ROOT}"
      [ -e "$PLUGIN/${rel#/}" ] && return 0
      return 1
      ;;
    *'$NS'/* | .nightshift/*)
      rel="${rel#*/}"
      base="${rel##*/}"
      for s in $STATE_FILES; do
        [ "$base" = "$s" ] && return 0
      done
      # Anything else under the workspace is runtime state this test does not own.
      return 0
      ;;
    plugins/* | tests/* | evals/* | examples/* | docs/* | .github/*)
      [ -e "$ROOT/$rel" ] && return 0
      return 1
      ;;
    runtime/* | lib/* | hooks/* | skills/* | references/*)
      [ -e "$PLUGIN/$rel" ] && return 0
      [ -e "$PLUGIN/skills/nightshift/$rel" ] && return 0
      return 1
      ;;
    *'$'*) return 0 ;;
  esac

  base="${rel##*/}"
  for s in $STATE_FILES; do
    [ "$base" = "$s" ] && return 0
  done
  [ -e "$ROOT/$rel" ] && return 0
  [ -n "$(find "$ROOT/plugins" "$ROOT/tests" "$ROOT/evals" "$ROOT/docs" "$ROOT/.github" \
    -name "$base" -print -quit)" ] && return 0
  return 1
}

@test "every backticked path in the public documentation exists" {
  local dead=""
  while read -r f; do
    [ -f "$f" ] || { echo "missing doc: $f"; return 1; }
    while read -r ref; do
      [ -n "$ref" ] || continue
      resolves "$ref" || dead="$dead
  ${f#"$ROOT/"}: $ref"
    done < <(backticked_paths "$f")
  done < <(owned_docs)

  [ -z "$dead" ] || { echo "dead references:$dead"; return 1; }
}

# Every markdown link into the repository must land on a file that exists.
@test "every relative documentation link resolves" {
  local dead="" target dir
  while read -r f; do
    dir="$(dirname "$f")"
    while read -r target; do
      [ -n "$target" ] || continue
      case "$target" in
        http://* | https://* | mailto:* | '#'*) continue ;;
      esac
      target="${target%%#*}"
      [ -n "$target" ] || continue
      [ -e "$dir/$target" ] || dead="$dead
  ${f#"$ROOT/"}: $target"
    done < <(grep -o ']([^)]*)' "$f" | sed -e 's/^](//' -e 's/)$//')
  done < <(linked_docs)

  [ -z "$dead" ] || { echo "dead links:$dead"; return 1; }
}

# The removed wrappers must not come back as prose in a public page.
@test "no public page names a helper that does not ship" {
  local removed="quality-workflow.sh quality-scan.sh shift-planner.sh shift-preview.sh
plan-learning.sh history-context.sh coverage-risk.sh defect-cycle.sh source-policy-evidence.sh
engineering-evidence.sh product-truth-evidence.sh seo-evidence.sh owner-work-evidence.sh
pr-readiness-evidence.sh release-readiness-evidence.sh build-onboarding-evidence.sh
migration-evidence.sh operational-evidence.sh specialist-evidence.sh detect-capabilities.sh
refresh-inventory.sh recipe-audit.sh"
  local dead=""
  while read -r f; do
    for helper in $removed; do
      if grep -qF "$helper" "$f"; then
        dead="$dead
  ${f#"$ROOT/"}: $helper"
      fi
    done
  done < <(owned_docs)

  [ -z "$dead" ] || { echo "removed helpers named:$dead"; return 1; }
}

# The documentation index and the pages it points at must stay in step.
@test "the README reaches a documentation index that lists every reference page" {
  local index="$ROOT/docs/README.md" missing="" page relative
  grep -qF '](docs/README.md#documentation)' "$ROOT/README.md"
  [ -f "$index" ]
  while read -r page; do
    [ "$page" = "$index" ] && continue
    relative="${page#"$ROOT/docs/"}"
    grep -qF "]($relative#" "$index" || missing="$missing $relative"
    grep -qF '](README.md#documentation)' "$page" || missing="$missing $relative:return-to-index"
  done < <(find "$ROOT/docs" -name '*.md' | LC_ALL=C sort)
  [ -z "$missing" ] || { echo "not linked from docs/README.md:$missing"; return 1; }
}

@test "committed docs and skills do not name the retired report words" {
  local hit
  hit="$(grep -R --include='*.md' -nE 'shift-report\.md|report\.templatePath|report\.legacyItemReceipts|write-receipt' \
    "$ROOT/docs" "$ROOT/README.md" "$PLUGIN/README.md" "$PLUGIN/skills" || true)"
  [ -z "$hit" ] || { echo "retired wording still present:$hit"; return 1; }
}

# The shift's record is its receipts: one file per item, the index beside them, and the morning
# receipt. "Report" stays only where it names a deliverable of the work — a cited research report,
# an SEO audit, a scanner's output — or is the verb. Every kept use the word-level pattern would
# otherwise catch is named below as file:phrase.
ALLOWED_REPORT_USES="plugins/nightshift/skills/nightshift/references/compose/tooling-hints.md:the shift reports"

@test "no public page calls the shift's own record a report" {
  local hit
  hit="$(grep -R --include='*.md' -niE 'shift report|shift-report|report section|example report' \
    "$ROOT/README.md" "$ROOT/docs" "$PLUGIN/README.md" "$ROOT/examples/README.md" "$PLUGIN/skills" \
    | sed "s|^$ROOT/||" \
    | awk -v allow="$ALLOWED_REPORT_USES" '
        BEGIN { n = split(allow, pairs, "\n") }
        {
          for (i = 1; i <= n; i++) {
            colon = index(pairs[i], ":")
            if (colon == 0) continue
            file = substr(pairs[i], 1, colon - 1)
            phrase = substr(pairs[i], colon + 1)
            if (index($0, file ":") == 1 && index($0, phrase) > 0) next
          }
          print
        }
      ' || true)"
  [ -z "$hit" ] || { echo "the shift's record is its receipts, not a report:$hit"; return 1; }
}
