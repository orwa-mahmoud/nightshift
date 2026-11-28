    BEGIN {
      while ((getline line < seen) > 0) {
        n = index(line, "\t")
        if (n > 0 && substr(line, 1, n - 1) == kind) known[substr(line, n + 1)] = 1
      }
      close(seen)
    }
    $0 != "" && !($0 in known) && !printed[$0]++ { print }
  
