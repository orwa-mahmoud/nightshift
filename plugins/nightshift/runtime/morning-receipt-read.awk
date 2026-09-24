# The text half of morning-receipt.sh: read the owner's Markdown records, the shift log and the work
# target's history into rows, and nothing else.
#
# morning-receipt.sh owns every decision about what a section says and how a row is printed. This
# program reads. One program serves every operation, selected by -v op=, and every input arrives
# with control characters already turned into spaces:
#
#   interruptions  the shift log. Each line written since the last `shift started` that records an
#                  interruption: a revival or resume attempt, an API failure, a stall, a usage-limit
#                  wait, or how the shift was stopped.
#   handover       the shift log. The last handover line written since the last `shift started`.
#   parked         the parking lot. `E` fs <text> fs <default> fs <rollback> for each decision below
#                  the rule that still waits for the owner. An entry is a `### ` heading and
#                  everything under it, a top-level bullet with its wrapped and nested lines, or a
#                  paragraph. Filed pointers, runtime notices and answered entries are skipped.
#   snags          the snag log. <finding> fs <disposition> for each entry below the rule whose
#                  disposition is not fixed and that is dated on or after -v day (every entry when
#                  day is empty). An entry reads `finding · evidence · disposition · date`; one
#                  without a disposition is open.
#   review         two files: the usage marks as <epoch> fs <label> lines, then `git log --numstat`
#                  output whose commit lines read `@@<TAB><hash><TAB><committer epoch><TAB><subject>`.
#                  The first line out is <first hash> fs <last hash>. Each later line is one change
#                  group: <lines> fs <files> fs <added> fs <removed> fs <commits> fs <key>. The key
#                  is `i` fs <item label> when the commit landed in that item's mark span, and
#                  `c` fs <hash> fs <subject> when it landed in no item's span.
#
# Variables: op, fs (the row separator), dot (the middle dot), day (YYYY-MM-DD or empty), and for
# parked the dispositions Archive files (NS_REVIEW_DISPOSITIONS).

function trim(s) {
  sub(/^ +/, "", s)
  sub(/ +$/, "", s)
  return s
}

# ---------------------------------------------------------------- parked

function p_add(s) {
  s = trim(s)
  if (s == "") return
  if (p_field == "d") p_def = (p_def == "" ? s : p_def " " s)
  else if (p_field == "r") p_rb = (p_rb == "" ? s : p_rb " " s)
  else p_text = (p_text == "" ? s : p_text " " s)
}

function p_flush(    all) {
  all = tolower(p_text " " p_def " " p_rb)
  if (p_open && p_text != "" && p_text !~ /^\[notice\]/ &&
      all !~ (" " dot " (" dispositions ")"))
    print "E" fs p_text fs p_def fs p_rb
  p_open = 0
  p_mode = ""
  p_field = "t"
  p_text = ""
  p_def = ""
  p_rb = ""
}

function p_begin(mode, s) {
  p_flush()
  p_open = 1
  p_mode = mode
  p_add(s)
}

function parked_line(raw,    t, s) {
  if (!p_started) {
    if (raw ~ /^--- *$/) p_started = 1
    return
  }
  t = raw
  sub(/ +$/, "", t)
  if (t == "") {
    p_blank = 1
    if (p_mode == "p") p_flush()
    return
  }
  if (t ~ /^### +/) {
    s = t
    sub(/^### +/, "", s)
    p_begin("h", s)
    p_blank = 0
    return
  }
  if (t ~ /^#/ || t ~ /^(- )?Filed:/ || t ~ /^\(empty/) {
    p_flush()
    p_blank = 0
    return
  }
  if (p_open && match(t, /^ *(- )?(\*\*)?(Default|Rollback):(\*\*)?/)) {
    s = substr(t, RSTART, RLENGTH)
    if (s ~ /Default/) {
      p_field = "d"
      p_def = ""
    } else {
      p_field = "r"
      p_rb = ""
    }
    p_add(substr(t, RSTART + RLENGTH))
    p_blank = 0
    return
  }
  if (t ~ /^- /) {
    if (p_open && p_mode == "h") p_add(substr(t, 3))
    else p_begin("b", substr(t, 3))
  } else if (!p_open || (p_mode == "b" && p_blank && t !~ /^ /)) {
    p_begin("p", t)
  } else {
    p_add(t)
  }
  p_blank = 0
}

# ---------------------------------------------------------------- snags

function s_flush(    n, part, disp, d, rest) {
  if (s_entry == "") return
  n = split(s_entry, part, " " dot " ")
  disp = "open"
  if (n >= 3 && part[3] !~ /^ *[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] *$/) disp = trim(part[3])
  d = ""
  rest = s_entry
  while (match(rest, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
    d = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
  }
  if (tolower(disp) !~ /^fixed/ && (day == "" || (d != "" && d >= day)))
    print trim(part[1]) fs disp
  s_entry = ""
}

function snag_line(raw,    t) {
  if (!s_started) {
    if (raw ~ /^--- *$/) s_started = 1
    return
  }
  t = raw
  sub(/ +$/, "", t)
  if (t == "" || t ~ /^#/ || t ~ /^(- )?Filed:/ || t ~ /^\(empty/) {
    s_flush()
    return
  }
  if (t ~ /^- /) {
    s_flush()
    s_entry = trim(substr(t, 3))
    return
  }
  if (s_entry != "") s_entry = s_entry " " trim(t)
}

# ---------------------------------------------------------------- shift log

function log_end(    i, t, l, last) {
  for (i = log_start + 1; i <= log_n; i++) {
    t = trim(log_line[i])
    if (t == "") continue
    l = tolower(t)
    if (op == "handover") {
      if (l ~ /handover/) last = t
    } else if (l ~ /resume attempt|reviv|resumed session|wedge|api down|(^|[^a-z])stall|stop-work|stopped by|pressed esc|quitting time|past the deadline|silent too long|usage limit/) {
      print t
    }
  }
  if (op == "handover" && last != "") print last
}

# ---------------------------------------------------------------- review

function review_mark(raw,    m) {
  split(raw, m, fs)
  stamp[++r_marks] = m[1] + 0
  owner[r_marks] = m[2]
}

function review_line(raw,    n, f, subject, i, key, path) {
  if (raw ~ /^@@\t/) {
    n = split(raw, f, "\t")
    subject = f[4]
    for (i = 5; i <= n; i++) subject = subject "\t" f[i]
    if (r_first == "") r_first = f[2]
    r_last = f[2]
    key = ""
    for (i = 1; i <= r_marks; i++) {
      if (stamp[i] >= f[3] + 0) {
        if (owner[i] != "arm" && owner[i] != "") key = "i" fs owner[i]
        break
      }
    }
    if (key == "") key = "c" fs f[2] fs subject
    if (!(key in commits)) order[++r_groups] = key
    commits[key]++
    r_current = key
    return
  }
  if (raw !~ /^[0-9-]+\t[0-9-]+\t/ || r_current == "") return
  split(raw, f, "\t")
  path = substr(raw, length(f[1]) + length(f[2]) + 3)
  if (!((r_current SUBSEP path) in seen)) {
    seen[r_current SUBSEP path] = 1
    files[r_current]++
  }
  if (f[1] ~ /^[0-9]+$/) added[r_current] += f[1]
  if (f[2] ~ /^[0-9]+$/) removed[r_current] += f[2]
}

function review_end(    i, k) {
  print r_first fs r_last
  for (i = 1; i <= r_groups; i++) {
    k = order[i]
    printf "%d%s%d%s%d%s%d%s%d%s%s\n", added[k] + removed[k], fs, files[k], fs, added[k], fs,
      removed[k], fs, commits[k], fs, k
  }
}

# ---------------------------------------------------------------- dispatch

op == "interruptions" || op == "handover" {
  log_line[++log_n] = $0
  if (tolower($0) ~ /shift started/) log_start = log_n
  next
}
op == "parked" { parked_line($0); next }
op == "snags" { snag_line($0); next }
op == "review" && FILENAME == ARGV[1] { review_mark($0); next }
op == "review" { review_line($0); next }

END {
  if (op == "interruptions" || op == "handover") log_end()
  else if (op == "parked") p_flush()
  else if (op == "snags") s_flush()
  else if (op == "review") review_end()
}
