    BEGIN {
      ORS = ""
      n = split(ENVIRON["NS_LAYOUT_ROWS"], rows, "\n")
      for (k = 1; k <= n; k++) {
        if (split(rows[k], f, "\t") < 4 || f[4] == "field" || f[4] == "retired" || f[4] == "stray") continue
        if (substr(f[3], 1, 7) == "runs/*/") {
          if (run == "") continue
          f[3] = "runs/" run "/" substr(f[3], 8)
        }
        if (index(f[3], "*")) continue
        key[k] = f[1]
        path[k] = f[3]
        if (f[2] + 0 <= version && (!(f[1] in best) || f[2] + 0 >= bestv[f[1]])) {
          best[f[1]] = f[3]
          bestv[f[1]] = f[2] + 0
        }
      }
      m = 0
      for (k = 1; k <= n; k++) {
        if (!(k in key) || !(key[k] in best) || path[k] == best[key[k]]) continue
        from[++m] = path[k]
        to[m] = best[key[k]]
      }
      # The longest name first, so a file is never read as the folder it sits in.
      for (a = 2; a <= m; a++) {
        for (b = a; b > 1 && length(from[b]) > length(from[b - 1]); b--) {
          t = from[b]; from[b] = from[b - 1]; from[b - 1] = t
          t = to[b]; to[b] = to[b - 1]; to[b - 1] = t
        }
      }
    }
    {
      s = $0
      while (match(s, /\.nightshift[\/\\]/)) {
        prefix = substr(s, 1, RSTART - 1)
        chunk = substr(s, RSTART, RLENGTH)
        sep = substr(chunk, length(chunk), 1)
        last = (length(prefix) ? substr(prefix, length(prefix), 1) : "")
        if (last == "/" || last == "\\") {
          printf "%s%s", prefix, chunk
        } else {
          printf "%s%s/.nightshift%s", prefix, ws, sep
        }
        s = substr(s, RSTART + RLENGTH)
        for (j = 1; j <= m; j++) {
          if (substr(s, 1, length(from[j])) == from[j] && substr(s, length(from[j]) + 1, 1) !~ /[A-Za-z0-9._-]/) {
            printf "%s", to[j]
            s = substr(s, length(from[j]) + 1)
            break
          }
        }
      }
      printf "%s", s
    }
  
