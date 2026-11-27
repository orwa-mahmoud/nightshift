#!/usr/bin/env bats
# Raw evidence stays private until it is chosen: ns promote-evidence lists a filed shift's raw
# evidence, copies the chosen files where Git sees them, links the filed receipts to the copies and
# labels the rest as private. The originals stay; a link is never followed.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
RUNTIME="$PLUGIN/runtime"
FOLDER=2026-11-27-aaa111
BASE=01-export-the-table-ab12

promote() { bash "$RUNTIME/promote-evidence.sh" --project "$1" --folder "${2:-$FOLDER}" "${@:3}"; }

# site <name> [evidence-preference] — a repository holding a site that shares everything, with one
# filed shift whose receipt links three raw evidence files, and a link to a file outside the site.
site() {
  local r="$BATS_TEST_TMPDIR/$1" filed
  add_repo "$BATS_TEST_TMPDIR" "$1"
  mkdir -p "$r/.nightshift/runs" "$r/.nightshift/staging/plans"
  printf '3\n' >"$r/.nightshift/state-version"
  jq --arg e "${2:-}" '.sharing.records = ["plans", "decisions", "rules", "receipts", "summaries"]
      | if $e == "" then del(.sharing.evidence) else .sharing.evidence = $e end' \
    "$RULES_TEMPLATE" >"$r/.nightshift/rules.json"
  bash "$RUNTIME/share.sh" --project "$r" --apply >/dev/null
  filed="$r/.nightshift/archive/$FOLDER"
  add_filed "$r" "$FOLDER"
  printf '%s' "$(cd -P "$r" && pwd)"
}

# add_filed <repo> <folder> — one filed shift with a receipt and its raw evidence.
add_filed() {
  local filed="$1/.nightshift/archive/$2"
  mkdir -p "$filed/receipts/$BASE/logs" "$BATS_TEST_TMPDIR/outside"
  printf '%s\n' "$2" >"$filed/.shift-id"
  printf 'secret\n' >"$BATS_TEST_TMPDIR/outside/secret.png"
  printf 'before\n' >"$filed/receipts/$BASE/before.png"
  printf 'after\n' >"$filed/receipts/$BASE/after.png"
  printf 'log\n' >"$filed/receipts/$BASE/logs/run.txt"
  ln -s "$BATS_TEST_TMPDIR/outside/secret.png" "$filed/receipts/$BASE/secret.png"
  ln -s "$BATS_TEST_TMPDIR/outside" "$filed/receipts/$BASE/elsewhere"
  printf '# 1. Export the table.\n\n![Before](./%s/before.png) and ![After](./%s/after.png).\n\nThe [run log](%s/logs/run.txt) and [a secret](./%s/secret.png).\n' \
    "$BASE" "$BASE" "$BASE" "$BASE" >"$filed/receipts/$BASE.md"
}

receipt() { cat "$1/.nightshift/archive/${2:-$FOLDER}/receipts/$BASE.md"; }
staged() { git -C "$1" add -A --dry-run | sed "s/^add '//; s/'\$//" | grep "archive/" | LC_ALL=C sort; }

@test "with no preference nothing is shared, and every link becomes a private label" {
  r="$(site none-set)"
  run promote "$r"
  [ "$status" -eq 0 ]
  [ "$output" = "ok preference none
eligible receipts/$BASE/after.png
eligible receipts/$BASE/before.png
eligible receipts/$BASE/logs/run.txt
next run this again with --apply, and --select, --all or --none to change the choice" ] || { echo "$output"; return 1; }
  run promote "$r" "$FOLDER" --apply
  [ "$status" -eq 0 ]
  [ ! -e "$r/.nightshift/archive/$FOLDER/evidence" ]
  [ "$(receipt "$r")" = "# 1. Export the table.

Before (private evidence: $BASE/before.png) and After (private evidence: $BASE/after.png).

The run log (private evidence: $BASE/logs/run.txt) and a secret (private evidence: $BASE/secret.png)." ]
  [ "$(staged "$r")" = ".nightshift/archive/$FOLDER/.shift-id
.nightshift/archive/$FOLDER/receipts/$BASE.md" ]
  # The originals stay where they were.
  [ -f "$r/.nightshift/archive/$FOLDER/receipts/$BASE/before.png" ]
}

@test "with all as the preference, narrowing one filing leaves the next one at all" {
  r="$(site all-set all)"
  run promote "$r"
  printf '%s\n' "$output" | grep -qx "promote receipts/$BASE/before.png"
  [ "$(printf '%s\n' "$output" | grep -c '^promote ')" = 3 ]
  run promote "$r" "$FOLDER" --select "receipts/$BASE/before.png" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cd "$r/.nightshift/archive/$FOLDER/evidence" && find . -type f | sort)" = "./$BASE/before.png" ]
  receipt "$r" | grep -qF "![Before](../evidence/$BASE/before.png) and After (private evidence: $BASE/after.png)."
  [ "$(staged "$r")" = ".nightshift/archive/$FOLDER/.shift-id
.nightshift/archive/$FOLDER/evidence/$BASE/before.png
.nightshift/archive/$FOLDER/receipts/$BASE.md" ]
  [ "$(jq -r .sharing.evidence "$r/.nightshift/rules.json")" = all ]
  add_filed "$r" 2026-11-28-bbb222
  run promote "$r" 2026-11-28-bbb222
  [ "$(printf '%s\n' "$output" | grep -c '^promote ')" = 3 ]
}

@test "a selection applied twice leaves one copy and the same receipt, and a link is never followed" {
  r="$(site selected select)"
  run promote "$r"
  ! printf '%s\n' "$output" | grep -q '^promote '
  ! printf '%s\n' "$output" | grep -q 'secret\|elsewhere'
  promote "$r" "$FOLDER" --select "receipts/$BASE/before.png" --select "receipts/$BASE/logs/run.txt" --apply >/dev/null
  first="$(receipt "$r")"
  promote "$r" "$FOLDER" --select "receipts/$BASE/before.png" --select "receipts/$BASE/logs/run.txt" --apply >/dev/null
  [ "$(receipt "$r")" = "$first" ]
  [ "$(cd "$r/.nightshift/archive/$FOLDER/evidence" && find . -type f | sort)" = "./$BASE/before.png
./$BASE/logs/run.txt" ]
  run promote "$r" "$FOLDER" --select "receipts/$BASE/secret.png" --apply
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx "refuse select receipts/$BASE/secret.png is not raw evidence of $FOLDER"
  run promote "$r" "$FOLDER" --select "receipts/$BASE/elsewhere/secret.png" --apply
  [ "$status" -eq 1 ]
  [ -z "$(find "$r/.nightshift/archive/$FOLDER/evidence" -name secret.png)" ]
}

@test "a teammate's checkout opens the promoted evidence from the receipt and has none of the rest" {
  r="$(site checkout all)"
  promote "$r" "$FOLDER" --select "receipts/$BASE/before.png" --apply >/dev/null
  git -C "$r" add -A
  git -C "$r" commit -q -m "file: export csv"
  git clone -q "$r" "$BATS_TEST_TMPDIR/teammate" 2>/dev/null
  t="$BATS_TEST_TMPDIR/teammate/.nightshift/archive/$FOLDER/receipts"
  link="$(sed -n 's/.*!\[Before\](\([^)]*\)).*/\1/p' "$t/$BASE.md")"
  [ "$link" = "../evidence/$BASE/before.png" ]
  [ "$(cat "$t/$link")" = before ]
  [ ! -e "$t/$BASE" ]
  ! grep -qF "$BATS_TEST_TMPDIR" "$t/$BASE.md"
}

@test "native Windows lists, copies and relinks the same way" {
  command -v pwsh >/dev/null || skip 'pwsh is not installed'
  a="$(site windows-bash select)"
  b="$(site windows-ps select)"
  bash_out="$(promote "$a" "$FOLDER" --select "receipts/$BASE/before.png" --apply)"
  ps_out="$(pwsh -NoProfile -File "$RUNTIME/windows/promote-evidence.ps1" -Project "$b" -Folder "$FOLDER" -Select "receipts/$BASE/before.png" -Apply)"
  [ "$bash_out" = "$ps_out" ] || { printf 'bash:\n%s\npwsh:\n%s\n' "$bash_out" "$ps_out"; return 1; }
  [ "$(receipt "$a")" = "$(receipt "$b")" ]
  [ "$(cd "$a/.nightshift/archive/$FOLDER/evidence" && find . -type f | sort)" = "$(cd "$b/.nightshift/archive/$FOLDER/evidence" && find . -type f | sort)" ]
  [ "$(pwsh -NoProfile -File "$RUNTIME/windows/promote-evidence.ps1" -Project "$b" -Folder "$FOLDER")" = "$(promote "$a")" ]
}
