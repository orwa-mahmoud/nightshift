    $2 == h && $1 >= cut { line[NR] = $0; if ($1 >= latest) { latest = $1; session = $3 } }
    END {
      for (n in line) {
        split(line[n], f, "\t")
        if (f[3] == session && !((f[4]) in seen)) { seen[f[4]] = 1; print f[4] "\t" f[5] }
      }
    }
