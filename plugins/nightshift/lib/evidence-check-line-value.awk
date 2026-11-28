    {
      n = split($0, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (w[i] == key ":") { print w[i + 1]; exit }
        if (index(w[i], key ":") == 1) { print substr(w[i], length(key) + 2); exit }
      }
    }
  
