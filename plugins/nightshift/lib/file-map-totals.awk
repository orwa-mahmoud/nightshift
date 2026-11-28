      NF && $4 != "-" { a += $4; d += $5 }
      END {
        printf "%d %s changed, +%d -%d", n, (n == 1 ? "file" : "files"), a, d
        if (collapsed) printf ", folders collapsed"
        printf "\n"
      }
