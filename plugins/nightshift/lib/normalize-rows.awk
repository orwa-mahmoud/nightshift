function san(s) {
  gsub(/[^ -~]/, " ", s)
  gsub(/  +/, " ", s)
  sub(/^ +/, "", s)
  sub(/ +$/, "", s)
  if (length(s) > 100) s = substr(s, 1, 97) "..."
  if (s == "") s = "-"
  return s
}
function rank(sev) {
  if (sev == "critical") return 5
  if (sev == "error" || sev == "high") return 4
  if (sev == "warning" || sev == "moderate") return 3
  if (sev == "note" || sev == "low") return 2
  if (sev == "info") return 1
  return 0
}
BEGIN { FS = "\t" }
$1 == "item" {
  sev = san($2)
  printf "%d\t%s\t%09d\t%s\t%s\t%s\n", 5 - rank(sev), san($3), $4 + 0, san($5), san($6), sev
  next
}
{ printf "%s\n", $0 > META }
