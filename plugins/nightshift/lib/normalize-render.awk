function mdesc(s,   i, c, o) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "|") o = o "\\|"
    else o = o c
  }
  return o
}
function jesc(s,   i, c, o) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\"") o = o "\\\""
    else if (c == "\\") o = o "\\\\"
    else o = o c
  }
  return o
}
BEGIN { FS = "\t"; total = 0; n = 0; nc = 0; files = 0; headline = "-"
        INPUT = ENVIRON["NS_NORMALIZE_INPUT"]
        BASENAME = ENVIRON["NS_NORMALIZE_BASENAME"] }
FNR == NR {
  if ($1 == "headline") headline = $2
  else if ($1 == "files") files = $2 + 0
  else if ($1 == "count") { nc++; cl[nc] = $2; cv[nc] = $3 + 0 }
  next
}
{
  total++
  if (n < TOP) {
    n++
    sv[n] = $6; fl[n] = $2; ln[n] = ($3 + 0); cd[n] = $4; ms[n] = $5
  }
}
END {
  for (i = 2; i <= nc; i++) {
    kl = cl[i]; kv = cv[i]; j = i - 1
    while (j >= 1 && cl[j] > kl) { cl[j + 1] = cl[j]; cv[j + 1] = cv[j]; j-- }
    cl[j + 1] = kl; cv[j + 1] = kv
  }
  if (MODE == "json") {
    printf "{\"counts\":{"
    for (i = 1; i <= nc; i++) printf "%s\"%s\":%d", (i > 1 ? "," : ""), jesc(cl[i]), cv[i]
    printf "},\"digest\":\"%s\",\"files\":%d,\"format\":\"%s\",\"headline\":\"%s\"", \
      jesc(DIGEST), files, jesc(FORMAT), jesc(headline)
    printf ",\"input\":\"%s\",\"items\":[", jesc(BASENAME)
    for (i = 1; i <= n; i++) {
      printf "%s{\"code\":\"%s\",\"file\":\"%s\",\"line\":%s,\"message\":\"%s\",\"severity\":\"%s\"}", \
        (i > 1 ? "," : ""), jesc(cd[i]), jesc(fl[i]), \
        (ln[i] == 0 ? "null" : sprintf("%d", ln[i])), jesc(ms[i]), jesc(sv[i])
    }
    printf "],\"shown\":%d,\"source\":\"%s\",\"total\":%d,\"version\":1}\n", \
      n, jesc(SOURCE), total
    exit
  }
  print headline
  print ""
  if (n > 0) {
    print "| severity | file | line | code | detail |"
    print "| --- | --- | --- | --- | --- |"
    for (i = 1; i <= n; i++) {
      printf "| %s | %s | %s | %s | %s |\n", \
        mdesc(sv[i]), mdesc(fl[i]), (ln[i] == 0 ? "-" : sprintf("%d", ln[i])), \
        mdesc(cd[i]), mdesc(ms[i])
    }
    print ""
  }
  printf "showing %d of %d items\n", n, total
  printf "result: sha256:%s\n", DIGEST
  printf "source: %s sha256:%s\n", INPUT, SOURCE
}
