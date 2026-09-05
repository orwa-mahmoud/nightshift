#!/usr/bin/env bash
# Shared hardhat decisions. Host wrappers own payload parsing and deny response emission.

# Armed site rules apply until clock-out writes ENDED. STOP is a stop-work order, not
# the ending — open boxes stay as the record and do not stand the hardhat down. Reset
# is the manual escape. A punch list that exists but will not count keeps the site armed:
# only a readable list with every box ticked takes the hardhat off.
ns_hardhat_active() {
  local _open
  if [ -f "$ENDED" ] && [ ! -L "$ENDED" ]; then
    return 1
  fi
  [ -f "$NS/.shift-armed" ] || return 1
  [ -f "$PUNCH" ] || return 1
  if [ -f "$NS/STOP" ] && [ ! -L "$NS/STOP" ]; then
    return 0
  fi
  _open="$(ns_open_boxes "$PUNCH")" || return 0
  [ "$_open" -gt 0 ]
}

ns_hardhat_is_command_tool() {
  case "$1" in Bash | PowerShell | Shell) return 0 ;; esac
  return 1
}

ns_hardhat_binding_probe() { # $1 = canonical tool name, $2 = command
  case "$1" in
    Bash | Shell) [ "$2" = ": nightshift-binding-probe" ] ;;
    PowerShell) [ "$2" = "\$null = 'nightshift-binding-probe'" ] ;;
    *) return 1 ;;
  esac
}

ns_hardhat_rules_targeted() {
  local normalized
  normalized="$(printf '%s' "$1" | sed 's#\\/#/#g')"
  printf '%s' "$normalized" | grep -qE '\.nightshift/rules\.json|nightshift-rules\.json' \
    || {
      printf '%s' "$normalized" | grep -q '\.nightshift' \
        && printf '%s' "$normalized" | grep -q 'rules\.json'
    }
}

# True when the command is already inside .nightshift — by path, by cd/pushd, or by payload cwd.
ns_hardhat_nightshift_dir_context() {
  local normalized="$1" cwd_norm ns_norm
  # `.nightshift && unlink .shift-armed` has no slash after the directory name.
  if printf '%s' "$normalized" | grep -qE '\.nightshift([/[:space:];&]|$)'; then
    return 0
  fi
  if printf '%s' "$normalized" |
      grep -qE '(^|[;&|()[:space:]])(cd|pushd)[[:space:]]+([^;&|()[:space:]]*/)?\.nightshift/?([;&|()[:space:]]|$)'; then
    return 0
  fi
  if [ -n "${CWD:-}" ] && [ -n "${NS:-}" ]; then
    cwd_norm="${CWD%/}"
    ns_norm="${NS%/}"
    case "$cwd_norm" in
      "$ns_norm" | "$ns_norm"/*) return 0 ;;
    esac
  fi
  return 1
}

ns_hardhat_lease_targeted() {
  local normalized nightshift_context=0
  normalized="$(printf '%s' "$1" | sed "s#\\\\/#/#g; s#[\"']##g")"
  if printf '%s' "$normalized" |
      grep -qE '(^|/)(\.shift-lease|\.mutex-scope)($|[^[:alnum:]_-])|(^|/)\.lease-lock\.d($|/)'; then
    return 0
  fi
  if ns_hardhat_nightshift_dir_context "$normalized"; then
    nightshift_context=1
  fi
  if [ "$nightshift_context" -eq 1 ]; then
    case "$normalized" in
      *'.shift-*'* | *'.shift-?'* | *'.shift-['* | *'.shift-{'* | *'.shift-$'* | *'.shift-`'* \
        | *'.lease-*'* | *'.lease-?'* | *'.lease-['* | *'.lease-{'* | *'.lease-$'* | *'.lease-`'* \
        | *'.mutex-*'* | *'.mutex-?'* | *'.mutex-['* | *'.mutex-{'* | *'.mutex-$'* | *'.mutex-`'* \
        | *'.nightshift/*'* | *'.nightshift/.*'* | *'.nightshift/.?'* \
        | *'{'*'shift-lease'* | *'{'*'lease-lock'* | *'{'*'mutex-scope'* ) return 0 ;;
    esac
  fi
  # The delete verb must target .nightshift itself. `cd .nightshift && unlink .shift-armed`
  # is a control-file write, not `rm .nightshift`.
  if printf '%s' "$normalized" |
      grep -qE '(^|[;&|()[:space:]])(rm|rmdir|unlink|mv)[[:space:]]+([^;&|\n]*[[:space:]]+)?(\./)?\.nightshift/?([;&|()[:space:]]|$)'; then
    return 0
  fi
  if printf '%s' "$normalized" | grep -qE '(^|[;&|[:space:]])find([[:space:]]|$)' \
    && printf '%s' "$normalized" | grep -qE '(^|[[:space:]])(\./)?\.nightshift/?([[:space:]]|$)' \
    && printf '%s' "$normalized" | grep -qE '(^|[[:space:]])(-delete|-exec)([[:space:]]|$)'; then
    return 0
  fi
  return 1
}

ns_hardhat_payload_targets() { # $1 = tool, $2 = raw payload, $3 = command/patch, $4 = predicate
  local targets="" predicate="$4" decoder="" encoded record_type
  case "$1" in
    Bash | PowerShell | Shell)
      "$predicate" "$3"
      return
      ;;
    apply_patch)
      targets="$(printf '%s\n' "$3" \
        | grep -E '^\*\*\* (Add|Update|Delete) File:|^\*\*\* Move to:' 2>/dev/null || true)"
      ;;
    *)
      if [ "${NS_HARDHAT_TARGETS_FOR:-}" = "$2" ]; then
        targets="${NS_HARDHAT_TARGETS:-}"
        decoder="${NS_HARDHAT_TARGETS_DECODER:-}"
      elif command -v jq >/dev/null 2>&1; then
        targets="$(printf '%s' "$2" | jq -r '
          def string_values: .. | strings;
          .tool_input
          | ..
          | objects
          | . as $object
          | (
              (
                $object
                | to_entries[]
                | select(.key | test("((^|_)(path|filepath|file|filename|directory|dir|uri|name)$|^(target|destination|dest|source|src)$)"; "i"))
                | .value
                | string_values
                | if contains("\n") then @base64 | "P\t\(.)" else "p\t\(.)" end
              ),
              (
                $object
                | to_entries[]
                | select(.key | test("(^|_)(command|cmd|script)$"; "i"))
                | .value
                | string_values
                | if contains("\n") then @base64 | "C\t\(.)" else "c\t\(.)" end
              ),
              (
                [$object | to_entries[] | select(.key | test("^(directory|dir)$"; "i")) | .value | string_values] as $dirs
                | [$object | to_entries[] | select(.key | test("^(name|filename|file)$"; "i")) | .value | string_values] as $names
                | $dirs[] as $dir
                | $names[] as $name
                | "\($dir)/\($name)"
                | if contains("\n") then @base64 | "P\t\(.)" else "p\t\(.)" end
              )
            )
        ' 2>/dev/null)" || return 2
        decoder=jq
      else
        # No general Bash JSON parser. Missing jq fails closed.
        return 2
      fi
      NS_HARDHAT_TARGETS_FOR="$2"
      NS_HARDHAT_TARGETS="$targets"
      NS_HARDHAT_TARGETS_DECODER="$decoder"
      ;;
  esac
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    if [ -n "$decoder" ]; then
      case "$target" in
        p$'\t'*) target="${target#*$'\t'}" ;;
        c$'\t'*) target="$(ns_hardhat_scrub "${target#*$'\t'}")" ;;
        P$'\t'* | C$'\t'*)
          record_type="${target%%$'\t'*}"
          encoded="${target#*$'\t'}"
          if [ "$decoder" = "jq" ]; then
            target="$(
              printf '%s' "$encoded" | jq -jRr '@base64d' 2>/dev/null || exit
              printf '\034'
            )" || return 2
          else
            return 2
          fi
          target="${target%$'\034'}"
          if [ "$record_type" = "C" ]; then
            target="$(
              ns_hardhat_scrub "$target"
              printf '\034'
            )"
            target="${target%$'\034'}"
          fi
          ;;
        *) return 2 ;;
      esac
    fi
    if "$predicate" "$target"; then return 0; fi
  done <<<"$targets"
  return 1
}

# Bound-worker control plane: forge/delete of the files the gate keys off. The shift policy, the
# remembered defaults and the derived deadline join them: tonight's authority is written before
# arming, so an armed agent that could rewrite it could widen its own permissions.
# punch-list.md may be edited; only a delete/rename of that file is denied.
# Regex is a pre-filter. A write is a hit only when the target's canonical absolute path
# equals $NS/<control-file>, so // /./ /../ backslashes and absolute twins cannot slip past.
ns_hardhat_control_prefilter() {
  printf '%s' "$1" | grep -qE \
    '(STOP|\.shift-armed|\.ended|\.shift-session|\.shift-worker|work-target|work-mode|shift-policy\.json|shift-defaults\.json|deadline|punch-list\.md)'
}

ns_hardhat_control_delete_verb() {
  printf '%s' "$1" | grep -qE '(^|[;&|()[:space:]])(rm|rmdir|unlink|mv|Remove-Item|Move-Item|Rename-Item)([[:space:]]|$)'
}

ns_hardhat_control_bare_name() {
  case "$1" in
    STOP | .shift-armed | .ended | .shift-session | .shift-worker | work-target | work-mode \
      | shift-policy.json | shift-defaults.json | deadline | punch-list.md \
      | ./STOP | ./.shift-armed | ./.ended | ./.shift-session | ./.shift-worker \
      | ./work-target | ./work-mode | ./shift-policy.json | ./shift-defaults.json \
      | ./deadline | ./punch-list.md)
      return 0
      ;;
  esac
  return 1
}

# Lexically collapse // /./ /../ on an absolute slash path. Directory need not exist.
ns_hardhat_lex_abs() {
  local p="$1" out="" part rest
  case "$p" in /*) ;; *) return 1 ;; esac
  rest="${p#/}"
  while [ -n "$rest" ]; do
    case "$rest" in
      */*)
        part="${rest%%/*}"
        rest="${rest#*/}"
        ;;
      *)
        part="$rest"
        rest=""
        ;;
    esac
    case "$part" in
      '' | .) continue ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$part" ;;
    esac
  done
  [ -n "$out" ] || out=/
  printf '%s' "$out"
}

# Canonical absolute path of a write target. The leaf need not exist; directory
# symlinks are followed. Relative paths resolve against CWD, then PROJECT_DIR.
ns_hardhat_canon_write_target() {
  local p="$1" base dir leaf
  [ -n "$p" ] || return 1
  p="$(printf '%s' "$p" | sed "s#\\\\#/#g; s#[\"']##g")"
  [ -n "$p" ] || return 1
  case "$p" in
    /*) ;;
    *)
      if [ -n "${CWD:-}" ]; then
        base="${CWD%/}"
      elif [ -n "${PROJECT_DIR:-}" ]; then
        base="${PROJECT_DIR%/}"
      else
        return 1
      fi
      case "$base" in
        /*) ;;
        *)
          [ -n "${PROJECT_DIR:-}" ] || return 1
          base="${PROJECT_DIR%/}/$base"
          ;;
      esac
      p="$base/$p"
      ;;
  esac
  p="$(ns_hardhat_lex_abs "$p")" || return 1
  if [ "$p" = / ]; then
    printf '/'
    return 0
  fi
  leaf="${p##*/}"
  dir="${p%/*}"
  [ -n "$dir" ] || dir=/
  dir="$(cd -P "$dir" >/dev/null 2>&1 && pwd -P)" || return 1
  if [ "$dir" = / ]; then
    printf '/%s' "$leaf"
  else
    printf '%s/%s' "$dir" "$leaf"
  fi
}

ns_hardhat_control_expected() {
  [ -n "${NS:-}" ] || return 1
  ns_hardhat_canon_write_target "$NS/$1"
}

ns_hardhat_control_rewrite_hit() {
  local name exp
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    exp="$(ns_hardhat_control_expected "$name")" || continue
    [ "$1" = "$exp" ] && return 0
  done <<'EOF'
STOP
.shift-armed
.ended
.shift-session
.shift-worker
work-target
work-mode
shift-policy.json
shift-defaults.json
deadline
EOF
  return 1
}

ns_hardhat_control_list_hit() {
  local exp
  exp="$(ns_hardhat_control_expected punch-list.md)" || return 1
  [ "$1" = "$exp" ]
}

ns_hardhat_control_candidates() {
  printf '%s\n' "$1" | tr ';|&()<>' '\n' | tr -s '[:space:]' '\n'
}

ns_hardhat_control_candidate_hits() {
  local cand="$1" full="$2" canon leaf
  leaf="${cand##*/}"
  leaf="${leaf#./}"
  if ns_hardhat_control_bare_name "$cand" && ns_hardhat_nightshift_dir_context "$full"; then
    canon="$(ns_hardhat_control_expected "$leaf")" || return 1
  else
    canon="$(ns_hardhat_canon_write_target "$cand")" || return 1
  fi
  ns_hardhat_control_rewrite_hit "$canon" && return 0
  ns_hardhat_control_list_hit "$canon" && ns_hardhat_control_delete_verb "$full"
}

ns_hardhat_control_targeted() {
  local normalized candidate
  normalized="$(printf '%s' "$1" | sed "s#\\\\#/#g; s#[\"']##g")"
  ns_hardhat_control_prefilter "$normalized" || return 1
  [ -n "${NS:-}" ] || return 1
  if ! printf '%s' "$normalized" | grep -qE '[[:space:];&|<>()]'; then
    ns_hardhat_control_candidate_hits "$normalized" "$normalized"
    return
  fi
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    ns_hardhat_control_candidate_hits "$candidate" "$normalized" && return 0
  done <<EOF
$(ns_hardhat_control_candidates "$normalized")
EOF
  return 1
}

ns_hardhat_payload_targets_control() {
  case "$1" in
    Read | Grep | Glob | LS | WebFetch | WebSearch | Task | TodoWrite | AskQuestion | AskUserQuestion | request_user_input | NotebookRead)
      return 1
      ;;
    *read* | *Read*)
      return 1
      ;;
  esac
  ns_hardhat_payload_targets "$1" "$2" "$3" ns_hardhat_control_targeted
}

ns_hardhat_payload_targets_rules() {
  ns_hardhat_payload_targets "$1" "$2" "$3" ns_hardhat_rules_targeted
}

ns_hardhat_payload_targets_lease() {
  local rc
  ns_hardhat_payload_targets "$1" "$2" "$3" ns_hardhat_lease_targeted
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 2 ] || return 1
  # If toolDeny cannot be read exactly, unknown local tools fail closed rather than letting a
  # helper conversation address the lease through an opaque payload.
  case "$1" in
    AskQuestion | AskUserQuestion | request_user_input | WebFetch | WebSearch | Task | TodoWrite) return 1 ;;
    *) return 0 ;;
  esac
}

NS_HARDHAT_NL='
'
NS_HARDHAT_STRIPPED=""

# ns_hardhat_strip_quoted_heredocs <command> — the same command with the body of every quoted
# here-document replaced by a placeholder.
#
# A quoted delimiter means the shell expands nothing in the body, runs nothing in it, and the
# words inside are the file being written rather than a command. Reading that body as code makes
# the product unwritable from inside a shift: a page explaining the elevation categories reads as
# a request for one, and a note naming a control file reads as an attempt to rewrite it.
#
# The line that opens the heredoc is kept, so the redirection target is inspected exactly as
# before — writing a protected file is caught by where it writes, not by what it says. An
# unquoted delimiter is left alone, because that body is expanded and a command substitution in
# it really does run. So is an unterminated one: a body with no visible end is not skipped.
ns_hardhat_strip_quoted_heredocs() {
  local input="$1" out="" line delim="" body_open=0 found stripped
  NS_HARDHAT_STRIPPED="$input"
  case "$input" in
    *'<<'*) ;;
    *) return 0 ;;
  esac
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$body_open" -eq 1 ]; then
      stripped="${line#"${line%%[! 	]*}"}"
      if [ "$stripped" = "$delim" ] || [ "$line" = "$delim" ]; then
        body_open=0
        out="$out$line$NS_HARDHAT_NL"
      fi
      continue
    fi
    out="$out$line$NS_HARDHAT_NL"
    found="$(printf '%s' "$line" | sed -n \
      -e "s/.*<<-\{0,1\}[[:space:]]*'\([^']*\)'.*/\1/p" \
      -e 's/.*<<-\{0,1\}[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    if [ -n "$found" ]; then
      delim="$found"
      body_open=1
      out="${out}NIGHTSHIFT_HEREDOC_BODY$NS_HARDHAT_NL"
    fi
  done <<NS_HEREDOC_SCAN
$input
NS_HEREDOC_SCAN
  if [ "$body_open" -eq 1 ]; then
    return 0
  fi
  case "$input" in
    *"$NS_HARDHAT_NL") NS_HARDHAT_STRIPPED="$out" ;;
    *) NS_HARDHAT_STRIPPED="${out%"$NS_HARDHAT_NL"}" ;;
  esac
}

ns_hardhat_scrub() {
  ns_hardhat_strip_quoted_heredocs "$1"
  ns_hardhat_scrub_options "$NS_HARDHAT_STRIPPED"
}

ns_hardhat_scrub_options() {
  local input="$1" output="" length i=0 j k option_length quote char previous next dynamic closed start
  length="${#input}"
  while [ "$i" -lt "$length" ]; do
    start=$i
    option_length=0
    while [ "$i" -lt "$length" ]; do
      if [ "$i" -eq 0 ]; then previous=""; else previous="${input:$((i - 1)):1}"; fi
      option_length=0
      case "$previous" in
        '' | ' ' | $'\t' | $'\n')
          if [ "${input:$i:9}" = "--message" ]; then
            next="${input:$((i + 9)):1}"
            case "$next" in '' | '=' | ' ' | $'\t' | $'\n' | "'" | '"') option_length=9 ;; esac
          elif [ "${input:$i:2}" = "-m" ]; then
            next="${input:$((i + 2)):1}"
            case "$next" in '' | '=' | ' ' | $'\t' | $'\n' | "'" | '"') option_length=2 ;; esac
          fi
          ;;
      esac
      [ "$option_length" -gt 0 ] && break
      i=$((i + 1))
    done
    if [ "$i" -gt "$start" ]; then
      output="${output}${input:$start:$((i - start))}"
    fi
    [ "$i" -ge "$length" ] && break
    [ "$option_length" -gt 0 ] || continue

    j=$((i + option_length))
    [ "${input:$j:1}" = "=" ] && j=$((j + 1))
    while [ "$j" -lt "$length" ]; do
      case "${input:$j:1}" in ' ' | $'\t' | $'\n') j=$((j + 1)) ;; *) break ;; esac
    done
    quote="${input:$j:1}"
    case "$quote" in
      "'")
        k=$((j + 1))
        while [ "$k" -lt "$length" ] && [ "${input:$k:1}" != "'" ]; do k=$((k + 1)); done
        if [ "$k" -lt "$length" ]; then
          output="${output}${input:$i:$((j - i))}MSG"
          i=$((k + 1))
          continue
        fi
        ;;
      '"')
        k=$((j + 1))
        dynamic=0
        closed=0
        while [ "$k" -lt "$length" ]; do
          char="${input:$k:1}"
          if [ "$char" = "\\" ]; then
            k=$((k + 2))
            continue
          fi
          if [ "$char" = '"' ]; then closed=1; break; fi
          if [ "$char" = '`' ] \
            || { [ "$char" = '$' ] && [ "${input:$((k + 1)):1}" = '(' ]; }; then
            dynamic=1
          fi
          k=$((k + 1))
        done
        if [ "$closed" -eq 1 ]; then
          if [ "$dynamic" -eq 1 ]; then
            output="${output}${input:$i:$((k - i + 1))}"
          else
            output="${output}${input:$i:$((j - i))}MSG"
          fi
          i=$((k + 1))
          continue
        fi
        ;;
    esac
    output="${output}${input:$i:1}"
    i=$((i + 1))
  done
  printf '%s' "$output"
}

ns_hardhat_rules_has() {
  [ -n "${TOOL_RULES:-}" ] || return 1
  ns_rules_map_has "$TOOL_RULES" "$1"
}

ns_hardhat_rules_msg() {
  ns_rules_map_msg "$TOOL_RULES" "$1"
}

ns_hardhat_tool_deny_broken() {
  [ -n "${TOOL_RULES:-}" ] || return 1
  case "$TOOL_RULES" in
    __nightshift_invalid_tool_rules__ | __nightshift_tool_rules_parser_missing__) return 0 ;;
  esac
  ! ns_rules_map_parse "$TOOL_RULES"
}

ns_hardhat_tool_deny_reason() {
  local m
  [ -n "$1" ] && ns_hardhat_rules_has "$1" || return 1
  m="$(ns_hardhat_rules_msg "$1")"
  [ -n "$m" ] || return 1
  printf '%s' "$m"
}

ns_hardhat_required_tool_deny_reason() {
  if ! ns_hardhat_rules_has "$1"; then
    printf '%s' "BLOCKED: toolDeny is missing the required '$1' entry. Add that exact host tool name to .nightshift/rules.json with a denial message, or use an empty string to allow it; run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex) to review the current template."
    return 0
  fi
  ns_hardhat_tool_deny_reason "$1"
}

ns_hardhat_git_verb() {
  printf '%s' "$1" | grep -qE "(^|[^[:alnum:]_-])git([^[:alnum:]]|$)" \
    && printf '%s' "$1" | grep -qE "(^|[^[:alnum:]_-])$2([^[:alnum:]]|$)"
}

ns_hardhat_is_git_write() {
  ns_hardhat_git_verb "$1" add || ns_hardhat_git_verb "$1" commit \
    || ns_hardhat_git_verb "$1" tag || ns_hardhat_git_verb "$1" remote
}

ns_hardhat_is_commit() {
  ns_hardhat_git_verb "$1" commit
}

# Print a simple quoted payload after eval or a shell -c, or nothing.
# Hardening only: one pair of quotes, no nested parser, not a sandbox.
ns_hardhat_elevation_inner() {
  local s="$1" inner
  printf '%s' "$s" | grep -qE '(^|[;&|()[:space:]])(eval|[A-Za-z0-9./_-]*sh[[:space:]]+-[a-zA-Z]*c)[[:space:]]' || return 1
  inner="$(printf '%s' "$s" | sed -n "s/.*eval[[:space:]]\{1,\}'\([^']*\)'.*/\1/p")"
  [ -n "$inner" ] && { printf '%s' "$inner"; return 0; }
  inner="$(printf '%s' "$s" | sed -n 's/.*eval[[:space:]]\{1,\}"\([^"]*\)".*/\1/p')"
  [ -n "$inner" ] && { printf '%s' "$inner"; return 0; }
  inner="$(printf '%s' "$s" | sed -n "s/.*[A-Za-z0-9./_-]*sh[[:space:]]\{1,\}-[a-zA-Z]*c[[:space:]]\{1,\}'\([^']*\)'.*/\1/p")"
  [ -n "$inner" ] && { printf '%s' "$inner"; return 0; }
  inner="$(printf '%s' "$s" | sed -n 's/.*[A-Za-z0-9./_-]*sh[[:space:]]\{1,\}-[a-zA-Z]*c[[:space:]]\{1,\}"\([^"]*\)".*/\1/p')"
  [ -n "$inner" ] && { printf '%s' "$inner"; return 0; }
  return 1
}

# Print a deny reason when the command needs an elevation category this shift does not allow,
# or return 1 to allow. Uses globals: SCRUBBED PROJECT_DIR
#
# Elevation gates creating system state, never using what already runs: the category patterns come
# from rules.elevation (or the shipped defaults) through ns_policy_elevation_pattern, which the
# permission preflight reads too, so the guard and the preflight can never disagree about what a
# command needs. Whether tonight lifts a deny is the resolver's answer alone — ns_policy_allowed
# carries the whole precedence table, including the exact-plan binding — so this reads a status
# and writes the sentence the agent acts on. A pattern the owner broke denies rather than lapses.
# A simple eval / sh -c quoted payload is matched as well as the outer text; that is hardening,
# not isolation — a determined rewrite still gets through.
ns_hardhat_elevation_reason() {
  local _cat _pat _rc _reason _patterns _subject _inner
  _subject="$SCRUBBED"
  _inner="$(ns_hardhat_elevation_inner "$SCRUBBED" || true)"
  [ -n "$_inner" ] && _subject="$SCRUBBED $_inner"
  # One parse of the rules for all five categories; each line is category<TAB>pattern.
  _patterns="$(ns_policy_elevation_patterns "$PROJECT_DIR")" || return 1
  while IFS="$(printf '\t')" read -r _cat _pat; do
    if [ -z "$_cat" ] || [ -z "$_pat" ]; then
      continue
    fi
    valid_ere "$_pat" || {
      printf '%s' "BLOCKED: elevation.$_cat.pattern is not a valid extended regular expression, so the guard it configures cannot run. Fix the pattern in .nightshift/rules.json."
      return 0
    }
    printf '%s' "$_subject" | grep -qE "$_pat" || continue
    ns_policy_allowed "$PROJECT_DIR" "$_cat" "$SCRUBBED"
    _rc=$?
    [ "$_rc" -eq 0 ] && continue
    _reason="BLOCKED: this command needs the '$_cat' elevation category, which is denied for this shift."
    if [ "$_rc" -eq 2 ]; then
      printf '%s' "$_reason An exact-plan allowance exists but this command is not one of its approved commands."
    else
      printf '%s' "$_reason The owner allows it in .nightshift/rules.json (elevation.$_cat.policy) or for one shift in shift-policy.json before arming. Park the item in .nightshift/parking-lot.md as \"needs allowance: $_cat\" and keep working."
    fi
    return 0
  done <<EOF
$_patterns
EOF
  return 1
}

# Print a deny reason for a Bash-like command, or return 1 to allow.
# Uses globals: SCRUBBED CMD CWD PROJECT_DIR PROTECTED_DIRS EXPECTED_EMAIL
# NEVER_COMMIT_PATTERNS FORBIDDEN_COMMANDS
ns_hardhat_command_reason() {
  local _p _name _pat d _tok _dirs _toks REPO email _scope _diff _verb _pathfile _pathrc _hit
  for _p in "FORBIDDEN_COMMANDS:$FORBIDDEN_COMMANDS" "NEVER_COMMIT_PATTERNS:$NEVER_COMMIT_PATTERNS"; do
    _name="${_p%%:*}"
    _pat="${_p#*:}"
    [ -n "$_pat" ] || continue
    valid_ere "$_pat" || {
      printf '%s' "BLOCKED: NIGHTSHIFT_$_name is not a valid extended regular expression, so the guard it configures cannot run. Fix the pattern in your session settings."
      return 0
    }
  done

  if [ -n "$PROTECTED_DIRS" ] && ns_hardhat_is_git_write "$SCRUBBED"; then
    _verb=""
    ns_hardhat_git_verb "$SCRUBBED" add && _verb=add
    ns_hardhat_git_verb "$SCRUBBED" commit && _verb=commit
    if [ -n "$_verb" ]; then
      if printf '%s' "$SCRUBBED" | grep -qE -- '--git-dir|--work-tree'; then
        printf '%s' "BLOCKED: --git-dir/--work-tree point this $_verb somewhere the protected-directory guard cannot verify. Run it from inside the repository instead."
        return 0
      fi
      REPO="$(target_repo "$CMD" "${CWD:-$PROJECT_DIR}")"
      case "$?" in
        1) printf '%s' "BLOCKED: this $_verb names a directory that is not a git repository, so the protected-directory guard cannot inspect it. Do not retry a rephrased form."
           return 0 ;;
        2) REPO="$(repo_root "$PROJECT_DIR" "$CWD")" || REPO="$(ns_work_target "$PROJECT_DIR")" || {
             printf '%s' "BLOCKED: cannot tell which git repository this $_verb targets, so the protected-directory guard cannot run. Run it from inside the repository."
             return 0
           } ;;
      esac
      _pathfile="$(mktemp "${TMPDIR:-/tmp}/ns-pd.XXXXXX")" || {
        printf '%s' "BLOCKED: cannot tell which paths this $_verb would write, so the protected-directory guard cannot run."
        return 0
      }
      ns_git_prospective_paths "$REPO" "$SCRUBBED" "$_verb" >"$_pathfile"
      _pathrc=$?
      if [ "$_pathrc" -eq 2 ]; then
        rm -f "$_pathfile"
        printf '%s' "BLOCKED: this $_verb uses a form the protected-directory guard cannot verify. Do not retry a rephrased form."
        return 0
      fi
      _hit=""
      while IFS= read -r -d '' _p; do
        [ -n "$_p" ] || continue
        if ns_path_under_protected "$_p" "$PROTECTED_DIRS"; then
          _hit="$_p"
          break
        fi
      done <"$_pathfile"
      rm -f "$_pathfile"
      if [ -n "$_hit" ]; then
        IFS=' |' read -ra _dirs <<<"$PROTECTED_DIRS"
        for d in "${_dirs[@]}"; do
          ns_path_under_protected "$_hit" "$d" && break
        done
        printf '%s' "BLOCKED: never git add/commit/tag/remote inside '$d' (a protected directory). Do not retry a rephrased form."
        return 0
      fi
    else
      IFS=' |' read -ra _dirs <<<"$PROTECTED_DIRS"
      read -ra _toks <<<"$SCRUBBED"
      for d in "${_dirs[@]}"; do
        [ -n "$d" ] || continue
        for _tok in "${_toks[@]}"; do
          case "$_tok" in
            "$d" | "$d"/* | */"$d" | */"$d"/* | *="$d" | *="$d"/*)
              printf '%s' "BLOCKED: never git add/commit/tag/remote inside '$d' (a protected directory). Do not retry a rephrased form."
              return 0
              ;;
          esac
        done
      done
    fi
  fi

  if ns_hardhat_is_commit "$SCRUBBED" && { [ -n "$EXPECTED_EMAIL" ] || [ -n "$NEVER_COMMIT_PATTERNS" ]; }; then
    if printf '%s' "$SCRUBBED" | grep -qE -- '--git-dir|--work-tree'; then
      printf '%s' "BLOCKED: --git-dir/--work-tree point this commit somewhere the configured commit guards cannot verify. Run the commit from inside the repository instead."
      return 0
    fi
    if [ -n "$EXPECTED_EMAIL" ] && printf '%s' "$SCRUBBED" |
      grep -qE -- '-c[[:space:]]*user\.email=|--author|GIT_(AUTHOR|COMMITTER)_EMAIL='; then
      printf '%s' "BLOCKED: this commit overrides the author identity on the command line, which the expected-identity guard cannot verify. Commit with the repository's configured identity."
      return 0
    fi
    REPO="$(target_repo "$CMD" "${CWD:-$PROJECT_DIR}")"
    case "$?" in
      1) printf '%s' "BLOCKED: this commit names a directory that is not a git repository, so the configured commit guards cannot inspect it. Do not retry a rephrased form."
         return 0 ;;
      2) REPO="$(repo_root "$PROJECT_DIR" "$CWD")" || REPO="$(ns_work_target "$PROJECT_DIR")" || {
           printf '%s' "BLOCKED: cannot tell which git repository this commit targets, so the configured commit guards cannot run. Run the commit from inside the repository."
           return 0
         } ;;
    esac
    if [ -n "$EXPECTED_EMAIL" ]; then
      email="$(git -C "$REPO" config user.email 2>/dev/null || true)"
      if [ "$email" != "$EXPECTED_EMAIL" ]; then
        printf '%s' "BLOCKED: committer identity ('$email') is not the expected '$EXPECTED_EMAIL'. Fix git config user.email, then retry."
        return 0
      fi
    fi
    if [ -n "$NEVER_COMMIT_PATTERNS" ]; then
      _scope="the diff this commit would write"
      _diff="$(ns_git_prospective_diff "$REPO" "$SCRUBBED")"
      case "$?" in
        2) printf '%s' "BLOCKED: this commit uses a form the never-commit guard cannot verify. Do not retry a rephrased form."
           return 0 ;;
      esac
      if printf '%s' "$_diff" | grep -qiE "$NEVER_COMMIT_PATTERNS"; then
        printf '%s' "BLOCKED: $_scope matches a never-commit pattern. Remove it, restage, retry. Do not weaken the pattern list."
        return 0
      fi
    fi
  fi

  if [ -n "$FORBIDDEN_COMMANDS" ] && printf '%s' "$SCRUBBED" | grep -qE "$FORBIDDEN_COMMANDS"; then
    printf '%s' "BLOCKED: the command matches the owner's forbidden list for this shift. Find another way, or park the task with a note in .nightshift/parking-lot.md and keep working. Do not retry a rephrased form."
    return 0
  fi

  # forbiddenCommands is the owner's own list and stays independent of the categories: a command
  # can clear it and still need an allowance the shift does not hold.
  ns_hardhat_elevation_reason && return 0
  return 1
}

# Split a simple command into tokens. Rejects unmatched quotes. No eval.
ns_hardhat_split_tokens() { # <cmd> → fills __ns_hh_tok
  local s="$1" tok="" quote="" c
  __ns_hh_tok=()
  while [ -n "$s" ]; do
    c="${s%"${s#?}"}"
    s="${s#?}"
    if [ -n "$quote" ]; then
      if [ "$c" = "$quote" ]; then
        quote=""
      else
        tok="${tok}${c}"
      fi
      continue
    fi
    case "$c" in
      \' | \") quote="$c" ;;
      [[:space:]])
        if [ -n "$tok" ]; then
          __ns_hh_tok+=("$tok")
          tok=""
        fi
        ;;
      *) tok="${tok}${c}" ;;
    esac
  done
  [ -z "$quote" ] || return 1
  [ -n "$tok" ] && __ns_hh_tok+=("$tok")
  return 0
}

ns_hardhat_canon_regular_file() { # <path>
  local p="$1" dir
  [ -n "$p" ] || return 1
  [ -f "$p" ] && [ ! -L "$p" ] || return 1
  case "$p" in
    */*) dir="$(cd -P "${p%/*}" >/dev/null 2>&1 && pwd -P)" || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s/%s' "$dir" "${p##*/}"
}

# True when the command is exactly a plugin Stop/Reset/Purge helper for this workspace.
# Invoked after lease targeting and before unbound, so a fenced conversation can recover.
ns_hardhat_trusted_shift_control() { # <cmd> <plugin_root> <workspace>
  local cmd="$1" plugin="$2" workspace="$3"
  local script project="" confirm="" i tok helper expected resolved
  [ -n "$cmd" ] && [ -n "$plugin" ] && [ -n "$workspace" ] || return 1
  case "$cmd" in
    *$'\n'* | *$'\r'*) return 1 ;;
  esac
  printf '%s' "$cmd" | grep -qE '[;&|`$<>]' && return 1
  printf '%s' "$cmd" | grep -q '\$' && return 1
  ns_hardhat_split_tokens "$cmd" || return 1
  [ "${#__ns_hh_tok[@]}" -ge 3 ] || return 1
  i=0
  case "${__ns_hh_tok[0]}" in
    bash | sh | /bin/bash | /usr/bin/bash)
      i=1
      ;;
  esac
  script="${__ns_hh_tok[$i]}"
  script="$(ns_hardhat_canon_regular_file "$script")" || return 1
  plugin="$(cd -P "$plugin" >/dev/null 2>&1 && pwd -P)" || return 1
  expected=""
  for helper in stop-shift.sh reset-shift.sh purge-workspace.sh; do
    tok="$(ns_hardhat_canon_regular_file "$plugin/runtime/$helper")" || continue
    if [ "$script" = "$tok" ]; then
      expected="$helper"
      break
    fi
  done
  [ -n "$expected" ] || return 1
  i=$((i + 1))
  while [ "$i" -lt "${#__ns_hh_tok[@]}" ]; do
    tok="${__ns_hh_tok[$i]}"
    i=$((i + 1))
    case "$tok" in
      --project)
        [ "$i" -lt "${#__ns_hh_tok[@]}" ] || return 1
        project="${__ns_hh_tok[$i]}"
        i=$((i + 1))
        ;;
      --reason)
        [ "$i" -lt "${#__ns_hh_tok[@]}" ] || return 1
        i=$((i + 1))
        ;;
      --confirm-path)
        [ "$i" -lt "${#__ns_hh_tok[@]}" ] || return 1
        confirm="${__ns_hh_tok[$i]}"
        i=$((i + 1))
        ;;
      *) return 1 ;;
    esac
  done
  [ -n "$project" ] || return 1
  case "$project" in /*) ;; *) return 1 ;; esac
  resolved="$(cd -P "$project" 2>/dev/null && pwd)" || return 1
  if [ -e "$resolved/.nightshift-link" ] || [ -L "$resolved/.nightshift-link" ]; then
    resolved="$(ns_workspace_root "$resolved" 2>/dev/null)" || return 1
  fi
  workspace="$(cd -P "$workspace" 2>/dev/null && pwd)" || return 1
  [ "$resolved" = "$workspace" ] || return 1
  if [ "$expected" = purge-workspace.sh ]; then
    [ -n "$confirm" ] || return 1
  fi
  return 0
}
