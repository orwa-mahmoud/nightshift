  .rules | keys[] as $k
  | select(($s[0].properties | has($k) | not) or $k == "$schema")
  | $k
