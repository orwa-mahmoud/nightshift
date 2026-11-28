function ns_order_key(n,    cls, pre, num, id) {
  cls = 2; pre = ""; num = ""
  if (match(n, /^[0-9]+/)) {
    cls = 0; num = substr(n, 1, RLENGTH)
  } else if (match(n, /^[A-Za-z]+[0-9]+/)) {
    id = substr(n, 1, RLENGTH)
    match(id, /[0-9]+$/)
    cls = 1; pre = tolower(substr(id, 1, RSTART - 1)); num = substr(id, RSTART)
  }
  sub(/^0+/, "", num)
  if (cls < 2 && num == "") num = "0"
  return sprintf("%d\t%s\t%04d%s\t%s", cls, pre, length(num), num, n)
}
