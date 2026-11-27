{
  s = $0
  gsub(/[^ -~]/, " ", s)
  gsub(/  +/, " ", s)
  sub(/^ +/, "", s)
  sub(/ +$/, "", s)
  print s
}
