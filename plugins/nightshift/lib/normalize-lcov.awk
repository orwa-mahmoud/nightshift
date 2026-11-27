function nt(s) { gsub(/[\t\r\n]/, " ", s); return s }
BEGIN { sf = ""; lf = 0; lh = 0; have = 0; files = 0; tlf = 0; tlh = 0; noise = 0 }
{
  line = $0
  sub(/\r$/, "", line)
  if (line ~ /^[ \t]*$/) next
  if (line ~ /^SF:/) { sf = substr(line, 4); lf = 0; lh = 0; have = 1; next }
  if (line ~ /^LF:/) { lf = substr(line, 4) + 0; next }
  if (line ~ /^LH:/) { lh = substr(line, 4) + 0; next }
  if (line == "end_of_record") {
    if (have) { record(); have = 0 }
    next
  }
  if (line ~ /^(TN|DA|FN|FNDA|FNF|FNH|BRDA|BRF|BRH|VER):/) next
  noise++
}
# A record with no instrumented lines has nothing to be a percentage of, so -1
# marks it unmeasured for every reader below.
function bp(c, t) { return (t <= 0) ? -1 : int((c * 20000 + t) / (2 * t)) }
function pl(c, t,   b) {
  b = bp(c, t)
  return (b < 0) ? "unmeasured" : sprintf("%d.%02d%%", int(b / 100), b % 100)
}
function band(c, t,   b) {
  b = bp(c, t)
  if (b < 0) return "info"
  return (b < 5000) ? "error" : ((b < 8000) ? "warning" : "note")
}
function record() {
  files++
  tlf += lf
  tlh += lh
  printf "item\t%s\t%s\t0\tlines\t%d/%d lines covered (%s)\n", \
    band(lh, lf), nt(sf), lh, lf, pl(lh, lf)
}
END {
  if (have) record()
  if (files == 0) {
    print "error\tthe input holds no lcov SF records"
    exit 0
  }
  printf "headline\tlcov: %s lines covered, %d/%d in %d %s\n", \
    pl(tlh, tlf), tlh, tlf, files, (files == 1 ? "file" : "files")
  printf "count\tlinesCovered\t%d\n", tlh
  printf "count\tlinesTotal\t%d\n", tlf
  printf "files\t%d\n", files
}
