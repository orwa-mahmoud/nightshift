#!/usr/bin/env bats
# File maps: with receipts.evidence.fileMap on, each tick draws the item's changed files into its
# receipt and the whole shift's into receipts/shift-map.md, from git, with no model involvement.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
CORE="$PLUGIN/hooks/shared/gate-core.sh"
PSM1="$PLUGIN/lib/Nightshift.psm1"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }
core() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$LIB" "$CORE" "$@"; }

# file_maps <project> <on|off> — the owner's setting.
file_maps() {
  jq --arg v "$2" '.receipts.evidence.fileMap = $v' "$1/.nightshift/rules.json" >"$1/.nightshift/rules.next"
  mv "$1/.nightshift/rules.next" "$1/.nightshift/rules.json"
}

# put <project> <path> <lines> — write a file of that many numbered lines.
put() {
  mkdir -p "$(dirname "$1/$2")"
  seq 1 "$3" | sed 's/^/line /' >"$1/$2"
}

commit() { git -C "$1" add -A -- . ':!.nightshift' && git -C "$1" commit -q -m "$2"; }

# tick <project> <n> — tick item n and let the gate record it, as a pulse does.
tick() {
  sed -i.bak "s/^- \[ \] \*\*$2\./- [x] **$2./" "$1/.nightshift/punch-list.md" && rm -f "$1/.nightshift/punch-list.md.bak"
  lib ns_usage_record "$1/.nightshift" claude claude-opus-5 transcript-incremental /t/a "$2" "input=$2,output=1"
  core ns_gate_usage_sync "$1/.nightshift" "$1" "$1/.nightshift/punch-list.md" "$2"
}

# block <receipt> — the generated block, markers included.
block() { sed -n '/^<!-- nightshift:file-map -->$/,/^<!-- \/nightshift:file-map -->$/p' "$1"; }

@test "an item's commit that adds three files and changes one is drawn as those four paths" {
  p="$(new_project fm-item)"
  file_maps "$p" on
  put "$p" README.md 2
  commit "$p" readme
  printf '## Items\n- [ ] **1. Add the parser.** <!-- id: aa11 -->\n- [ ] **2. Later.** <!-- id: bb22 -->\n' \
    >"$p/.nightshift/punch-list.md"
  lib ns_filemap_start "$p"
  base="$(git -C "$p" rev-parse HEAD)"
  put "$p" src/a.sh 2
  put "$p" src/b.sh 1
  put "$p" docs/c.md 3
  printf 'line 1\nchanged\n' >"$p/README.md"
  commit "$p" parser
  head="$(git -C "$p" rev-parse HEAD)"
  r="$p/.nightshift/receipts"
  mkdir -p "$r"
  printf '# 1. Add the parser.\n\nDone.\n' >"$r/01-add-the-parser-aa11.md"
  touch -t 202609240101 "$r/01-add-the-parser-aa11.md"
  tick "$p" 1
  [ "$(block "$r/01-add-the-parser-aa11.md")" = "$(cat <<'EOF'
<!-- nightshift:file-map -->
## File map

4 files changed, +7 -1

```text
./
  M README.md  +1 -1
docs/
  A c.md  +3 -0
src/
  A a.sh  +2 -0
  A b.sh  +1 -0
```
<!-- /nightshift:file-map -->
EOF
)" ] || { cat "$r/01-add-the-parser-aa11.md"; return 1; }
  # The runtime's writing keeps the receipt's time and is never read as the model's text.
  [ -z "$(find "$r/01-add-the-parser-aa11.md" -newermt '2026-09-24 01:02' 2>/dev/null)" ]
  ! lib ns_receipt_model_lines "$r/01-add-the-parser-aa11.md" | grep -qF 'File map' || false
  # A refresh redraws the block in place, never a second copy.
  lib ns_filemap_tick "$p/.nightshift" "$p" '1. Add the parser.'
  [ "$(grep -c '^<!-- nightshift:file-map -->$' "$r/01-add-the-parser-aa11.md")" -eq 1 ]
  # The shift map names its range, and the index and the morning page link it.
  grep -qxF "From ${base:0:12}, where the shift started, to ${head:0:12}." "$r/shift-map.md"
  grep -qxF '4 files changed, +7 -1' "$r/shift-map.md"
  grep -qxF 'Shift file map: [shift-map.md](./shift-map.md)' "$r/README.md"
  ! grep -qF '| Shift file map |' "$r/README.md" || false
  run bash "$PLUGIN/runtime/morning-receipt.sh" --project "$p"
  [[ "$output" == *'- Files: 4 files changed, +7 -1 ([shift-map.md](./shift-map.md))'* ]] || { printf '%s\n' "$output"; return 1; }
}

@test "after three ticks the shift map is the diff from the starting commit to HEAD, and each item keeps its own" {
  p="$(new_project fm-shift)"
  file_maps "$p" on
  printf '## Items\n- [ ] **1. One.** <!-- id: aa11 -->\n- [ ] **2. Two.** <!-- id: bb22 -->\n- [ ] **3. Three.** <!-- id: cc33 -->\n' \
    >"$p/.nightshift/punch-list.md"
  lib ns_filemap_start "$p"
  base="$(git -C "$p" rev-parse HEAD)"
  r="$p/.nightshift/receipts"
  mkdir -p "$r"
  for n in 1 2 3; do
    put "$p" "part$n/file$n.txt" "$n"
    commit "$p" "item $n"
    title="$(sed -n "s/^- \[ \] \*\*$n\. \([A-Za-z]*\)\.\*\*.*/\1/p" "$p/.nightshift/punch-list.md" | tr 'A-Z' 'a-z')"
    printf '# %s. Item.\n\nDone.\n' "$n" >"$r/0$n-$title-$(printf 'aa11 bb22 cc33' | cut -d' ' -f"$n").md"
    tick "$p" "$n"
  done
  # The shift map lists exactly what git says changed over the whole shift.
  want="$(git -C "$p" diff --name-only "$base" HEAD | LC_ALL=C sort)"
  got="$(awk '/^```text$/ { on = 1; next } /^```$/ { on = 0 } on' "$r/shift-map.md" | awk '
    /^[^ ]/ { dir = ($0 == "./") ? "" : $0; next }
    { sub(/^  [A-Z] /, ""); sub(/  .*$/, ""); print dir $0 }' | LC_ALL=C sort)"
  [ "$got" = "$want" ] || { echo "want: $want"; echo "got: $got"; return 1; }
  grep -qxF '3 files changed, +6 -0' "$r/shift-map.md"
  # Item two's map holds item two's commit alone.
  block "$r/02-two-bb22.md" | grep -qxF '1 file changed, +2 -0'
  block "$r/02-two-bb22.md" | grep -qxF '  A file2.txt  +2 -0'
  ! block "$r/02-two-bb22.md" | grep -qF 'file1.txt' || false
}

@test "a commit that touches 120 files collapses its folders and still totals 120" {
  p="$(new_project fm-wide)"
  file_maps "$p" on
  printf '## Items\n- [ ] **1. Wide.** <!-- id: aa11 -->\n' >"$p/.nightshift/punch-list.md"
  lib ns_filemap_start "$p"
  for i in $(seq 1 40); do
    put "$p" "pkg/a/x$i.txt" 1
    put "$p" "pkg/b/y$i.txt" 1
    put "$p" "lib/z$i.txt" 1
  done
  commit "$p" wide
  r="$p/.nightshift/receipts"
  mkdir -p "$r"
  printf '# 1. Wide.\n\nDone.\n' >"$r/01-wide-aa11.md"
  tick "$p" 1
  [ "$(block "$r/01-wide-aa11.md")" = "$(cat <<'EOF'
<!-- nightshift:file-map -->
## File map

120 files changed, +120 -0, folders collapsed

```text
lib/  40 files  +40 -0
pkg/  80 files  +80 -0
```
<!-- /nightshift:file-map -->
EOF
)" ] || { cat "$r/01-wide-aa11.md"; return 1; }
}

@test "with file maps off nothing is recorded and no map or block is written" {
  p="$(new_project fm-off)"
  printf '## Items\n- [ ] **1. Quiet.** <!-- id: aa11 -->\n' >"$p/.nightshift/punch-list.md"
  lib ns_filemap_start "$p"
  [ ! -e "$p/.nightshift/file-map" ] && [ ! -e "$p/.nightshift/run/file-map" ]
  put "$p" src/a.sh 2
  commit "$p" quiet
  r="$p/.nightshift/receipts"
  mkdir -p "$r"
  printf '# 1. Quiet.\n\nDone.\n' >"$r/01-quiet-aa11.md"
  tick "$p" 1
  ! grep -qF 'nightshift:file-map' "$r/01-quiet-aa11.md" || false
  [ ! -e "$r/shift-map.md" ]
  ! grep -qF 'Shift file map' "$r/README.md" || false
}

@test "a map that cannot be built says why, and artifact mode lists the declared outputs" {
  p="$(new_project fm-unavailable)"
  file_maps "$p" on
  printf '## Items\n- [ ] **1. Late.** <!-- id: aa11 -->\n' >"$p/.nightshift/punch-list.md"
  r="$p/.nightshift/receipts"
  mkdir -p "$r"
  printf '# 1. Late.\n\nDone.\n' >"$r/01-late-aa11.md"
  tick "$p" 1
  block "$r/01-late-aa11.md" | grep -qxF 'unavailable — no starting commit was recorded when the shift started'
  grep -qxF 'unavailable — no starting commit was recorded when the shift started' "$r/shift-map.md"

  a="$(new_project fm-artifact)"
  file_maps "$a" on
  printf 'artifact\n' >"$a/.nightshift/work-mode"
  printf '## Items\n- [ ] **1. Site.** <!-- id: aa11 -->\n- [ ] **2. Report.** <!-- id: bb22 -->\n' >"$a/.nightshift/punch-list.md"
  r="$a/.nightshift/receipts"
  mkdir -p "$r"
  printf '# 1. Site.\n\n## Outputs\n\n- `out/site/index.html` and [the styles](./out/site/style.css)\n- [docs](https://example.com/x) `not a path`\n' >"$r/01-site-aa11.md"
  printf '# 2. Report.\n\n## Outputs\n\n- [report](out/report.pdf)\n- `out/site/index.html`\n' >"$r/02-report-bb22.md"
  tick "$a" 1
  tick "$a" 2
  [ "$(block "$r/01-site-aa11.md")" = "$(cat <<'EOF'
<!-- nightshift:file-map -->
## File map

2 outputs declared

```text
out/site/
  index.html
  style.css
```
<!-- /nightshift:file-map -->
EOF
)" ] || { cat "$r/01-site-aa11.md"; return 1; }
  grep -qxF '3 outputs declared' "$r/shift-map.md"
  grep -qxF '  report.pdf' "$r/shift-map.md"
}

@test "PowerShell draws the same receipt block and shift map, byte for byte" {
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  p="$(new_project fm-parity)"
  file_maps "$p" on
  put "$p" keep/old-name.txt 5
  printf '\000PNG\001' >"$p/logo.png"
  commit "$p" before
  printf '## Items\n- [ ] **1. Mixed.** <!-- id: aa11 -->\n' >"$p/.nightshift/punch-list.md"
  lib ns_filemap_start "$p"
  git -C "$p" mv keep/old-name.txt keep/new-name.txt
  printf '\000PNG\002' >"$p/logo.png"
  put "$p" "a dir/with space.txt" 2
  for i in $(seq 1 45); do put "$p" "many/sub$((i % 3))/f$i.txt" 1; done
  commit "$p" mixed
  r="$p/.nightshift/receipts"
  mkdir -p "$r"
  printf '# 1. Mixed.\n\nDone.\n' >"$r/01-mixed-aa11.md"
  cp -R "$p" "$BATS_TEST_TMPDIR/fm-parity-ps"
  q="$BATS_TEST_TMPDIR/fm-parity-ps"
  lib ns_filemap_tick "$p/.nightshift" "$p" '1. Mixed.'
  NS_MODULE="$PSM1" NS_NS="$q/.nightshift" NS_WS="$q" pwsh -NoProfile -NonInteractive -Command \
    'Import-Module $env:NS_MODULE -Force -DisableNameChecking; Invoke-NSFileMapTick $env:NS_NS $env:NS_WS "1. Mixed."'
  cmp "$r/01-mixed-aa11.md" "$q/.nightshift/receipts/01-mixed-aa11.md" || { diff "$r/01-mixed-aa11.md" "$q/.nightshift/receipts/01-mixed-aa11.md"; return 1; }
  cmp "$r/shift-map.md" "$q/.nightshift/receipts/shift-map.md" || { diff "$r/shift-map.md" "$q/.nightshift/receipts/shift-map.md"; return 1; }
  grep -qF 'folders collapsed' "$r/shift-map.md"
  # The same change drawn uncollapsed: a rename, a binary file and a path with a space.
  lib ns_filemap_set "$p" last "$(git -C "$p" rev-parse HEAD~1)"
  lib ns_filemap_set "$q" last "$(git -C "$q" rev-parse HEAD~1)"
  git -C "$p" rm -q -r many && git -C "$p" commit -q -m trim
  git -C "$q" rm -q -r many && git -C "$q" commit -q -m trim
  lib ns_filemap_tick "$p/.nightshift" "$p" '1. Mixed.'
  NS_MODULE="$PSM1" NS_NS="$q/.nightshift" NS_WS="$q" pwsh -NoProfile -NonInteractive -Command \
    'Import-Module $env:NS_MODULE -Force -DisableNameChecking; Invoke-NSFileMapTick $env:NS_NS $env:NS_WS "1. Mixed."'
  cmp "$r/01-mixed-aa11.md" "$q/.nightshift/receipts/01-mixed-aa11.md" || { diff "$r/01-mixed-aa11.md" "$q/.nightshift/receipts/01-mixed-aa11.md"; return 1; }
  block "$r/01-mixed-aa11.md" | grep -qxF '  R new-name.txt  +0 -0  (from keep/old-name.txt)'
  block "$r/01-mixed-aa11.md" | grep -qxF '  M logo.png  binary'
  block "$r/01-mixed-aa11.md" | grep -qxF '  A with space.txt  +2 -0'
}

@test "native Windows covers file maps, and its suite is registered" {
  grep -qF 'receipt-file-map-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  run pwsh -NoProfile -File "$BATS_TEST_DIRNAME/windows/receipt-file-map-logic.ps1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}
