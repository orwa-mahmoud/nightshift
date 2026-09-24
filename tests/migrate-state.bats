#!/usr/bin/env bats
# migrate-state moves a workspace's state files into the current layout. The layout table is the
# plan: every file found at an earlier path of its key moves to its current path, whatever layout
# the workspace started in. It previews by default, moves only with --apply, refuses while anything
# may be writing, never deletes or overwrites, and writes the marker last.

bats_require_minimum_version 1.5.0

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
MIGRATE="$PLUGIN/runtime/migrate-state.sh"
PS_MIGRATE="$PLUGIN/runtime/windows/migrate-state.ps1"
DOCTOR="$PLUGIN/runtime/doctor.sh"
PREFLIGHT="$PLUGIN/runtime/start-preflight.sh"
MODULE="$PLUGIN/lib/Nightshift.psm1"

fingerprint() {
  (cd "$1" && find . -name .git -prune -o \( -type f -o -type l \) -exec cksum {} \; | LC_ALL=C sort)
}

# v1_site [name] — a version-1 workspace with one of everything the move has to handle: a file of
# each group, the runtime's files, a family folder, a settings block under its old name, the page
# an older layout kept beside the punch list, and links that name moved files from live and
# archived pages alike. Echoes the workspace.
v1_site() {
  local ws="$BATS_TEST_TMPDIR/${1:-v1}" ns
  ns="$ws/.nightshift"
  mkdir -p "$ns/archive/2026-09-24" "$ns/receipts" "$ns/usage" "$ns/usage-abc123" "$ns/evidence"
  printf '1\n' >"$ns/state-version"
  printf '{\n  "report": {\n    "enabled": true,\n    "legacyItemReceipts": true\n  },\n  "watchMinutes": 10\n}\n' >"$ns/rules.json"
  printf '# Punch List\n\n## Items\n\n- [x] **1. done.** Decided in [the lot](parking-lot.md#top).\n' >"$ns/punch-list.md"
  printf '# Parking Lot\n\n- a decision · answered: yes\n\nFiled: [2026-09-24](archive/2026-09-24/parking-lot.md)\n' >"$ns/parking-lot.md"
  printf '# Snag Log\n\n- a snag · fixed\n\nFiled: [2026-09-24](archive/2026-09-24/snag-log.md)\n' >"$ns/snag-log.md"
  printf '# Drafting Table\n\nSee [the parked one](parking-lot.md) and [last night](archive/2026-09-24/punch-list.md).\n\n[log]: shift-log.md "The log"\n\n```\n[not a link](parking-lot.md)\n```\n\nAnd `[code](snag-log.md)` stays.\n' >"$ns/drafting-table.md"
  printf '# Work Orders\n' >"$ns/work-orders.md"
  printf '# Opportunity Map\n' >"$ns/opportunity-map.md"
  printf '# Product Research\n' >"$ns/product-research.md"
  printf '# Shift Log\n- line\n' >"$ns/shift-log.md"
  printf 'scheduled run\n' >"$ns/scheduled.log"
  printf '{}\n' >"$ns/capabilities.json"
  printf 'repository\n' >"$ns/work-mode"
  printf '%s\n' "$ws" >"$ns/work-target"
  printf 'a\tb\n' >"$ns/usage/segments.tsv"
  printf 'a\tb\n' >"$ns/usage-abc123/segments.tsv"
  : >"$ns/evidence/findings.jsonl"
  printf '# Previous report\n' >"$ns/shift-report.md"
  printf '# 1. done.\n\nSee [snags](../snag-log.md) and [the report](../shift-report.md).\n' >"$ns/receipts/a1b2-done.md"
  printf '# Parking Lot\n\n- a decision · answered: yes\n' >"$ns/archive/2026-09-24/parking-lot.md"
  printf '# Snag Log\n\n- a snag · fixed\n' >"$ns/archive/2026-09-24/snag-log.md"
  printf '# Punch List\n' >"$ns/archive/2026-09-24/punch-list.md"
  printf '# Drafting Table\n\nStill open: [the parked one](../../parking-lot.md).\n' >"$ns/archive/2026-09-24/drafting-table.md"
  printf 'stray\n' >"$ns/receipt-item.md"
  printf 'mine\n' >"$ns/owner-notes.txt"
  printf 'shiftId=abc\n' >"$ns/.ended"
  printf '%s' "$ws"
}

# plan <workspace> — the plan records, as the command computes them.
plan() {
  bash -c '. "$1"; . "${1%/*}/migrate.sh"; ns_migrate_plan "$2"' _ "$LIB" "$1"
}

# links_resolve <state-dir> — every relative link in every Markdown file resolves, outside code.
links_resolve() {
  local ns="$1" f t dir
  while IFS= read -r f; do
    dir="${f%/*}"
    while IFS= read -r t; do
      t="${t%%#*}"
      [ -n "$t" ] || continue
      case "$t" in *:* | /*) continue ;; esac
      [ -e "$dir/$t" ] || { echo "unresolved: ${f#"$ns"/} -> $t"; return 1; }
    done < <(awk '/^[[:space:]]*```/ { fence = !fence; next } !fence' "$f" | sed 's/`[^`]*`//g' \
      | grep -oE '\]\([^)]*\)|^\[[^]]*\]: *[^ ]+' | sed -E 's/^\]\(//; s/\)$//; s/^\[[^]]*\]: *//')
  done < <(find "$ns" -name .git -prune -o -type f -name '*.md' ! -name '*.original.md' -print)
}

@test "the preview lists every move, rename, link and leftover, and changes no byte" {
  ws="$(v1_site)"
  before="$(fingerprint "$ws")"
  run bash "$MIGRATE" --project "$ws"
  [ "$status" -eq 0 ]
  for line in \
    'move      parking-lot.md -> inbox/parking-lot.md' \
    'move      snag-log.md -> inbox/snag-log.md' \
    'move      drafting-table.md -> staging/drafting-table.md' \
    'move      work-orders.md -> staging/work-orders.md' \
    'move      opportunity-map.md -> product/opportunity-map.md' \
    'move      product-research.md -> product/product-research.md' \
    'move      shift-report.md -> receipts/previous-report.md' \
    'move      shift-log.md -> run/shift-log.md' \
    'move      work-target -> run/work-target' \
    'move      usage -> run/usage' \
    'move      usage-abc123 -> run/usage-abc123' \
    'move      evidence -> run/evidence' \
    'move      .ended -> run/.ended' \
    'rename    rules.json: report -> receipts' \
    'retire    rules.json: receipts.legacyItemReceipts (no version reads it)' \
    'link      punch-list.md: parking-lot.md#top -> inbox/parking-lot.md#top' \
    'link      staging/drafting-table.md: parking-lot.md -> ../inbox/parking-lot.md' \
    'link      staging/drafting-table.md: archive/2026-09-24/punch-list.md -> ../archive/2026-09-24/punch-list.md' \
    'link      staging/drafting-table.md: shift-log.md -> ../run/shift-log.md' \
    'link      receipts/a1b2-done.md: ../shift-report.md -> previous-report.md' \
    'link      archive/2026-09-24/drafting-table.md: ../../parking-lot.md -> ../../inbox/parking-lot.md' \
    'original  archive/2026-09-24/drafting-table.original.md keeps the archived file as it was' \
    'unknown   owner-notes.txt (no Nightshift file has this name; left in place)' \
    'stray     receipt-item.md' \
    'note      a schedule registered before this move still appends to scheduled.log' \
    'marker    state-version 1 -> 2' \
    'Preview only - nothing was changed. Run it again with --apply'; do
    printf '%s\n' "$output" | grep -qF -- "$line" || { echo "missing: $line"; echo "$output"; return 1; }
  done
  # Text inside a fence or a code span is not a link.
  if printf '%s\n' "$output" | grep -q 'not a link\|code\]'; then return 1; fi
  [ "$(fingerprint "$ws")" = "$before" ]
}

@test "--apply performs exactly what the preview listed, and the links still resolve" {
  ws="$(v1_site)"
  ns="$ws/.nightshift"
  plan "$ws" >"$BATS_TEST_TMPDIR/plan"
  while IFS="$(printf '\t')" read -r kind a b _; do
    [ "$kind" = move ] || continue
    if [ -f "$ns/$a" ]; then cksum <"$ns/$a" >"$BATS_TEST_TMPDIR/sum.${a//\//_}"; fi
  done <"$BATS_TEST_TMPDIR/plan"
  cp "$ns/archive/2026-09-24/drafting-table.md" "$BATS_TEST_TMPDIR/archived"

  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qF 'Applied. Nothing was deleted or overwritten.'

  while IFS="$(printf '\t')" read -r kind a b c; do
    case "$kind" in
      move)
        [ ! -e "$ns/$a" ] || { echo "still at $a"; return 1; }
        [ -e "$ns/$b" ] || { echo "not at $b"; return 1; }
        # A moved file keeps its bytes, but for the links the plan named in it.
        grep -q "^link$(printf '\t')$b$(printf '\t')" "$BATS_TEST_TMPDIR/plan" && continue
        if [ -f "$BATS_TEST_TMPDIR/sum.${a//\//_}" ]; then
          [ "$(cksum <"$ns/$b")" = "$(cat "$BATS_TEST_TMPDIR/sum.${a//\//_}")" ] || { echo "changed: $b"; return 1; }
        fi
        ;;
      link) grep -qF "$c" "$ns/$a" || { echo "not repointed: $a $c"; return 1; } ;;
    esac
  done <"$BATS_TEST_TMPDIR/plan"
  [ "$(cat "$ns/state-version")" = 2 ]
  jq -e '.receipts.enabled == true and (has("report") | not) and (.receipts | has("legacyItemReceipts") | not) and .watchMinutes == 10' "$ns/rules.json"
  cmp -s "$ns/archive/2026-09-24/drafting-table.original.md" "$BATS_TEST_TMPDIR/archived"
  # Fenced text and code spans are left exactly as written.
  grep -qF '[not a link](parking-lot.md)' "$ns/staging/drafting-table.md"
  grep -qF '`[code](snag-log.md)`' "$ns/staging/drafting-table.md"
  # What no layout names stays where it was.
  [ -f "$ns/owner-notes.txt" ]
  [ -f "$ns/receipt-item.md" ]
  links_resolve "$ns"
}

@test "a second run finds nothing to do and changes nothing" {
  ws="$(v1_site)"
  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 0 ]
  before="$(fingerprint "$ws")"
  run bash "$MIGRATE" --project "$ws"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'Every file is where the current layout keeps it; nothing to do.'
  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 0 ]
  [ "$(fingerprint "$ws")" = "$before" ]
}

@test "a rerun after an interrupted move finishes it and repoints what the first run moved" {
  ws="$(v1_site)"
  ns="$ws/.nightshift"
  # What an interrupted run leaves: some renames made, their links not yet written, the marker not.
  mkdir -p "$ns/inbox" "$ns/run"
  mv "$ns/parking-lot.md" "$ns/inbox/parking-lot.md"
  mv "$ns/shift-log.md" "$ns/run/shift-log.md"
  [ "$(cat "$ns/state-version")" = 1 ]
  run bash "$MIGRATE" --project "$ws"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'link      punch-list.md: parking-lot.md#top -> inbox/parking-lot.md#top'
  printf '%s\n' "$output" | grep -qF 'link      staging/drafting-table.md: shift-log.md -> ../run/shift-log.md'
  if printf '%s\n' "$output" | grep -qF 'move      parking-lot.md'; then return 1; fi
  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$ns/state-version")" = 2 ]
  [ -f "$ns/staging/drafting-table.md" ]
  links_resolve "$ns"
}

@test "an armed workspace is refused and nothing changes" {
  ws="$(v1_site)"
  : >"$ws/.nightshift/.shift-armed"
  before="$(fingerprint "$ws")"
  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse    the shift is armed (.shift-armed) - clock out, or run Reset, first'
  printf '%s\n' "$output" | grep -qF 'Refused - nothing was changed.'
  [ "$(fingerprint "$ws")" = "$before" ]
}

@test "a live watchman and a held lock are each refused by name" {
  ws="$(v1_site)"
  sleep 60 &
  pid=$!
  printf '%s\n' "$pid" >"$ws/.nightshift/.watchman"
  before="$(fingerprint "$ws")"
  run bash "$MIGRATE" --project "$ws" --apply
  kill "$pid" 2>/dev/null || :
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF "refuse    a watchman is running (pid $pid, .watchman)"
  [ "$(fingerprint "$ws")" = "$before" ]

  rm -f "$ws/.nightshift/.watchman"
  mkdir "$ws/.nightshift/.lock.d"
  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse    a lock is held (.lock.d)'
  [ "$(cat "$ws/.nightshift/state-version")" = 1 ]
  [ -f "$ws/.nightshift/parking-lot.md" ]
}

@test "a file at both paths with different content is refused by name, the same bytes are left" {
  ws="$(v1_site)"
  ns="$ws/.nightshift"
  mkdir -p "$ns/inbox"
  printf 'a different parking lot\n' >"$ns/inbox/parking-lot.md"
  before="$(fingerprint "$ws")"
  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 5 ]
  printf '%s\n' "$output" | grep -qF 'conflict  parking-lot.md and inbox/parking-lot.md are both there and differ - keep one by hand'
  [ "$(fingerprint "$ws")" = "$before" ]

  cp "$ns/parking-lot.md" "$ns/inbox/parking-lot.md"
  cp "$ns/parking-lot.md" "$BATS_TEST_TMPDIR/left"
  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qF 'leave     parking-lot.md (the same content is already at inbox/parking-lot.md)'
  # Nothing is deleted: the copy left behind stays as it was, and the one in place has its links
  # written for where it sits.
  cmp -s "$ns/parking-lot.md" "$BATS_TEST_TMPDIR/left"
  grep -qF '](../archive/2026-09-24/parking-lot.md)' "$ns/inbox/parking-lot.md"
  links_resolve "$ns"
  # The two still hold the same content, so a rerun leaves them as they are.
  before="$(fingerprint "$ws")"
  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qF 'leave     parking-lot.md (the same content is already at inbox/parking-lot.md)'
  [ "$(fingerprint "$ws")" = "$before" ]
}

@test "the older report page and settings move, including onto an existing page and without jq or python3" {
  ws="$(v1_site)"
  ns="$ws/.nightshift"
  printf '# A different previous report\n' >"$ns/receipts/previous-report.md"
  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 5 ]
  printf '%s\n' "$output" | grep -qF 'conflict  shift-report.md and receipts/previous-report.md are both there and differ'
  [ -f "$ns/shift-report.md" ]

  cp "$ns/shift-report.md" "$ns/receipts/previous-report.md"
  printf '{\n  "report": {\n    "enabled": false\n  },\n  "receipts": {\n    "enabled": false\n  }\n}\n' >"$ns/shift-policy.json"
  # Every tool the move needs, and neither JSON tool.
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  for tool in bash sh awk sed grep cat cp mv mkdir rm mktemp find sort tr cmp ls tail head cksum \
    dirname basename date ps kill env printf wc cut uname id readlink stat touch; do
    t="$(command -v "$tool" 2>/dev/null)" || continue
    ln -s "$t" "$bin/$tool"
  done
  run env PATH="$bin" bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qF 'leave     shift-report.md (the same content is already at receipts/previous-report.md)'
  printf '%s\n' "$output" | grep -qF 'drop      run/shift-policy.json: report (the same value is already under receipts)'
  grep -q '"receipts"' "$ns/rules.json"
  if grep -q '"report"\|legacyItemReceipts' "$ns/rules.json"; then return 1; fi
  if grep -q '"report"' "$ns/run/shift-policy.json"; then return 1; fi
  [ "$(cat "$ns/state-version")" = 2 ]
}

@test "settings present under both names with different values are refused by name" {
  ws="$(v1_site)"
  printf '{\n  "report": {\n    "enabled": true\n  },\n  "receipts": {\n    "enabled": false\n  }\n}\n' >"$ws/.nightshift/rules.json"
  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 5 ]
  printf '%s\n' "$output" | grep -qF 'conflict  rules.json holds both report and receipts with different values'
  [ "$(cat "$ws/.nightshift/state-version")" = 1 ]
}

@test "a legacy workspace with no marker moves too, and a new one is born in the current layout" {
  ws="$(v1_site)"
  rm -f "$ws/.nightshift/state-version"
  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'marker    state-version 0 -> 2'
  [ "$(cat "$ws/.nightshift/state-version")" = 2 ]

  fresh="$BATS_TEST_TMPDIR/fresh"
  mkdir -p "$fresh"
  run bash "$PLUGIN/runtime/scaffold.sh" --project "$fresh"
  [ "$status" -eq 0 ]
  [ "$(cat "$fresh/.nightshift/state-version")" = 2 ]
  run bash "$MIGRATE" --project "$fresh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'nothing to do'
}

@test "the receipts repository gets run/ left out, on a last line with no newline too" {
  ws="$(v1_site)"
  ns="$ws/.nightshift"
  printf 'STOP\n.stall' >"$ns/.gitignore"
  git -C "$ns" init -q
  run bash "$MIGRATE" --project "$ws"
  printf '%s\n' "$output" | grep -qF 'ignore    .gitignore: add run/'
  printf '%s\n' "$output" | grep -qF 'note      the receipts repository shows each move once you commit'
  run bash "$MIGRATE" --project "$ws" --apply
  [ "$status" -eq 0 ]
  [ "$(cat "$ns/.gitignore")" = "$(printf 'STOP\n.stall\nrun/')" ]
  run bash "$MIGRATE" --project "$ws"
  if printf '%s\n' "$output" | grep -qF 'ignore'; then return 1; fi
}

@test "Doctor names each file's old and new path, changes nothing, and waits while armed" {
  ws="$(v1_site)"
  before="$(fingerprint "$ws")"
  run bash "$DOCTOR" --project "$ws"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'state version 1 (every state file sits at the top of .nightshift/)'
  printf '%s\n' "$output" | grep -qF '[confirm] move the state files into layout 2: shift-report.md -> receipts/previous-report.md, parking-lot.md -> inbox/parking-lot.md, snag-log.md -> inbox/snag-log.md'
  printf '%s\n' "$output" | grep -qF '.ended -> run/.ended'
  printf '%s\n' "$output" | grep -qF 'nothing is deleted or overwritten. Preview it with'
  printf '%s\n' "$output" | grep -qF 'migrate-state.sh, then run it again with --apply'
  [ "$(fingerprint "$ws")" = "$before" ]

  : >"$ws/.nightshift/.shift-armed"
  run bash "$DOCTOR" --project "$ws"
  printf '%s\n' "$output" | grep -qF 'the move into layout 2 waits: the shift is armed (.shift-armed)'
  printf '%s\n' "$output" | grep -qF '[blocked] move the state files into layout 2:'
}

@test "Start warns once on a version-1 workspace and arms as usual" {
  ws="$(v1_site start)"
  rm -f "$ws/.nightshift/.ended"
  add_repo "$ws" repo
  printf '%s\n' "$ws/repo" >"$ws/.nightshift/work-target"
  printf '## Items\n- [ ] **1. work.**\n' >"$ws/.nightshift/punch-list.md"
  cp "$RULES_TEMPLATE" "$ws/.nightshift/rules.json"
  run bash "$PREFLIGHT" --project "$ws" --host claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | grep -c '^warn state-version')" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'warn state-version 1 keeps every state file at the top of .nightshift/ - Doctor offers the move to version 2'
  [ "$(cat "$ws/.nightshift/state-version")" = 1 ]
  [ -f "$ws/.nightshift/parking-lot.md" ]
}

@test "an armed version-1 workspace stays guarded by the upgraded hooks" {
  p="$(new_project)"
  printf '1\n' >"$p/.nightshift/state-version"
  punch_open "$p"
  run gate "$p"
  is_block "$output"
  run hardhat_bash "$p" 'rm .nightshift/.shift-armed'
  is_deny "$output"
  run hardhat_bash "$p" "printf x > $p/.nightshift/rules.json"
  is_deny "$output"
  [ -f "$p/.nightshift/.shift-armed" ]
  [ ! -d "$p/.nightshift/run" ]
}

@test "a version-2 workspace keeps its runtime files in run/ and the hooks guard them there" {
  p="$(new_project v2)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '2\n' >"$p/.nightshift/state-version"
  mkdir -p "$p/.nightshift/run"
  : >"$p/.nightshift/run/.shift-armed"
  punch_open "$p"
  run gate "$p"
  is_block "$output"
  [ -f "$p/.nightshift/run/.shift-session" ]
  [ ! -e "$p/.nightshift/.shift-session" ]
  run hardhat_bash "$p" 'rm .nightshift/run/.shift-armed'
  is_deny "$output"
  run hardhat_bash "$p" 'rm -rf .nightshift/run'
  is_deny "$output"
  [ -f "$p/.nightshift/run/.shift-armed" ]
  punch_done "$p"
  run gate "$p"
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/run/.ended" ]
  [ ! -e "$p/.nightshift/.ended" ]
}

@test "ns path answers from the workspace's own layout" {
  ws="$(cd -P "$(v1_site)" && pwd)"
  run bash "$PLUGIN/runtime/path.sh" --project "$ws" parking-lot armed usage-shift
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s\n%s' "$ws/.nightshift/parking-lot.md" "$ws/.nightshift/.shift-armed" "$ws/.nightshift/usage-")" ]
  run bash "$PLUGIN/runtime/path.sh" --project "$ws" inbox
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'path: layout 1 has no inbox'
  printf '2\n' >"$ws/.nightshift/state-version"
  run bash "$PLUGIN/runtime/path.sh" --project "$ws" parking-lot armed
  [ "$output" = "$(printf '%s\n%s' "$ws/.nightshift/inbox/parking-lot.md" "$ws/.nightshift/run/.shift-armed")" ]
}

@test "no hook, watchman or runtime script spells a state path itself" {
  moved='punch-list\.md|rules\.json|state-version|STOP|receipts|archive|support|parking-lot\.md|snag-log\.md|drafting-table\.md|work-orders\.md|opportunity-map\.md|product-research\.md|shift-log\.md|scheduled\.log|shift-policy\.json|capabilities\.json|work-target|work-mode|deadline|\.shift-[a-z]+|\.ended|\.pending-filing|\.stall|\.notified|\.session-end|\.watchman|\.watch-reason|\.mint-failed|\.lock\.d|\.lease-lock\.d|\.mutex-scope|usage|evidence|provision-[a-z]+'
  inline="(\\\$NS|\\\$ns|\\.nightshift)[\"}']?[/\\\\]($moved)"
  cd "$PLUGIN"
  hits="$(git ls-files 'hooks/**' 'runtime/**' 'lib/**' | grep -E '\.(sh|ps1|psm1|awk|jq)$' \
    | xargs grep -nE "$inline" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  [ -z "$hits" ] || { echo "$hits"; return 1; }
  # Skill commands name a key; a moved path is never built inline in one.
  hits="$(git ls-files 'skills/**/*.md' | xargs grep -nE "^(touch|rm|mv|cat|mkdir|New-Item|Remove-Item) .*$inline" || true)"
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}

@test "bash and PowerShell plan, render and apply the same move" {
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  a="$(v1_site bash-side)"
  b="$(v1_site pwsh-side)"
  printf 'fixed\n' >"$a/.nightshift/work-target"
  printf 'fixed\n' >"$b/.nightshift/work-target"
  plan "$a" | sed "s#$a#WS#g" >"$BATS_TEST_TMPDIR/bash.plan"
  pwsh -NoProfile -NonInteractive -Command "Import-Module '$MODULE' -Force -DisableNameChecking; foreach (\$r in (Get-NSMigrationPlan '$b').Records) { [Console]::Out.Write(\$r + \"\`n\") }" \
    | sed "s#$b#WS#g" >"$BATS_TEST_TMPDIR/pwsh.plan"
  diff "$BATS_TEST_TMPDIR/bash.plan" "$BATS_TEST_TMPDIR/pwsh.plan"
  run bash "$MIGRATE" --project "$a" --apply
  [ "$status" -eq 0 ]
  run pwsh -NoProfile -NonInteractive -File "$PS_MIGRATE" -Project "$b" -Apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  diff -r "$a/.nightshift" "$b/.nightshift"
}
