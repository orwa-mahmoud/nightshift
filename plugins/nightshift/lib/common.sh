#!/usr/bin/env bash
# Generic shell helpers shared by Nightshift hooks and runtime.

# valid_ere <pattern> — true when grep -E accepts the pattern.
# An invalid pattern makes grep exit 2, which reads exactly like "no match" to a plain `if`,
# so a typo in an owner's guard pattern would silently disable the guard.
valid_ere() {
  printf '' | grep -qE "$1" 2>/dev/null
  [ "$?" -le 1 ]
}

# ns_local_time <epoch> [second] — the moment as the person at this machine reads it: local date
# and time with the machine's own UTC offset, `2026-10-08 07:12 (UTC+04:00)`; with `second`, to
# the second. Every time a person reads is written this way. Fields a program reads back keep UTC.
ns_local_time() {
  local e="${1:-}" fmt='%Y-%m-%d %H:%M' stamp z
  case "$e" in '' | *[!0-9]*) return 1 ;; esac
  [ "${2:-}" != second ] || fmt='%Y-%m-%d %H:%M:%S'
  stamp="$(date -r "$e" "+$fmt" 2>/dev/null || date -d "@$e" "+$fmt" 2>/dev/null)" || return 1
  z="$(date -r "$e" +%z 2>/dev/null || date -d "@$e" +%z 2>/dev/null)" || return 1
  case "$z" in [+-][0-9][0-9][0-9][0-9]) ;; *) return 1 ;; esac
  printf '%s (UTC%s:%s)' "$stamp" "${z%??}" "${z#???}"
}

# ns_worker_settle_seconds — how long start-run watches a new background worker before calling it
# started: a CLI that stops at once on a prompt it cannot answer headless has exited by then.
ns_worker_settle_seconds() { printf '5'; }

# ns_local_now [second] — now, as ns_local_time writes it.
ns_local_now() { ns_local_time "$(date +%s)" "${1:-}"; }

# A local timestamp to the second, the form the shift log writes.
ts() { ns_local_now second; }

# One shift-log line, skipped when the workspace folder is already gone.
log_line() { [ -d "$NS" ] && printf '%s · %s\n' "$(ts)" "$1" >>"$LOG"; }

ns_mtime() {
  case "$(uname -s)" in
    Darwin) stat -f %m "$1" 2>/dev/null ;;
    *) stat -c %Y "$1" 2>/dev/null ;;
  esac
}

ns_age_days() {
  local m now
  m="$(ns_mtime "$1")" || return 1
  case "$m" in '' | *[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  printf '%s' "$(((now - m) / 86400))"
}

ns_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Support-bundle redaction. If a line still looks secret or contains an
# unresolved absolute path, omit it — never guess.
ns_secret_line() {
  printf '%s' "$1" | grep -qiE \
    '(password|passwd|secret|token|api[_-]?key|authorization|bearer|credential)[[:space:]]*[=:]' && return 0
  printf '%s' "$1" | grep -qE '://[^/@[:space:]]+:[^/@[:space:]]+@' && return 0
  printf '%s' "$1" | grep -qiE '[?&](token|key|secret|password|auth|access_token)=' && return 0
  return 1
}

ns_sed_escape() {
  printf '%s' "$1" | sed 's/[][\\.*^$]/\\&/g'
}

# The folder of shipped state templates, fixed when this file is sourced: lib.sh clears its own
# directory variable once every module has loaded.
_NS_TEMPLATES_DIR="${BASH_SOURCE[0]%/*}/../skills/nightshift/references/templates"

# ns_templates_dir — the folder of shipped state templates (punch-list.md, parking-lot.md, …).
ns_templates_dir() {
  printf '%s' "$_NS_TEMPLATES_DIR"
}

# ns_owner_template <template> <workspace> [<run-dir>] — the template's text with
# `$NIGHTSHIFT_WORKSPACE`, `$NS` and, when <run-dir> is given, `$RUN` (the folder of the run the
# file belongs to) replaced by those paths, character for character: a path holding `&`, `|` or a
# backslash is written as it is. Without <run-dir>, `$RUN` is left for whoever places the file in
# a run.
ns_owner_template() {
  local ws="${2%/}"
  NS_TEMPLATE_WS="$ws" NS_TEMPLATE_NS="$ws/.nightshift" NS_TEMPLATE_RUN="${3-}" \
    NS_TEMPLATE_HAS_RUN="${3+1}" awk '
    function literal(s, from, to,    out, i) {
      out = ""
      while ((i = index(s, from)) > 0) {
        out = out substr(s, 1, i - 1) to
        s = substr(s, i + length(from))
      }
      return out s
    }
    {
      line = $0
      if (ENVIRON["NS_TEMPLATE_HAS_RUN"] == "1") line = literal(line, "$RUN", ENVIRON["NS_TEMPLATE_RUN"])
      line = literal(line, "$NIGHTSHIFT_WORKSPACE", ENVIRON["NS_TEMPLATE_WS"])
      print literal(line, "$NS", ENVIRON["NS_TEMPLATE_NS"])
    }
  ' "$1"
}

# ns_tokenize_text <text> <home> <workspace> <work-target>
# Longest prefix wins. Remaining absolute paths make the function return 1 (omit).
ns_tokenize_text() {
  local text="$1" home="$2" workspace="$3" target="$4" out
  out="$text"
  if [ -n "$target" ]; then
    out="$(printf '%s' "$out" | sed "s#$(ns_sed_escape "$target")#\$WORK_TARGET#g")"
  fi
  if [ -n "$workspace" ]; then
    out="$(printf '%s' "$out" | sed "s#$(ns_sed_escape "$workspace")#\$WORKSPACE#g")"
  fi
  if [ -n "$home" ]; then
    out="$(printf '%s' "$out" | sed "s#$(ns_sed_escape "$home")#\$HOME#g")"
  fi
  if printf '%s' "$out" | grep -qE '(^|[[:space:]=])(/|file://)'; then
    return 1
  fi
  printf '%s' "$out"
}

# ns_sanitize_line <text> <home> <workspace> <work-target>
# Prints the tokenized line, or returns 1 to omit.
ns_sanitize_line() {
  local text="$1"
  ns_secret_line "$text" && return 1
  ns_tokenize_text "$text" "$2" "$3" "$4"
}

# ns_payload_session_id <json> — the hook payload's session_id, read with jq when it is installed
# and with sed otherwise. Empty when the payload has none.
ns_payload_session_id() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r '.session_id // empty' 2>/dev/null || true
  else
    printf '%s' "$1" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
  fi
}

# ns_conversation_session_id — the id of the conversation a command runs in, from the host's own
# environment: Claude Code gives its Bash tool CLAUDE_CODE_SESSION_ID, the same id its hooks receive
# as session_id. Empty on a host that gives a command no such id.
ns_conversation_session_id() {
  printf '%s' "${CLAUDE_CODE_SESSION_ID:-}"
}

# ns_read_stdin_bounded <seconds> — the hook payload, and never a hung session.
#
# A hook whose stdin is a descriptor that never reaches EOF used to sit in `cat` until something
# killed it: one such hook held a session for five and a half hours with its payload sitting in
# argv the whole time. Cursor (and Claude Code) can also keep the descriptor open and trickle a
# line often enough that `read -t` resets every time — the timeout is per read, not the loop.
# bash `read -t` has also been observed never to return at all on a unix socket whose peer is
# gone, so the bound is a process-level alarm around the read, not a flag that `read` is
# trusted to honor. Perl's SIGALRM is on stock macOS and the Linux runners. Without perl the
# bash loop still honors the wall clock on a pipe; /bin/sleep kills this process if `read`
# itself never returns. The killer is only for the read: it is disarmed before the hook
# continues, so an armed clock-out is not cut off mid-archive.
#
# A terminal is a manual run and carries no payload. Bytes already received when the alarm
# fires are kept.
ns_read_stdin_bounded() {
  local seconds="${1:-2}" line buf="" begun left dog=""
  [ ! -t 0 ] || return 0
  case "$seconds" in '' | *[!0-9]*) seconds=2 ;; esac
  if ns_have_cmd perl; then
    NS_STDIN_BOUND="$seconds" perl -e '
      my $seconds = $ENV{NS_STDIN_BOUND};
      $seconds = 2 unless defined $seconds && $seconds =~ /^[0-9]+$/;
      my $buf = "";
      eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $seconds;
        binmode STDIN;
        while (1) {
          my $n = sysread(STDIN, my $chunk, 8192);
          last if !defined $n || $n == 0;
          $buf .= $chunk;
        }
        alarm 0;
      };
      binmode STDOUT;
      print $buf;
    '
    return 0
  fi
  if [ -x /bin/sleep ]; then
    (
      /bin/sleep "$seconds"
      kill -TERM "$$" 2>/dev/null || true
    ) &
    dog=$!
  fi
  begun=$SECONDS
  while :; do
    left=$((seconds - (SECONDS - begun)))
    [ "$left" -gt 0 ] || break
    IFS= read -r -t "$left" line || {
      [ -z "$line" ] || buf="$buf$line"
      break
    }
    buf="$buf$line
"
  done
  if [ -n "$dog" ]; then
    kill "$dog" 2>/dev/null || true
    wait "$dog" 2>/dev/null || true
  fi
  printf '%s' "$buf"
}
