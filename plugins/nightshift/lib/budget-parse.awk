    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function seconds(s,    n, t, total, part, unit, v) {
      n = split(s, t, /[[:space:]]+/)
      total = 0
      for (i2 = 1; i2 <= n; i2++) {
        part = t[i2]
        if (part !~ /^[0-9]+[hms]$/) return -1
        unit = substr(part, length(part))
        v = substr(part, 1, length(part) - 1) + 0
        total += (unit == "h") ? v * 3600 : (unit == "m") ? v * 60 : v
      }
      return (total > 0) ? total : -1
    }
    function tokens(s,    num, unit, m) {
      if (s !~ /^[0-9]+(\.[0-9]+)?[kKmMbB]?[[:space:]]+tokens?$/) return -1
      sub(/[[:space:]]+tokens?$/, "", s)
      unit = substr(s, length(s))
      m = 1
      if (unit ~ /[kK]/) m = 1000
      else if (unit ~ /[mM]/) m = 1000000
      else if (unit ~ /[bB]/) m = 1000000000
      if (m > 1) s = substr(s, 1, length(s) - 1)
      num = int(s * m)
      return (num > 0) ? num : -1
    }
    {
      text = trim($0)
      if (text == "") { empty = 1; exit }
      lim["soft", "t"] = "-"; lim["soft", "k"] = "-"; lim["hard", "t"] = "-"; lim["hard", "k"] = "-"
      nc = split(text, clause, ",")
      for (c = 1; c <= nc; c++) {
        cl = trim(clause[c])
        if (!match(cl, /^(soft|hard)[[:space:]]+/)) { bad = 1; exit }
        level = trim(substr(cl, 1, RLENGTH))
        if (seen[level]++) { bad = 1; exit }
        rest = trim(substr(cl, RLENGTH + 1))
        nl = split(rest, part, "/")
        for (p = 1; p <= nl; p++) {
          one = trim(part[p])
          if (one ~ /tokens?$/) {
            v = tokens(one); kind = "k"
          } else {
            v = seconds(one); kind = "t"
          }
          if (v < 0 || lim[level, kind] != "-") { bad = 1; exit }
          lim[level, kind] = v
        }
      }
    }
    END {
      if (empty) exit 1
      if (bad) exit 2
      printf "%s %s %s %s\n", lim["soft", "t"], lim["soft", "k"], lim["hard", "t"], lim["hard", "k"]
    }
  
