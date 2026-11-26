#!/usr/bin/env bash
# Messages between the owner and a running shift.
#
# Each run keeps one file, inbox/messages.md, that both sides append to and nobody rewrites: the
# owner's questions and answers under `## Owner · <time>`, the worker's replies under
# `## Worker · <time>`. The pulse shows the worker what the owner added since it last looked, at its
# next tool call; the owner reads the worker's reply in the same file. The text between headings is
# kept exactly as written.

NS_MESSAGE_OWNER='## Owner · '
NS_MESSAGE_WORKER='## Worker · '

# ns_message_append <state-dir> <Owner|Worker> <text> — one message, appended with the local time.
ns_message_append() {
  local ns="$1" who="$2" text="$3" file header
  case "$who" in
    Owner) header="$NS_MESSAGE_OWNER" ;;
    Worker) header="$NS_MESSAGE_WORKER" ;;
    *) printf 'messages: author must be Owner or Worker, not %s\n' "$who" >&2; return 2 ;;
  esac
  ns_layout_set file "$ns" messages || return 1
  if [ -L "$file" ]; then
    printf 'messages: %s is a symlink; not writing through it\n' "$file" >&2
    return 1
  fi
  mkdir -p "${file%/*}" || return 1
  if [ ! -s "$file" ]; then
    printf '# Messages\n' >>"$file" || return 1
  fi
  # One write, so a pulse reading at the same moment sees the whole message or none of it.
  printf '\n%s%s\n\n%s\n' "$header" "$(ns_local_now second)" "$text" >>"$file"
}

# ns_message_unseen <state-dir> — the owner's messages added since the last call, each with its
# heading, and marks them seen. The worker's own replies are never shown back to it. A file that got
# shorter (the owner edited it) shows nothing until it grows again.
ns_message_unseen() {
  local ns="$1" file seen size off
  ns_layout_set file "$ns" messages || return 0
  ns_layout_set seen "$ns" messages-seen || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  off=0
  if [ -f "$seen" ] && [ ! -L "$seen" ]; then
    IFS= read -r off <"$seen" || :
  fi
  case "$off" in '' | *[!0-9]*) off=0 ;; esac
  [ "$size" -gt "$off" ] || {
    [ "$size" -eq "$off" ] || ns_message_mark_seen "$seen" "$size"
    return 0
  }
  tail -c "+$((off + 1))" "$file" | NS_OWNER="$NS_MESSAGE_OWNER" NS_WORKER="$NS_MESSAGE_WORKER" awk '
    index($0, ENVIRON["NS_OWNER"]) == 1 { who = "owner"; if (shown++) print ""; print; next }
    index($0, ENVIRON["NS_WORKER"]) == 1 { who = "worker"; next }
    who == "owner" { print }
  '
  ns_message_mark_seen "$seen" "$size"
}

# ns_message_mark_seen <seen-file> <bytes> — how far into the messages file the worker has been shown.
ns_message_mark_seen() {
  local seen="$1" tmp
  mkdir -p "${seen%/*}" 2>/dev/null || return 0
  tmp="$seen.tmp.$$"
  if ! { printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$seen"; } 2>/dev/null; then
    rm -f "$tmp"
  fi
}

# ns_message_notice <state-dir> — the pulse's notice for the owner's new messages, empty when none.
ns_message_notice() {
  local text file
  text="$(ns_message_unseen "$1")"
  [ -n "$text" ] || return 0
  ns_layout_set file "$1" messages
  printf 'The owner sent this shift a message in %s:\n\n%s\n\nAnswer each one once, by appending a "%s<time>" block with your answer to that file (skip a message you already answered there), then carry on with the item.' \
    "$file" "$text" "$NS_MESSAGE_WORKER"
}
