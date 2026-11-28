      NF { n++; path[n] = $1; st[n] = $2; old[n] = $3; add[n] = $4; del[n] = $5 }
      function keyof(p, depth,    parts, c, k, j) {
        c = split(p, parts, "/")
        if (c - 1 < depth) return p
        k = parts[1]
        for (j = 2; j <= depth; j++) k = k "/" parts[j]
        return k "/"
      }
      END {
        for (depth = 3; depth >= 1; depth--) {
          split("", seen); rows = 0
          for (i = 1; i <= n; i++) { k = keyof(path[i], depth); if (!(k in seen)) { seen[k] = 1; rows++ } }
          if (rows <= limit || depth == 1) break
        }
        for (i = 1; i <= n; i++) {
          k = keyof(path[i], depth)
          if (k ~ /\/$/) {
            files[k]++
            if (add[i] != "-") { plus[k] += add[i]; minus[k] += del[i] }
            continue
          }
          if (kind == "git") {
            line = st[i] " " path[i] "  " ((add[i] == "-") ? "binary" : "+" add[i] " -" del[i])
            if (old[i] != "") line = line "  (from " old[i] ")"
          } else {
            line = path[i]
          }
          print k "\t" line
        }
        for (k in files) {
          if (kind == "git") line = k "  " files[k] (files[k] == 1 ? " file" : " files") "  +" (plus[k] + 0) " -" (minus[k] + 0)
          else line = k "  " files[k] (files[k] == 1 ? " output" : " outputs")
          print k "\t" line
        }
      }
