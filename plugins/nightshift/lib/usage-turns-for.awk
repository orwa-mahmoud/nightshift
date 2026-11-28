    {
      n = split($4, c, ";"); hit = 0; items = ""
      for (i = 1; i <= n; i++) {
        if (c[i] == entry) hit = 1
        l = c[i]; sub(/@[^@]*$/, "", l)
        if (!(l in seen)) { seen[l] = 1; items = items (items == "" ? "" : ";") l }
      }
      delete seen
      if (hit) print $1 "\t" $3 "\t" items
    }
