function nt(s) { gsub(/[\t\r\n]/, " ", s); return s }
BEGIN {
  items = 0; noise = 0; errors = 0; warnings = 0
  summaries = 0; counted = 0
  esc = sprintf("%c", 27)
}
{
  line = $0
  sub(/\r$/, "", line)
  # --pretty colours its diagnostics, and a report captured to a file keeps the
  # escapes. They are decoration: strip them before anything is matched.
  gsub(esc "\\[[0-9;]*[A-Za-z]", "", line)
  if (line ~ /^[ \t]*$/) next
  # file(line,col): error TS1234: message
  p = index(line, "): ")
  head = ""
  rest = ""
  if (p > 0) {
    head = substr(line, 1, p)
    rest = substr(line, p + 3)
  }
  if (p > 0 && head ~ /\([0-9]+,[0-9]+\)$/ && rest ~ /^(error|warning) TS[0-9]+: /) {
    q = 0
    for (i = length(head); i > 0; i--) {
      if (substr(head, i, 1) == "(") { q = i; break }
    }
    file = substr(head, 1, q - 1)
    lc = substr(head, q + 1, length(head) - q - 1)
    split(lc, a, ",")
    emit(rest, file, a[1] + 0)
    next
  }
  # file:line:col - error TS1234: message, which is what --pretty writes. A drive
  # letter puts colons in the path too, so the line and column are taken from the
  # end and everything before them is the file. The header starts a line; the same
  # shape indented is the tail of a diagnostic whose head this input never carried.
  d = index(line, " - ")
  if (d > 0 && line !~ /^[ \t]/) {
    head = substr(line, 1, d - 1)
    rest = substr(line, d + 3)
    if (head ~ /:[0-9]+:[0-9]+$/ && rest ~ /^(error|warning) TS[0-9]+: /) {
      n = split(head, b, ":")
      file = b[1]
      for (i = 2; i <= n - 2; i++) file = file ":" b[i]
      emit(rest, file, b[n - 1] + 0)
      next
    }
  }
  if (line ~ /^(error|warning) TS[0-9]+: /) { emit(line, "-", 0); next }
  if (line ~ /^Found [0-9]+ error/) {
    summaries++
    split(line, f, " ")
    counted = f[2] + 0
    next
  }
  # Every other non-blank line counts, indented continuations included: an input
  # of nothing but continuation lines is a report this parser did not read, not a
  # clean compile.
  noise++
}
function emit(rest, file, ln,   s1, sev, r2, s2, code, msg) {
  s1 = index(rest, " ")
  sev = substr(rest, 1, s1 - 1)
  r2 = substr(rest, s1 + 1)
  s2 = index(r2, " ")
  code = substr(r2, 1, s2 - 2)
  msg = substr(r2, s2 + 1)
  if (sev == "error") errors++; else warnings++
  items++
  printf "item\t%s\t%s\t%d\t%s\t%s\n", sev, nt(file), ln, nt(code), nt(msg)
  if (file != "-") seen[file] = 1
}
END {
  # A watch log is several reports in one file, and none of them describes the
  # whole input. Read it as unavailable rather than as the last one that ran.
  if (summaries > 1) {
    print "error\tthe input holds more than one TypeScript report"
    exit 0
  }
  if (items == 0 && summaries == 0 && noise > 0) {
    print "error\tthe input holds no TypeScript diagnostics"
    exit 0
  }
  # A report that counts its own errors is the authority on how many there were.
  # Reading fewer than it counted means diagnostics in a shape this parser does
  # not know, so the answer is unavailable — never the total rounded down to what
  # happened to parse, and never rows invented to reach the total.
  if (summaries == 1 && counted != errors) {
    printf "error\tthe report counts %d error%s and this parser read %d\n", \
      counted, (counted == 1 ? "" : "s"), errors
    exit 0
  }
  files = 0
  for (k in seen) files++
  printf "headline\ttsc: %d %s, %d %s in %d %s\n", \
    errors, (errors == 1 ? "error" : "errors"), \
    warnings, (warnings == 1 ? "warning" : "warnings"), \
    files, (files == 1 ? "file" : "files")
  printf "count\terrors\t%d\n", errors
  printf "count\twarnings\t%d\n", warnings
  printf "files\t%d\n", files
}
