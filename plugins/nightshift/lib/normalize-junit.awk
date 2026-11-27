function nt(s) { gsub(/[\t\r\n]/, " ", s); return s }
BEGIN {
  doc = ""
  suites = 0; tests = 0; failures = 0; errs = 0; skipped = 0
  depth = 0; cases = 0
  torn = ""; bad = ""
  cls = "-"; nm = "-"
  SQ = sprintf("%c", 39)
}
function att(tag, key,   q, v, i) {
  if (!match(tag, "[ \t\r\n]" key "=[\"" SQ "]")) return ""
  q = substr(tag, RSTART + RLENGTH - 1, 1)
  v = substr(tag, RSTART + RLENGTH)
  i = index(v, q)
  if (i == 0) return ""
  return unent(substr(v, 1, i - 1))
}
function unent(s) {
  gsub(/&lt;/, "<", s)
  gsub(/&gt;/, ">", s)
  gsub(/&quot;/, "\"", s)
  gsub("&apos;", SQ, s)
  gsub(/&amp;/, "\\&", s)
  return s
}
# A CDATA section and a comment are payload, not markup. A failure message that
# quotes a suite element would otherwise add phantom suites and phantom rows, so
# both are cut out before anything is split on a bracket. The scan runs left to
# right, which is what keeps a marker inside the other one literal.
function decontent(s,   out, ci, mi, j) {
  out = ""
  while (1) {
    ci = index(s, "<![CDATA[")
    mi = index(s, "<!--")
    if (ci == 0 && mi == 0) break
    if (mi == 0 || (ci > 0 && ci < mi)) {
      out = out substr(s, 1, ci - 1)
      s = substr(s, ci + 9)
      j = index(s, "]]>")
      if (j == 0) { torn = "an unterminated CDATA section"; return out }
      s = substr(s, j + 3)
    } else {
      out = out substr(s, 1, mi - 1)
      s = substr(s, mi + 4)
      j = index(s, "-->")
      if (j == 0) { torn = "an unterminated comment"; return out }
      s = substr(s, j + 3)
    }
  }
  return out s
}
# The element text of one record, ending at the first bracket outside a quoted
# attribute value, so an attribute may carry one and the text content never
# reaches the attribute reader.
function tagtext(rec,   i, c, q) {
  q = ""
  for (i = 1; i <= length(rec); i++) {
    c = substr(rec, i, 1)
    if (q != "") {
      if (c == q) q = ""
      continue
    }
    if (c == "\"" || c == SQ) { q = c; continue }
    if (c == ">") return substr(rec, 1, i - 1)
  }
  return rec
}
# One suite leaves the stack. Only a leaf carries counts: a report that nests its
# suites states the same tests twice, once on the outer suite and once on each
# suite inside it, and adding both reports every test twice.
function pop(   d) {
  if (depth <= 0) { bad = "a testsuite that closes without opening"; return }
  d = depth
  depth--
  if (!leaf[d]) return
  suites++
  tests += s_tests[d]
  failures += s_failures[d]
  errs += s_errors[d]
  skipped += s_skipped[d]
}
{ doc = doc $0 "\n" }
END {
  body = decontent(doc)
  # The last element of a finished report closes. A document whose final bracket
  # opens a tag and never shuts it was cut off while the writer was still writing.
  lt = 0
  for (i = length(body); i > 0; i--) {
    if (substr(body, i, 1) == "<") { lt = i; break }
  }
  if (lt > 0 && index(substr(body, lt), ">") == 0) bad = "a tag that never closes"
  n = split(body, rec, "<")
  for (r = 1; r <= n; r++) {
    if (rec[r] == "") continue
    tag = tagtext(rec[r])
    open = tag
    closing = 0
    if (substr(open, 1, 1) == "/") { closing = 1; open = substr(open, 2) }
    name = open
    sub(/[ \t\r\n\/].*$/, "", name)
    if (name == "testsuite") {
      if (closing) { pop(); continue }
      saw = 1
      depth++
      s_tests[depth] = att(tag, "tests") + 0
      s_failures[depth] = att(tag, "failures") + 0
      s_errors[depth] = att(tag, "errors") + 0
      s_skipped[depth] = att(tag, "skipped") + 0
      leaf[depth] = 1
      if (depth > 1) leaf[depth - 1] = 0
      if (substr(tag, length(tag), 1) == "/") pop()
      continue
    }
    if (name == "testcase") {
      if (closing) {
        cases--
        if (cases < 0) bad = "a testcase that closes without opening"
        continue
      }
      cls = att(tag, "classname")
      nm = att(tag, "name")
      if (cls == "") cls = "-"
      if (nm == "") nm = "-"
      if (substr(tag, length(tag), 1) != "/") cases++
      continue
    }
    if (closing) continue
    if (name == "failure" || name == "error") {
      t = att(tag, "type")
      printf "item\terror\t%s\t0\t%s\t%s%s\n", \
        nt(cls), name, nt(nm), (t == "" ? "" : " (" nt(t) ")")
      continue
    }
  }
  # A reader that closes elements nobody closed is answering about a document
  # nobody wrote. An unfinished report is unavailable, with the reason named.
  if (torn != "") {
    print "error\tthe report ends inside " torn
    exit 0
  }
  if (bad != "") {
    print "error\tthe report holds " bad
    exit 0
  }
  if (depth > 0) {
    print "error\tthe report ends with an unclosed testsuite element"
    exit 0
  }
  if (cases > 0) {
    print "error\tthe report ends with an unclosed testcase element"
    exit 0
  }
  if (!saw) {
    print "error\tthe input holds no JUnit testsuite element"
    exit 0
  }
  printf "headline\tjunit: %d %s, %d %s, %d %s, %d skipped in %d %s\n", \
    tests, (tests == 1 ? "test" : "tests"), \
    failures, (failures == 1 ? "failure" : "failures"), \
    errs, (errs == 1 ? "error" : "errors"), \
    skipped, suites, (suites == 1 ? "suite" : "suites")
  printf "count\terrors\t%d\n", errs
  printf "count\tfailures\t%d\n", failures
  printf "count\tskipped\t%d\n", skipped
  printf "count\ttests\t%d\n", tests
  printf "files\t%d\n", suites
}
