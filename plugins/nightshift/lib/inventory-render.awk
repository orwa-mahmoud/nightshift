function san(s) {
  gsub(/[^ -~]/, " ", s)
  gsub(/  +/, " ", s)
  sub(/^ +/, "", s)
  sub(/ +$/, "", s)
  if (s == "") s = "-"
  return s
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
function cell(s,   i, c, o) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "|") o = o "\\|"
    else o = o c
  }
  return o
}
BEGIN {
  FS = "\t"
  target = "-"; vcs = "none"; nci = 0; npkg = 0; nrow = 0
}
$1 == "target" { target = san($2); next }
$1 == "vcs" { vcs = san($2); next }
$1 == "ci" { nci++; ci[nci] = san($2); next }
$1 == "pkg" { npkg++; pkg[npkg] = san($2); kind[npkg] = san($3); next }
$1 == "field" || $1 == "script" || $1 == "config" || $1 == "tool" {
  nrow++
  rk[nrow] = $1; rp[nrow] = san($2); rn[nrow] = san($3); rv[nrow] = san($4)
  next
}
END {
  if (MODE == "json") {
    printf "{\"ci\":["
    for (i = 1; i <= nci; i++) printf "%s\"%s\"", (i > 1 ? "," : ""), jesc(ci[i])
    printf "],\"packages\":["
    for (p = 1; p <= npkg; p++) {
      printf "%s{", (p > 1 ? "," : "")
      group(p, "config", "configs")
      printf ",\"kind\":\"%s\"", jesc(kind[p])
      printf ",\"lockfile\":\"%s\"", jesc(one(p, "lockfile"))
      printf ",\"manager\":\"%s\"", jesc(one(p, "manager"))
      printf ",\"path\":\"%s\",", jesc(pkg[p])
      group(p, "script", "scripts")
      printf ","
      group(p, "tool", "tools")
      printf ",\"workspaces\":\"%s\"}", jesc(one(p, "workspaces"))
    }
    printf "],\"target\":\"%s\",\"vcs\":\"%s\",\"version\":1}\n", jesc(target), jesc(vcs)
    exit
  }
  printf "inventory: %d %s in %s (%s)\n", npkg, (npkg == 1 ? "package" : "packages"), target, vcs
  printf "ci:"
  if (nci == 0) printf " none"
  for (i = 1; i <= nci; i++) printf " %s", ci[i]
  printf "\n"
  for (p = 1; p <= npkg; p++) {
    printf "\n## %s (%s)\n\n", pkg[p], kind[p]
    print "| field | value |"
    print "| --- | --- |"
    for (i = 1; i <= nrow; i++) {
      if (rp[i] != pkg[p]) continue
      label = rn[i]
      if (rk[i] == "script") label = "script " rn[i]
      else if (rk[i] == "config") label = "config " rn[i]
      else if (rk[i] == "tool") label = "tool " rn[i]
      printf "| %s | %s |\n", cell(label), cell(rv[i])
    }
  }
}
function one(p, name,   i) {
  for (i = 1; i <= nrow; i++) {
    if (rk[i] == "field" && rp[i] == pkg[p] && rn[i] == name) return rv[i]
  }
  return "-"
}
function group(p, kindName, label,   i, first) {
  printf "\"%s\":{", label
  first = 1
  for (i = 1; i <= nrow; i++) {
    if (rk[i] != kindName || rp[i] != pkg[p]) continue
    printf "%s\"%s\":\"%s\"", (first ? "" : ","), jesc(rn[i]), jesc(rv[i])
    first = 0
  }
  printf "}"
}
