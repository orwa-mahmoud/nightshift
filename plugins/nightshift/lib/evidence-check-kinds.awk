    {
      n = split($0, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        v = ""
        if (w[i] == "kind:") v = w[i + 1]
        else if (index(w[i], "kind:") == 1) v = substr(w[i], 6)
        if (v ~ /^[a-z0-9]+(-[a-z0-9]+)*$/) print v
      }
    }
  
