#!/usr/bin/env bash
# Git inspection and commit-safety helpers shared by Nightshift hooks.

# repo_root <project-dir> [candidate-dir ...]
#
# Echo the top level of the git repository the hooks should inspect, or return 1 when that
# cannot be decided. The recommended layout opens Claude Code in a plain workspace folder that
# holds the repo one level down, so the project dir is frequently not a repository itself:
#
#   my-project/        <- project dir, not a repo
#   ├── repo/          <- what the guards must inspect
#   └── .nightshift/   <- run state, with its own receipts repo
#
# Candidates are tried in order — the tool's own working directory first, since a commit runs
# from inside the repo it lands in — then the project dir, then a single level below it.
# Children whose own name is hidden are skipped, which keeps .nightshift's receipts repo out of
# the search; a hidden component anywhere else in the path is none of our business.
# Two distinct repositories below the project dir are undecidable: callers that guard a commit
# must treat that as a denial rather than pick one.
repo_root() {
  local project="$1"
  shift
  local d top found="" child base

  for d in "$@" "$project"; do
    [ -n "$d" ] || continue
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || continue
    printf '%s' "$top"
    return 0
  done

  for child in "$project"/*/; do
    base="${child%/}"
    base="${base##*/}"
    case "$base" in .*) continue ;; esac
    top="$(git -C "$child" rev-parse --show-toplevel 2>/dev/null)" || continue
    if [ -n "$found" ] && [ "$found" != "$top" ]; then
      return 1
    fi
    found="$top"
  done

  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

# ns_work_target <workspace>
#
# Resolve the work target Nightshift works on while keeping run state in <workspace>/.nightshift.
# Setup persists the choice in .nightshift/work-target and the mode in .nightshift/work-mode.
# Readers prefer those records so resumed, scheduled, and revived sessions do not rediscover a
# different folder. The path record may be absolute or relative to the workspace.
# Return 2 when several child repositories make an unstored repository choice ambiguous, 3 when
# the target is a disposable scratch path, 1 when nothing can be resolved.
ns_work_target() {
  local project="$1" record="$1/.nightshift/work-target" target="" child base top found="" mode=""
  mode="$(ns_work_mode "$project")" || return 1
  if [ -L "$record" ]; then
    return 1
  fi
  if [ -s "$record" ]; then
    IFS= read -r target <"$record" || true
    target="${target%$'\r'}"
    target="$(ns_msys_path "$target")"
    case "$target" in /*) ;; *) target="$project/$target" ;; esac
    top="$(cd -P "$target" 2>/dev/null && pwd)" || return 1
    if ns_is_scratch_path "$top"; then
      return 3
    fi
    if [ "$mode" = artifact ]; then
      [ -d "$top" ] || return 1
      printf '%s' "$top"
      return 0
    fi
    # git.exe's -C rejects /c/Users/... even when bash can cd there. Run from inside.
    top="$(cd -P "$target" 2>/dev/null && git rev-parse --show-toplevel)" || return 1
    printf '%s' "$top"
    return 0
  fi
  if [ "$mode" = artifact ]; then
    top="$(cd -P "$project" 2>/dev/null && pwd)" || return 1
    if ns_is_scratch_path "$top"; then
      return 3
    fi
    printf '%s' "$top"
    return 0
  fi

  if top="$(git -C "$project" rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s' "$top"
    return 0
  fi

  for child in "$project"/*/; do
    base="${child%/}"; base="${base##*/}"
    case "$base" in .*) continue ;; esac
    [ -L "${child%/}" ] && continue
    top="$(git -C "$child" rev-parse --show-toplevel 2>/dev/null)" || continue
    if [ -n "$found" ] && [ "$found" != "$top" ]; then return 2; fi
    found="$top"
  done
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

# ns_record_work_target <workspace> <path> [repository|artifact]
# Persist an absolute canonical work-target path atomically. The optional mode defaults to
# repository and is written to .nightshift/work-mode. Artifact mode records a persistent
# directory and does not require Git. Scratch paths are refused.
ns_record_work_target() {
  local project="$1" target="$2" mode="${3:-repository}" top tmp
  case "$mode" in repository | artifact) ;; *) return 1 ;; esac
  if ns_is_scratch_path "$target"; then
    return 3
  fi
  if [ "$mode" = artifact ]; then
    top="$(cd -P "$target" 2>/dev/null && pwd)" || return 1
    [ -d "$top" ] || return 1
  else
    top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" || return 1
  fi
  if ns_is_scratch_path "$top"; then
    return 3
  fi
  mkdir -p "$project/.nightshift" || return 1
  ns_record_work_mode "$project" "$mode" || return 1
  tmp="$project/.nightshift/.work-target.$$"
  printf '%s\n' "$top" >"$tmp" || return 1
  mv "$tmp" "$project/.nightshift/work-target"
  ns_ensure_work_target_link "$project" || return 1
}

# target_repo <command> <base-dir>
#
# A command can name the repository it acts on — `git -C <dir> commit`, or `cd <dir> && git
# commit` — and that repository, not the session's working directory, is where the commit
# lands. Resolve it so the guards inspect what is actually being written to.
#
#   0 + path  the command names a directory and it resolves to a repository
#   1         it names one that is NOT a repository — nothing can be verified about it
#   2         it names none; the caller should fall back to repo_root
target_repo() {
  local cmd="$1" base="$2" d=""

  d="$(printf '%s' "$cmd" |
    sed -n "s/.*git[[:space:]]\{1,\}-C[[:space:]]\{1,\}['\"]\{0,1\}\([^'\"[:space:];&|]\{1,\}\).*/\1/p" |
    head -n1)"
  if [ -z "$d" ]; then
    d="$(printf '%s' "$cmd" |
      sed -n "s/^[[:space:]]*cd[[:space:]]\{1,\}['\"]\{0,1\}\([^'\"[:space:];&|]\{1,\}\)['\"]\{0,1\}[[:space:]]*&&.*/\1/p" |
      head -n1)"
  fi
  [ -n "$d" ] || return 2

  case "$d" in /*) ;; *) d="$base/$d" ;; esac
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
  printf '%s' "$top"
  return 0
}

# commit_stages_implicitly <command>
#
# True when a `git commit` will pick up changes the index does not hold yet: `-a`/`--all` (and
# clustered short forms such as `-am`), or an explicit pathspec after `--`. Those commits are
# not described by `git diff --cached`, so a guard reading only the index would inspect the
# wrong content.
commit_stages_implicitly() {
  printf '%s' "$1" | grep -qE '(^|[[:space:]])--all([[:space:]]|$)' && return 0
  printf '%s' "$1" | grep -qE '(^|[[:space:]])-[a-zA-Z]*a[a-zA-Z]*([[:space:]]|$)' && return 0
  printf '%s' "$1" | grep -qE '(^|[[:space:]])--([[:space:]]|$)' && return 0
  return 1
}

# ns_git_verb_tail <command> <add|commit>
# Print the words after that git verb. Return 1 when the verb is absent.
ns_git_verb_tail() {
  local cmd="$1" verb="$2" seen=0 word
  # shellcheck disable=SC2086
  set -- $cmd
  for word in "$@"; do
    if [ "$seen" -eq 1 ]; then
      printf '%s\n' "$word"
      continue
    fi
    [ "$word" = "$verb" ] && seen=1
  done
  [ "$seen" -eq 1 ]
}

# Replay add/commit against a copied index so guards can ask Git what would be written
# without mutating the working index. 0 = prepared ($NS_GIT_PROSP_DIR, GIT_INDEX_FILE),
# 1 = no-op / empty, 2 = cannot model this command (fail closed).
ns_git_prospective_prepare() { # <repo> <command> <add|commit>
  local repo="$1" cmd="$2" verb="$3" tmp src word rest=0 skip=0 form=index
  local -a paths=()
  NS_GIT_PROSP_DIR=""
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ns-git.XXXXXX")" || return 2
  src="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)" || { rm -rf "$tmp"; return 2; }
  src="$src/index"
  if [ -f "$src" ]; then
    cp "$src" "$tmp/index" || { rm -rf "$tmp"; return 2; }
  fi
  export GIT_INDEX_FILE="$tmp/index"
  NS_GIT_PROSP_DIR="$tmp"
  git -C "$repo" ls-files --stage -z >"$tmp/before" 2>/dev/null || :

  while IFS= read -r word; do
    [ -n "$word" ] || continue
    if [ "$skip" -eq 1 ]; then
      skip=0
      continue
    fi
    if [ "$rest" -eq 1 ]; then
      [ "$word" = MSG ] || paths+=("$word")
      continue
    fi
    case "$word" in
      --) rest=1 ;;
      --all | -A)
        if [ "$verb" = add ]; then form=all
        else form=tracked
        fi
        ;;
      --update | -u) form=tracked ;;
      --include | -i) [ "$verb" = commit ] && form=include ;;
      --only | -o) [ "$verb" = commit ] && form=only ;;
      -m | --message | --file | --author | --date | --cleanup)
        skip=1
        ;;
      --message=* | --file=* | --author=* | --date=* | MSG) ;;
      --allow-empty | --allow-empty-message | --no-verify | --no-edit | --quiet | --signoff | -q | -s | -n | --no-gpg-sign | --porcelain | --verbose | -v | --force | -f | --ignore-missing | --refresh)
        ;;
      --amend | --patch | -p | --interactive | --chmod=* | --edit | -e | --fixup | --squash | --reuse-message | --reedit-message)
        ns_git_prospective_cleanup
        return 2
        ;;
      -*)
        if [ "$verb" = commit ] && printf '%s' "$word" | grep -qE '^-[[:alpha:]]*a[[:alpha:]]*$'; then
          form=tracked
        elif [ "$verb" = commit ] && printf '%s' "$word" | grep -qE '^-[[:alpha:]]*i[[:alpha:]]*$'; then
          form=include
        elif [ "$verb" = commit ] && printf '%s' "$word" | grep -qE '^-[[:alpha:]]*o[[:alpha:]]*$'; then
          form=only
        elif [ "$verb" = add ] && printf '%s' "$word" | grep -qE '^-[[:alpha:]]*A[[:alpha:]]*$'; then
          form=all
        elif [ "$verb" = add ] && printf '%s' "$word" | grep -qE '^-[[:alpha:]]*u[[:alpha:]]*$'; then
          form=tracked
        else
          ns_git_prospective_cleanup
          return 2
        fi
        ;;
      *) [ "$word" = MSG ] || paths+=("$word") ;;
    esac
  done < <(ns_git_verb_tail "$cmd" "$verb")

  if [ "$verb" = commit ] && [ "${#paths[@]}" -gt 0 ] && [ "$form" = index ]; then
    form=only
  fi

  case "$verb-$form" in
    add-index)
      if [ "${#paths[@]}" -eq 0 ]; then
        :
      else
        git -C "$repo" add -- "${paths[@]}" >/dev/null 2>&1 || { ns_git_prospective_cleanup; return 2; }
      fi
      ;;
    add-all) git -C "$repo" add -A >/dev/null 2>&1 || { ns_git_prospective_cleanup; return 2; } ;;
    add-tracked) git -C "$repo" add -u >/dev/null 2>&1 || { ns_git_prospective_cleanup; return 2; } ;;
    commit-index) ;;
    commit-tracked) git -C "$repo" add -u >/dev/null 2>&1 || { ns_git_prospective_cleanup; return 2; } ;;
    commit-include)
      if [ "${#paths[@]}" -gt 0 ]; then
        git -C "$repo" add -- "${paths[@]}" >/dev/null 2>&1 || { ns_git_prospective_cleanup; return 2; }
      fi
      ;;
    commit-only)
      git -C "$repo" read-tree HEAD >/dev/null 2>&1 || git -C "$repo" read-tree --empty >/dev/null 2>&1 || {
        ns_git_prospective_cleanup
        return 2
      }
      if [ "${#paths[@]}" -gt 0 ]; then
        git -C "$repo" add -- "${paths[@]}" >/dev/null 2>&1 || { ns_git_prospective_cleanup; return 2; }
      fi
      ;;
    *) ns_git_prospective_cleanup; return 2 ;;
  esac
  return 0
}

ns_git_prospective_cleanup() {
  [ -n "${NS_GIT_PROSP_DIR:-}" ] && rm -rf "$NS_GIT_PROSP_DIR"
  unset GIT_INDEX_FILE NS_GIT_PROSP_DIR
}

# Print NUL-delimited paths this add/commit would write. 2 = cannot model.
ns_git_prospective_paths() { # <repo> <command> <add|commit>
  local repo="$1" cmd="$2" verb="$3" rc line _path
  ns_git_prospective_prepare "$repo" "$cmd" "$verb"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if [ "$verb" = add ]; then
    tr '\0' '\n' <"$NS_GIT_PROSP_DIR/before" >"$NS_GIT_PROSP_DIR/before.nl" 2>/dev/null || :
    git -C "$repo" ls-files --stage -z 2>/dev/null | tr '\0' '\n' >"$NS_GIT_PROSP_DIR/after.nl" || :
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      grep -F -x -- "$line" "$NS_GIT_PROSP_DIR/before.nl" >/dev/null 2>&1 && continue
      printf '%s\0' "${line#*	}"
    done <"$NS_GIT_PROSP_DIR/after.nl"
    # A deletion has no after-index entry, so the loop above never emits it.
    sed 's/^[^	]*	//' "$NS_GIT_PROSP_DIR/after.nl" | sort -u >"$NS_GIT_PROSP_DIR/after.paths"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      _path="${line#*	}"
      grep -F -x -- "$_path" "$NS_GIT_PROSP_DIR/after.paths" >/dev/null 2>&1 && continue
      printf '%s\0' "$_path"
    done <"$NS_GIT_PROSP_DIR/before.nl"
  else
    git -C "$repo" diff --cached --name-only -z --no-ext-diff HEAD 2>/dev/null \
      || git -C "$repo" diff --cached --name-only -z --no-ext-diff 2>/dev/null \
      || true
  fi
  ns_git_prospective_cleanup
  return 0
}

# Print the diff this commit would write. 2 = cannot model.
ns_git_prospective_diff() { # <repo> <command>
  local repo="$1" cmd="$2" rc
  ns_git_prospective_prepare "$repo" "$cmd" commit
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  git -C "$repo" diff --cached --no-ext-diff HEAD 2>/dev/null \
    || git -C "$repo" diff --cached --no-ext-diff 2>/dev/null \
    || true
  ns_git_prospective_cleanup
  return 0
}
