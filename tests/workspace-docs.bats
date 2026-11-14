load helpers

ROOT="$BATS_TEST_DIRNAME/.."
LIB="$ROOT/plugins/nightshift/lib/lib.sh"
LINKER="$ROOT/plugins/nightshift/runtime/link-workspace.sh"

resolve_workspace() {
  bash -c '. "$1"; ns_workspace_root "$2"' _ "$LIB" "$1"
}

resolve_work_target() {
  bash -c '. "$1"; ns_work_target "$2"' _ "$LIB" "$1"
}

@test "documented repository and parent layouts match the resolver" {
  repo="$(new_project direct)"
  run resolve_work_target "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "$(git -C "$repo" rev-parse --show-toplevel)" ]

  workspace="$(new_workspace parent)"
  run resolve_work_target "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$(git -C "$workspace/repo" rev-parse --show-toplevel)" ]

  add_repo "$workspace" second
  run resolve_work_target "$workspace"
  [ "$status" -eq 2 ]

  bash -c '. "$1"; ns_record_work_target "$2" "$3"' \
    _ "$LIB" "$workspace" "$workspace/second"
  run resolve_work_target "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$(git -C "$workspace/second" rev-parse --show-toplevel)" ]
}

@test "an opened worktree resolves to that worktree" {
  repo="$(new_project worktree-source)"
  worktree="$BATS_TEST_TMPDIR/feature-worktree"
  git -C "$repo" worktree add -q -b workspace-docs-test "$worktree"
  mkdir -p "$worktree/.nightshift"

  run resolve_work_target "$worktree"
  [ "$status" -eq 0 ]
  [ "$output" = "$(git -C "$worktree" rev-parse --show-toplevel)" ]
  [ -f "$worktree/.git" ]
}

@test "the explicit link resolves state without selecting the work target" {
  host="$(new_project host)"
  workspace="$(new_workspace linked)"
  bash "$LINKER" --host-root "$host" --workspace "$workspace" >/dev/null

  run resolve_workspace "$host"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd -P "$workspace" && pwd)" ]
  [ ! -e "$workspace/.nightshift/work-target" ]

  printf 'relative/path\n' >"$host/.nightshift-link"
  run resolve_workspace "$host"
  [ "$status" -eq 2 ]
}

# The public surface says what the product does.
#
# A reader who types what a page shows and gets an error learns the page is not maintained, and
# from then on checks everything against the tree themselves. These hold the pages to the tree.

@test "no public page shows a command the product does not have" {
  for f in "$ROOT/README.md" "$ROOT"/docs/*.md "$ROOT"/examples/*.md; do
    [ -f "$f" ] || continue
    case "$f" in
      # These two map source files to the tests that cover them: a maintainer needs the path.
      */contribution-map.md | */maintainer-verification-matrix.md) continue ;;
    esac
    if grep -nE 'runtime[/\\](windows[/\\])?[a-z-]+\.(sh|ps1)' "$f" | grep -vE '[/\\]ns\.ps1|/ns"'; then
      echo "$f shows a helper path where a verb belongs"
      return 1
    fi
    if grep -nE '`[a-z][a-z0-9-]+\.(sh|ps1)' "$f" | grep -vE 'coverage\.sh|run\.ps1|ns\.ps1'; then
      echo "$f names a helper file where a verb belongs"
      return 1
    fi
  done
}

@test "no public page tells a reader to pass a flag the runtime supplies" {
  for f in "$ROOT/README.md" "$ROOT"/docs/*.md "$ROOT"/examples/*.md; do
    [ -f "$f" ] || continue
    case "$f" in */contribution-map.md | */maintainer-verification-matrix.md) continue ;; esac
    # `--project` is legitimate when the page is teaching terminal use from elsewhere; what is
    # not legitimate is telling the reader it is required.
    if grep -qF 'Do not omit `--project`' "$f"; then
      echo "$f still requires a flag the dispatcher supplies"
      return 1
    fi
    if grep -qE '\-Project\b' "$f"; then
      echo "$f carries a second spelling of a flag"
      return 1
    fi
  done
}

@test "every public page points at a reference that exists" {
  for f in "$ROOT/README.md" "$ROOT"/docs/*.md "$ROOT"/examples/*.md; do
    [ -f "$f" ] || continue
    for ref in $(grep -o 'references/[A-Za-z0-9_./-]*\.md' "$f" | sort -u); do
      case "$ref" in *'<'* | *'*'*) continue ;; esac
      [ -f "$ROOT/plugins/nightshift/skills/nightshift/$ref" ] \
        || { echo "$f points at missing $ref"; return 1; }
    done
  done
}
