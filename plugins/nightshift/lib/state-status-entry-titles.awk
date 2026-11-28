    /^Filed:/ { next }
    /^- Filed:/ { next }
    /^- / {
      line = $0
      sub(/^- /, "", line)
      gsub(/\*\*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (length(line) > 100) line = substr(line, 1, 97) "..."
      out[++n] = line
    }
    END {
      first = 1
      if (max > 0 && n > max) first = n - max + 1
      for (i = first; i <= n; i++) print out[i]
    }
  
