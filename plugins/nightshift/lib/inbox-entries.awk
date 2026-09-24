# The parking lot and the snag log, read entry by entry: the text half of Archive's filing and of
# Doctor's inbox check. lib/Nightshift.psm1 Get-NSInboxBlocks is the PowerShell twin.
#
# An entry is a top-level `- ` bullet with its wrapped lines, its indented lines and any `Default:`
# or `Rollback:` line, blank lines between them included. An unindented line after a blank line
# ends it, and so does a heading, a `---` rule, a `Filed:` pointer or the `(empty)` placeholder.
# Any other text is a paragraph, which Archive never files. The morning receipt reads the parking
# lot's bullets and paragraphs the same way.
#
#   op=file    prints the file less each entry that carries a disposition, and appends those
#              entries to the file named by -v filed. -v dispositions is the alternation Archive
#              files (NS_REVIEW_DISPOSITIONS); a disposition follows a ` · ` separator.
#   op=strays  prints <line> TAB <text> for the first line of each paragraph below the first `---`
#              rule, or anywhere in a file that has none.

function handled(s) {
  return tolower(s) ~ (" · (" dispositions ")")
}

function flush() {
  if (buf != "" && op == "file") {
    if (handled(buf)) printf "%s\n", buf >>filed
    else printf "%s\n", buf
  }
  buf = ""
  blank = 0
}

function keep(line) {
  if (op == "file") print line
}

{
  t = $0
  gsub(/[[:cntrl:]]/, " ", t)
  sub(/ +$/, "", t)
}

t == "" {
  if (buf != "") {
    buf = buf "\n" $0
    blank = 1
  } else {
    keep($0)
  }
  para = 0
  next
}

t ~ /^--- *$/ {
  flush()
  para = 0
  keep($0)
  if (!rule) rule = FNR
  next
}

t ~ /^#/ || t ~ /^(- )?Filed:/ || t ~ /^\(empty/ {
  flush()
  para = 0
  keep($0)
  next
}

buf != "" && t ~ /^ *(- )?(\*\*)?(Default|Rollback):/ {
  buf = buf "\n" $0
  blank = 0
  next
}

t ~ /^- / {
  flush()
  buf = $0
  para = 0
  next
}

buf != "" && (!blank || t ~ /^ /) {
  buf = buf "\n" $0
  blank = 0
  next
}

{
  flush()
  keep($0)
  if (!para) {
    n++
    at[n] = FNR
    text[n] = t
  }
  para = 1
}

END {
  flush()
  if (op == "strays") {
    for (i = 1; i <= n; i++) {
      if (!rule || at[i] > rule) printf "%d\t%s\n", at[i], text[i]
    }
  }
}
