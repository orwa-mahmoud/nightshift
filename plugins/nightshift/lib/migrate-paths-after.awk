    BEGIN {
      n = split(ENVIRON["NS_MIG_MOVES"], pairs, "\n")
      for (k = 1; k <= n; k++) {
        if (pairs[k] == "") continue
        split(pairs[k], pr, "\t")
        moves[pr[1]] = pr[2]
      }
    }
    {
      p = $0
      out = p
      for (src in moves) {
        if (p == src) { out = moves[src]; break }
        if (index(p, src "/") == 1) { out = moves[src] substr(p, length(src) + 1); break }
      }
      print out
      while (index(out, "/") > 0) { sub(/\/[^\/]*$/, "", out); print out }
    }
