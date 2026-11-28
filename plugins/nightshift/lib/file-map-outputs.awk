    { sub(/\r$/, "") }
    skip { if ($0 ~ /^<!-- \/(nightshift:[a-z-]+|usage) -->$/) skip = 0; next }
    /^<!-- (nightshift:[a-z-]+|usage) -->$/ { skip = 1; next }
    comment { if (index($0, "-->")) comment = 0; next }
    /^<!--/ { if (!index($0, "-->")) comment = 1; next }
    {
      line = $0
      while (match(line, /\]\([^)]+\)/)) {
        t = substr(line, RSTART + 2, RLENGTH - 3)
        line = substr(line, RSTART + RLENGTH)
        sub(/[ \t].*$/, "", t)
        if (t ~ /^[a-z][a-z0-9+.-]*:/ || t ~ /^#/ || t ~ /^\//) continue
        print t
      }
      line = $0
      while (match(line, /`[^`]+`/)) {
        t = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        if (t ~ /[ \t]/ || t ~ /^[a-z][a-z0-9+.-]*:/ || t ~ /^\//) continue
        if (t !~ /\// && t !~ /\.[A-Za-z0-9]+$/) continue
        print t
      }
    }
  
