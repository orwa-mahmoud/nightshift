    function block(   l) { print first; while ((getline l < bodyfile) > 0) print l; close(bodyfile); print last }
    { line = $0; sub(/\r$/, "", line) }
    line == first { if (!done) block(); done = 1; skip = 1; next }
    skip && line == last { skip = 0; next }
    skip { next }
    present { print; next }
    { kept[++n] = $0 }
    END {
      if (present) exit
      while (n > 0 && kept[n] ~ /^[[:space:]]*\r?$/) n--
      for (i = 1; i <= n; i++) print kept[i]
      if (n > 0) print ""
      block()
    }
