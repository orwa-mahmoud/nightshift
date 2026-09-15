#!/usr/bin/env bash
# Generic shell helpers shared by Nightshift hooks and runtime.

# valid_ere <pattern> — true when grep -E accepts the pattern.
# An invalid pattern makes grep exit 2, which reads exactly like "no match" to a plain `if`,
# so a typo in an owner's guard pattern would silently disable the guard.
valid_ere() {
  printf '' | grep -qE "$1" 2>/dev/null
  [ "$?" -le 1 ]
}

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
