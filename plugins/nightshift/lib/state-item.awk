function ns_item_id(line,    s) {
  sub(/\r$/, "", line)
  if (!match(line, /<!--[[:space:]]*id:[[:space:]]*[a-z0-9]+[[:space:]]*-->[[:space:]]*$/)) return ""
  s = substr(line, RSTART, RLENGTH)
  sub(/^<!--[[:space:]]*id:[[:space:]]*/, "", s)
  sub(/[[:space:]]*-->[[:space:]]*$/, "", s)
  return s
}
function ns_item_label(line,    lead) {
  sub(/\r$/, "", line)
  sub(/[[:space:]]*<!--[[:space:]]*id:[[:space:]]*[a-z0-9]+[[:space:]]*-->[[:space:]]*$/, "", line)
  sub(/^- \[[ xX-]\][[:space:]]*\*\*/, "", line)
  sub(/^- \[[ xX-]\][[:space:]]*/, "", line)
  # A dash right after a bare number numbers the item, as in "1 — Fix it": a number alone is no
  # label, so only a later dash ends the title. A code such as P03 before a dash is the label.
  lead = ""
  if (match(line, /^[0-9]+[[:space:]]*(—|–)[[:space:]]*/) || match(line, /^[0-9]+[[:space:]]+-[[:space:]]+/)) {
    lead = substr(line, 1, RLENGTH)
    line = substr(line, RLENGTH + 1)
  }
  sub(/[[:space:]]+—.*$/, "", line)
  sub(/[[:space:]]+-[[:space:]].*$/, "", line)
  sub(/\*\*.*$/, "", line)
  gsub(/[[:space:]]+$/, "", line)
  return lead line
}
